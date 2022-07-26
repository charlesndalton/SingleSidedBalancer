// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";

import "@openzeppelin/contracts/utils/math/Math.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@yearnvaults/contracts/yToken.sol";

import {IBalancerPool} from "./interfaces/Balancer/IBalancerPool.sol";
import {IBalancerVault} from "./interfaces/Balancer/IBalancerVault.sol";
import {IAsset} from "./interfaces/Balancer/IAsset.sol";
import {IVault} from "./interfaces/Yearn/Vault.sol";

/* A few key things can change between underlying pools. For example, although we enter
 * most pools through balancerVault.joinPool(), linear pools such as the aave boosted pool
 * don't support this, and we need to enter them through batch swaps. Common logic inside
 * 'BaseSingleSidedBalancer' and details are implemented in extensions such as
 * 'PhantomSingleSidedBalancer'.
 */
/**
 * @notice Strategy for depositing into Balancer and depositing LP tokens into auto-compounding vault.
 * @dev Balancer pools are heterogeneous. Already, there are normal pools and phantom
        pools. Balancer may also add more types in the future.

        To accomodate this, we use the template pattern. `BaseSingleSidedBalancer`
        contains a bunch of logic that is shared across pool types. For each pool
        type, there is a corresponding extension. 

        All extensions must implement the following:
        - extensionName() returns (string memory)
        - _investWantIntoBalancerPool(uint256 _wantAmount)
        - _liquidateBPTsToWant(uint256 _bptAmount)
        The latter two functions must perform slippage checks based on two params
        in the template, `maxSlippageIn` and `maxSlippageOut.` 
        
        Extensions can optionally add other functions which allow vault managers
        to manually manage the position.
 */
abstract contract BaseSingleSidedBalancer is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    uint256 public lastDepositTime;

    IVault public bptVault;
    IBalancerPool public balancerPool;
    uint8 public numTokens;
    uint8 public tokenIndex;
    IAsset[] internal assets; // assets of the pool
    bytes32 public balancerPoolID;

    uint256 public maxSlippageIn; // bips
    uint256 public maxSlippageOut; // bips
    uint256 public maxSingleInvest;
    bool public withdrawProtection;
    uint256 internal constant MAX_BPS = 10000;

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    IERC20 internal constant BAL =
        IERC20(0xba100000625a3754423978a60c9317c58a424e3D);
    IBalancerVault internal constant balancerVault =
        IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    // === DEPLOYMENT FUNCTIONS ===

    constructor(address _vault) BaseStrategy(_vault) {}

    // === TVL ACCOUNTING ===

    function delegatedAssets() public view override returns (uint256) {
        return vault.strategies(address(this)).totalDebt;
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 _totalBPTBalance = balancerPool.balanceOf(address(this)) +
            poolTokensInYVault();
        return want.balanceOf(address(this)) + bptToWant(_totalBPTBalance);
    }

    function poolTokensInYVault() public view returns (uint256) {
        uint256 _balance = bptVault.balanceOf(address(this));

        if (bptVault.totalSupply() == 0) {
            //needed because of revert on priceperfullshare if 0
            return 0;
        }
        uint256 _pricePerShare = bptVault.pricePerShare();
        uint256 _decimals = IERC20Metadata(address(balancerPool)).decimals();
        // ASSUMPTION: balancer pool tokens are always 18 decimals
        return (_balance * _pricePerShare) / (10**_decimals);
    }

    function bptToWant(uint256 _bptAmount) public view returns (uint256) {
        uint256 _unscaledWantAmount = (_bptAmount * balancerPool.getRate()) /
            1e18;
        return
            _scaleDecimals(
                _unscaledWantAmount,
                IERC20Metadata(address(balancerPool)),
                IERC20Metadata(address(want))
            );
    }

    function wantToBPT(uint256 _wantAmount) public view returns (uint256) {
        uint256 _unscaledBPTAmount = (_wantAmount * 1e18) /
            balancerPool.getRate();
        return
            _scaleDecimals(
                _unscaledBPTAmount,
                IERC20Metadata(address(want)),
                IERC20Metadata(address(balancerPool))
            );
    }

    function _scaleDecimals(
        uint256 _amount,
        IERC20Metadata _fromToken,
        IERC20Metadata _toToken
    ) internal view returns (uint256 _scaled) {
        uint256 decFrom = _fromToken.decimals();
        uint256 decTo = _toToken.decimals();
        return
            decTo > decFrom
                ? _amount * (10**(decTo - decFrom))
                : _amount / (10**(decFrom - decTo));
    }

    // === HARVEST-RELEVANT FUNCTIONS ===

    function _investWantIntoBalancerPool(uint256 _wantAmount) internal virtual;

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _balanceOfWant = want.balanceOf(address(this));
        if (_balanceOfWant > _debtOutstanding) {
            uint256 _amountToInvest = _balanceOfWant - _debtOutstanding;
            _amountToInvest = Math.min(_amountToInvest, maxSingleInvest);
            _investWantIntoBalancerPool(_amountToInvest);
            bptVault.deposit();
            lastDepositTime = block.timestamp;
        }
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        _debtPayment = _debtOutstanding;

        uint256 _totalDebt = vault.strategies(address(this)).totalDebt;
        uint256 _totalAssets = estimatedTotalAssets();

        if (_totalAssets > _totalDebt) {
            _profit = _totalAssets - _totalDebt;
        } else {
            _loss = _totalDebt - _totalAssets;
        }

        uint256 _amountNeededLiquid = _debtPayment + _profit;
        uint256 _liquidAssets = want.balanceOf(address(this));

        if (_amountNeededLiquid > _liquidAssets) {
            uint256 _toWithdraw = _amountNeededLiquid - _liquidAssets;

            (, uint256 _withdrawalLoss) = _withdrawSome(_toWithdraw);
            if (_withdrawalLoss < _profit) {
                _profit = _profit - _withdrawalLoss;
            } else {
                _loss = _loss + (_withdrawalLoss - _profit);
                _profit = 0;
            }

            _liquidAssets = want.balanceOf(address(this));

            // pay back profit first
            if (_liquidAssets < _profit) {
                _profit = _liquidAssets;
                _debtPayment = 0;
            } else if (_liquidAssets < _debtPayment + _profit) {
                _debtPayment = _liquidAssets - _profit;
            }
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _liquidAssets = want.balanceOf(address(this));

        if (_liquidAssets < _amountNeeded) {
            uint256 _toWithdraw = _amountNeeded - _liquidAssets;
            (_liquidatedAmount, ) = _withdrawSome(_toWithdraw);
        }

        _liquidatedAmount = Math.min(
            _amountNeeded,
            _liquidatedAmount + _liquidAssets
        );
        _loss = _amountNeeded - _liquidatedAmount;
    }

    // safe to request more than we have
    function _liquidateBPTsToWant(uint256 _bptAmount) internal virtual;

    function _withdrawSome(uint256 _amountToWithdraw)
        internal
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _wantBalanceBefore = want.balanceOf(address(this));

        uint256 _bptAmount = wantToBPT(_amountToWithdraw);

        // should be 0 but just in case
        uint256 _bptBeforeBalance = balancerPool.balanceOf(address(this));

        uint256 _pricePerShare = bptVault.pricePerShare();
        uint256 _vaultShareToWithdraw = (_bptAmount * 1e18) / _pricePerShare;

        uint256 _vaultShareBalance = bptVault.balanceOf(address(this));

        if (_vaultShareToWithdraw > _vaultShareBalance) {
            // this is not loss, so we amend the amount
            _vaultShareToWithdraw = _vaultShareBalance;

            uint256 _equivalentBPTAmount = (_vaultShareToWithdraw *
                _pricePerShare) / 1e18;
            _amountToWithdraw = bptToWant(_equivalentBPTAmount);
        }

        if (_vaultShareToWithdraw > 0) {
            bptVault.withdraw(_vaultShareToWithdraw);
            if (withdrawProtection) {
                //this tests that we liquidated all of the expected ytokens. Without it if we get back less then will mark it is loss
                require(
                    _vaultShareBalance - bptVault.balanceOf(address(this)) >=
                        _vaultShareToWithdraw - 1,
                    "YVAULTWITHDRAWFAILED"
                );
            }
        }

        uint256 _bptsToLiquidate = balancerPool.balanceOf(address(this)) -
            _bptBeforeBalance;

        if (_bptsToLiquidate > 0) {
            _liquidateBPTsToWant(_bptsToLiquidate);
        }

        uint256 _wantBalanceDiff = want.balanceOf(address(this)) -
            _wantBalanceBefore;

        if (_wantBalanceDiff >= _amountToWithdraw) {
            _liquidatedAmount = _amountToWithdraw;
        } else {
            _liquidatedAmount = _wantBalanceDiff;
            _loss = _amountToWithdraw - _wantBalanceDiff;
        }
    }

    function liquidateAllPositions()
        internal
        override
        returns (uint256 _amountFreed)
    {
        // slippage checks still exist in emergency exit
        bptVault.withdraw(bptVault.balanceOf(address(this)));
        _liquidateBPTsToWant(balancerPool.balanceOf(address(this)));
        return want.balanceOf(address(this));
    }

    // === MISC FUNCTIONS ===

    // Examples: BASIC, PHANTOM
    function extensionName() public view virtual returns (string memory);

    // Examples: SSB_DAI_BASIC_FUD, SSB_USDC_PHANTOM_bb-a-USD
    function name() external view override returns (string memory) {
        return
            string(
                abi.encodePacked(
                    "SSB_",
                    IERC20Metadata(address(want)).symbol(),
                    "_",
                    extensionName(),
                    "_",
                    balancerPool.symbol()
                )
            );
    }

    function prepareMigration(address _newStrategy) internal override {
        // everything else can, and should be, swept
        bptVault.transfer(_newStrategy, bptVault.balanceOf(address(this)));
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    // solhint-disable-next-line no-empty-blocks
    {

    }

    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    // solhint-disable-next-line no-empty-blocks
    {

    }

    // === MANAGEMENT FUNCTIONS ===

    function withdrawSome(uint256 _amountToWithdraw)
        external
        onlyVaultManagers
    {
        _withdrawSome(_amountToWithdraw);
    }

    function investWantIntoBalancerPool(uint256 _wantAmount)
        external
        onlyVaultManagers
    {
        _investWantIntoBalancerPool(_wantAmount);
    }

    function liquidateBPTsToWant(uint256 _bptAmount)
        external
        onlyVaultManagers
    {
        _liquidateBPTsToWant(_bptAmount);
    }

    function updateMaxSlippageIn(uint256 _maxSlippageIn)
        public
        onlyVaultManagers
    {
        maxSlippageIn = _maxSlippageIn;
    }

    function updateMaxSlippageOut(uint256 _maxSlippageOut)
        public
        onlyVaultManagers
    {
        maxSlippageOut = _maxSlippageOut;
    }

    function updateMaxSingleInvest(uint256 _maxSingleInvest)
        public
        onlyVaultManagers
    {
        maxSingleInvest = _maxSingleInvest;
    }

    function updateWithdrawProtection(bool _withdrawProtection)
        public
        onlyVaultManagers
    {
        withdrawProtection = _withdrawProtection;
    }
}

/**
 * @notice SSB Extension for normal pools. Should only be used for stable pools.
 */
contract BasicSingleSidedBalancer is BaseSingleSidedBalancer {
    using SafeERC20 for IERC20;
    using Address for address;

    event Cloned(address indexed clone);

    bool public isOriginal = true;
    uint256 internal constant MAX_TOKENS = 20;

    // Cloning & initialization code adapted from https://github.com/yearn/yearn-vaults/blob/43a0673ab89742388369bc0c9d1f321aa7ea73f6/contracts/BaseStrategy.sol#L866

    constructor(
        address _vault,
        address _bptVault,
        uint256 _maxSlippageIn,
        uint256 _maxSlippageOut,
        uint256 _maxSingleInvest
    ) BaseSingleSidedBalancer(_vault) {
        _initializeStrat(
            _bptVault,
            _maxSlippageIn,
            _maxSlippageOut,
            _maxSingleInvest
        );
    }

    function _initializeStrat(
        address _bptVault,
        uint256 _maxSlippageIn,
        uint256 _maxSlippageOut,
        uint256 _maxSingleInvest
    ) internal virtual {
        // health.ychad.eth
        healthCheck = address(0xDDCea799fF1699e98EDF118e0629A974Df7DF012);

        bptVault = IVault(_bptVault);

        balancerPool = IBalancerPool(bptVault.token());
        bytes32 _poolID = balancerPool.getPoolId();
        balancerPoolID = _poolID;

        (IERC20[] memory tokens, , ) = balancerVault.getPoolTokens(_poolID);
        uint8 _numTokens = uint8(tokens.length);
        numTokens = _numTokens;
        require(_numTokens > 0, "Empty Pool");
        require(_numTokens <= MAX_TOKENS, "Exceeds max tokens");

        assets = new IAsset[](numTokens);
        uint8 _tokenIndex = type(uint8).max;
        for (uint8 i = 0; i < _numTokens; i++) {
            if (tokens[i] == want) {
                _tokenIndex = i;
            }
            assets[i] = IAsset(address(tokens[i]));
        }
        // require(_tokenIndex != type(uint8).max, "token not supported in pool!");
        tokenIndex = _tokenIndex;

        maxSlippageIn = _maxSlippageIn;
        maxSlippageOut = _maxSlippageOut;
        maxSingleInvest = _maxSingleInvest;

        want.safeApprove(address(balancerVault), type(uint256).max);
        IERC20(address(balancerPool)).safeApprove(
            address(bptVault),
            type(uint256).max
        );

        withdrawProtection = true;
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _bptVault,
        uint256 _maxSlippageIn,
        uint256 _maxSlippageOut,
        uint256 _maxSingleInvest
    ) external virtual {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(
            _bptVault,
            _maxSlippageIn,
            _maxSlippageOut,
            _maxSingleInvest
        );
    }

    function clone(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _bptVault,
        uint256 _maxSlippageIn,
        uint256 _maxSlippageOut,
        uint256 _maxSingleInvest
    ) external returns (address newStrategy) {
        require(isOriginal, "!clone");
        bytes20 addressBytes = bytes20(address(this));

        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            newStrategy := create(0, clone_code, 0x37)
        }

        BasicSingleSidedBalancer(newStrategy).initialize(
            _vault,
            _strategist,
            _rewards,
            _keeper,
            _bptVault,
            _maxSlippageIn,
            _maxSlippageOut,
            _maxSingleInvest
        );

        emit Cloned(newStrategy);
    }

    function extensionName() public view override returns (string memory) {
        // basic pool, no frills
        return "BASIC";
    }

    function _investWantIntoBalancerPool(uint256 _wantAmount)
        internal
        override
    {
        uint256 _minBPTOut = (wantToBPT(_wantAmount) *
            (MAX_BPS - maxSlippageIn)) / MAX_BPS;
        uint256[] memory _maxAmountsIn = new uint256[](numTokens);
        _maxAmountsIn[tokenIndex] = _wantAmount;

        if (_wantAmount > 0) {
            bytes memory _userData = abi.encode(
                IBalancerVault.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT,
                _maxAmountsIn,
                _minBPTOut
            );

            IBalancerVault.JoinPoolRequest memory _request = IBalancerVault
                .JoinPoolRequest(assets, _maxAmountsIn, _userData, false);

            balancerVault.joinPool(
                balancerPoolID,
                address(this),
                address(this),
                _request
            );
        }
    }

    function _liquidateBPTsToWant(uint256 _bptAmount) internal override {
        uint256[] memory _minAmountsOut = new uint256[](numTokens);

        _minAmountsOut[tokenIndex] =
            (bptToWant(_bptAmount) * (MAX_BPS - maxSlippageOut)) /
            MAX_BPS;

        bytes memory _userData = abi.encode(
            IBalancerVault.ExitKind.EXACT_BPT_IN_FOR_ONE_TOKEN_OUT,
            _bptAmount,
            tokenIndex
        );

        IBalancerVault.ExitPoolRequest memory _request = IBalancerVault
            .ExitPoolRequest(assets, _minAmountsOut, _userData, false);

        balancerVault.exitPool(
            balancerPoolID,
            address(this),
            payable(address(this)),
            _request
        );
    }
}

/**
 * @notice SSB Extension for Phantom pools
 * @dev We can't deposit into Phantom pools the same way that we deposit into normal pools. 
        Instead, we need to swap into them. For example, if we needed to deposit
        DAI into the Boosted pool, we would swap DAI -> bb_a_DAI -> bb_a_USD.

        This is challenging because there can be different numbers of swaps in
        the swap path, but stack-allocated arrays need to be fixed-size. To get
        around this, we create storage arrays at initialization time.
  */
contract PhantomSingleSidedBalancer is BaseSingleSidedBalancer {
    using SafeERC20 for IERC20;
    using Address for address;

    // These three are set manually by strategists
    bytes32[] public swapPathPoolIDs; // pool IDs of pools in your swap path, in the order of swapping.
    IAsset[] public swapPathAssets; // these MUST be sorted numerically
    uint256[] public swapPathAssetIndexes; // explained in following example

    IBalancerVault.BatchSwapStep[] depositSwapSteps;
    int256[] depositLimits;

    IBalancerVault.BatchSwapStep[] withdrawSwapSteps;
    int256[] withdrawLimits;

    event Cloned(address indexed clone);

    bool public isOriginal = true;

    // Cloning & initialization code adapted from https://github.com/yearn/yearn-vaults/blob/43a0673ab89742388369bc0c9d1f321aa7ea73f6/contracts/BaseStrategy.sol#L866

    /**
     * @param _swapPathPoolIDs Pool IDs of pools in your swap path, in the order of swapping.
     * @param _swapPathAssets Assets you're swapping through. Must be sorted from smallest address to biggest address.
     * @param _swapPathAssetIndexes Indexes of `_swapPathAssets` which explain the order that you're swapping through the assets. Explained in following example.
     *
     * @dev Let's say we wanted to single-side DAI into the boosted pool
            swapPathPoolIDs[0] would be the ID of the pool that contains regular DAI and bb_a_DAI
            swapPathPoolIDs[1] would be the ID of the pool that contains bb_a_DAI and bb_a_USD (the real BPT)
            If these were reversed, the strategy would try to swap DAI into the bb_a_DAI/bb_a_USD pool, which doesn't make any sense.
            assets would be DAI, bb_a_DAI, and bb_a_USD, sorted numerically (so not necessarily in that order, but let's assume that this is the case)
            swapPathAssetIndexes would be [0, 1, 2]
            if assets was [bb_a_DAI, bb_a_USD, DAI], swapPathAssetIndexes would be [2, 1, 0]
     */
    constructor(
        address _vault,
        address _bptVault,
        uint256 _maxSlippageIn,
        uint256 _maxSlippageOut,
        uint256 _maxSingleInvest,
        bytes32[] memory _swapPathPoolIDs,
        IAsset[] memory _swapPathAssets,
        uint256[] memory _swapPathAssetIndexes
    ) BaseSingleSidedBalancer(_vault) {
        _initializeStrat(
            _bptVault,
            _maxSlippageIn,
            _maxSlippageOut,
            _maxSingleInvest,
            _swapPathPoolIDs,
            _swapPathAssets,
            _swapPathAssetIndexes
        );
    }

    function _initializeStrat(
        address _bptVault,
        uint256 _maxSlippageIn,
        uint256 _maxSlippageOut,
        uint256 _maxSingleInvest,
        bytes32[] memory _swapPathPoolIDs,
        IAsset[] memory _swapPathAssets,
        uint256[] memory _swapPathAssetIndexes
    ) internal virtual {
        // health.ychad.eth
        healthCheck = address(0xDDCea799fF1699e98EDF118e0629A974Df7DF012);

        bptVault = IVault(_bptVault);

        balancerPool = IBalancerPool(bptVault.token());
        bytes32 _poolID = balancerPool.getPoolId();
        balancerPoolID = _poolID;

        maxSlippageIn = _maxSlippageIn;
        maxSlippageOut = _maxSlippageOut;
        maxSingleInvest = _maxSingleInvest;

        want.safeApprove(address(balancerVault), type(uint256).max);
        IERC20(address(balancerPool)).safeApprove(
            address(bptVault),
            type(uint256).max
        );

        swapPathPoolIDs = _swapPathPoolIDs;
        swapPathAssets = _swapPathAssets;
        swapPathAssetIndexes = _swapPathAssetIndexes;

        // we need to create one swap path for swapping want -> BPT and one for swapping BPT -> want
        // example of swap steps here: https://github.com/charlesndalton/StrategyBalancerTemplate/blob/df947fbb2f4b973d46b820001e476dfbe27c0826/tests/test_yswap.py#L79-L104

        uint256 _numberOfPools = _swapPathPoolIDs.length;
        for (uint8 i = 0; i < _numberOfPools; i++) {
            bytes32 _poolID = _swapPathPoolIDs[i];

            // Check that this pool indeed contains these tokens
            address[] memory _tokensToCheck = new address[](2);
            _tokensToCheck[0] = address(
                _swapPathAssets[_swapPathAssetIndexes[i]]
            );
            _tokensToCheck[1] = address(
                _swapPathAssets[_swapPathAssetIndexes[i + 1]]
            );
            require(
                poolContainsTokens(_poolID, _tokensToCheck),
                "!pool_contains_tokens"
            );

            depositSwapSteps.push(
                IBalancerVault.BatchSwapStep(
                    _poolID, // poolId
                    _swapPathAssetIndexes[i], // assetInIndex
                    _swapPathAssetIndexes[i + 1], // assetOutIndex
                    0, // amount (0 is a placeholder, since this will be modified in each deposit call)
                    abi.encode(0) // userData
                )
            );

            // should be the items, but in reverse order
            withdrawSwapSteps.push(
                IBalancerVault.BatchSwapStep(
                    _swapPathPoolIDs[_numberOfPools - 1 - i],
                    _swapPathAssetIndexes[_numberOfPools - i],
                    _swapPathAssetIndexes[_numberOfPools - 1 - i],
                    0,
                    abi.encode(0)
                )
            );

            /// Balancer explanation of limits:
            /// An array of maximum amounts of each asset to be transferred.
            /// For tokens going in to the Vault, the limit shall be a positive number.
            /// For tokens going out of the Vault, the limit shall be a negative number.
            /// If the amount to be transferred for a given asset is greater than its limit,
            /// the trade will fail with error BAL#507: SWAP_LIMIT.

            /// For slippage checks, we care about the limit of the asset that's
            /// coming out of the vault (to us). When we're depositing, we care
            /// about the limit of the LP token. When we're withdrawing, we care
            /// about the limit of want.

            /// Because assets are in order of hex size and not in order of swap,
            /// figuring out which limit to change for slippage checks is a bit
            /// of a chore. It's not just limits[0] or limits[limits.length - 1].
            /// For a deposit, we need to change `limits[swapPathAssetIndexes[swapPathAssetIndexes.length - 1]]`.
            /// For a withdrawal, we need to change `limits[swapPathAssetIndexes[0]]`.
            /// In our previous example, this would change bb-a-USD for deposits and DAI for withdrawals.

            /// For every other asset, the limit can just be a really high number.
            /// So we start by creating two storage arrays, filled with really high
            /// numbers, and allow deposit to modify one and withdraw to modify the
            /// other one.

            /// num of limits = num of assets = num of pools + 1, so we push 1 for each iteration of this loop and an additional one at the end

            depositLimits.push(type(int256).max);
            withdrawLimits.push(type(int256).max);
        }
        depositLimits.push(type(int256).max);
        withdrawLimits.push(type(int256).max);

        withdrawProtection = true;
    }

    function poolContainsTokens(bytes32 _poolID, address[] memory _tokens)
        internal
        returns (bool)
    {
        (IERC20[] memory _tokensInPool, , ) = balancerVault.getPoolTokens(
            _poolID
        );

        uint256 _numberOfTokensToCheck = _tokens.length;

        uint256 _matches = 0;

        for (uint256 i = 0; i < _tokensInPool.length; i++) {
            for (uint256 j = 0; j < _numberOfTokensToCheck; j++) {
                if (address(_tokensInPool[i]) == _tokens[j]) {
                    _matches++;
                }
            }
        }

        return _matches == _numberOfTokensToCheck;
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _bptVault,
        uint256 _maxSlippageIn,
        uint256 _maxSlippageOut,
        uint256 _maxSingleInvest,
        bytes32[] memory _swapPathPoolIDs,
        IAsset[] memory _swapPathAssets,
        uint256[] memory _swapPathAssetIndexes
    ) external virtual {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(
            _bptVault,
            _maxSlippageIn,
            _maxSlippageOut,
            _maxSingleInvest,
            _swapPathPoolIDs,
            _swapPathAssets,
            _swapPathAssetIndexes
        );
    }

    function clone(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _bptVault,
        uint256 _maxSlippageIn,
        uint256 _maxSlippageOut,
        uint256 _maxSingleInvest,
        bytes32[] memory _swapPathPoolIDs,
        IAsset[] memory _swapPathAssets,
        uint256[] memory _swapPathAssetIndexes
    ) external returns (address newStrategy) {
        require(isOriginal, "!clone");
        bytes20 addressBytes = bytes20(address(this));

        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            newStrategy := create(0, clone_code, 0x37)
        }

        PhantomSingleSidedBalancer(newStrategy).initialize(
            _vault,
            _strategist,
            _rewards,
            _keeper,
            _bptVault,
            _maxSlippageIn,
            _maxSlippageOut,
            _maxSingleInvest,
            _swapPathPoolIDs,
            _swapPathAssets,
            _swapPathAssetIndexes
        );

        emit Cloned(newStrategy);
    }

    function extensionName() public view override returns (string memory) {
        return "PHANTOM";
    }

    function _investWantIntoBalancerPool(uint256 _wantAmount)
        internal
        override
    {
        uint256 _minBPTOut = (wantToBPT(_wantAmount) *
            (MAX_BPS - maxSlippageIn)) / MAX_BPS;

        assert(_minBPTOut < 2**255); // security check that it's castable to int256 without overflow

        depositLimits[swapPathAssetIndexes[swapPathAssetIndexes.length - 1]] =
            0 -
            int256(_minBPTOut);

        depositSwapSteps[0].amount = _wantAmount;

        IBalancerVault.FundManagement memory _funds = IBalancerVault
            .FundManagement(
                address(this), // sender
                false, // fromInternalBalance
                payable(address(this)), // recipient
                false // toInternalBalance
            );

        balancerVault.batchSwap(
            IBalancerVault.SwapKind.GIVEN_IN,
            depositSwapSteps,
            swapPathAssets,
            _funds,
            depositLimits,
            block.timestamp
        );
    }

    function _liquidateBPTsToWant(uint256 _bptAmount) internal override {
        uint256 _minWantOut = (bptToWant(_bptAmount) *
            (MAX_BPS - maxSlippageOut)) / MAX_BPS;

        assert(_minWantOut < 2**255); // security check that it's castable to int256 without overflow

        withdrawLimits[swapPathAssetIndexes[0]] = 0 - int256(_minWantOut);

        withdrawSwapSteps[0].amount = _bptAmount;

        IBalancerVault.FundManagement memory _funds = IBalancerVault
            .FundManagement(
                address(this), // sender
                false, // fromInternalBalance
                payable(address(this)), // recipient
                false // toInternalBalance
            );

        balancerVault.batchSwap(
            IBalancerVault.SwapKind.GIVEN_IN,
            withdrawSwapSteps,
            swapPathAssets,
            _funds,
            withdrawLimits,
            block.timestamp
        );
    }
}
