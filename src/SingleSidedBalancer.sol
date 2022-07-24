// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy, StrategyParams, VaultAPI} from "@yearnvaults/contracts/BaseStrategy.sol";

import "@openzeppelin/contracts/utils/math/Math.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@yearnvaults/contracts/yToken.sol";

import {IBalancerPool} from "./interfaces/Balancer/IBalancerPool.sol";
import {IBalancerVault} from "./interfaces/Balancer/IBalancerVault.sol";

/* A few key things can change between underlying pools. For example, although we enter
 * most pools through balancerVault.joinPool(), linear pools such as the aave boosted pool
 * don't support this, and we need to enter them through batch swaps. Common logic inside
 * 'BaseSingleSidedBalancer' and details are implemented in extending strategies such as
 * 'SingleSidedBalancerLinearPool'.
 */
abstract contract BaseSingleSidedBalancer is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    uint256 public lastDepositTime;

    VaultAPI public bptVault;
    IBalancerPool public balancerPool;
    uint256 public maxSlippageIn; // bips
    uint256 public maxSlippageOut; // bips
    uint256 public maxSingleInvest;
    uint256 public minDepositPeriod; // seconds
    bool public withdrawProtection;
    uint256 internal constant MAX_BPS = 10000;

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    IERC20 internal constant BAL =
        IERC20(0xba100000625a3754423978a60c9317c58a424e3D);
    IBalancerVault internal constant balancerVault =
        IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    // === DEPLOYMENT FUNCTIONS ===

    // solhint-disable-next-line no-empty-blocks
    constructor(address _vault) BaseStrategy(_vault) {}

    // extensions can override this
    function _initializeStrat(address _bptVault) internal virtual {
        // health.ychad.eth
        healthCheck = address(0xDDCea799fF1699e98EDF118e0629A974Df7DF012);

        bptVault = VaultAPI(_bptVault);

        balancerPool = IBalancerPool(bptVault.token());
        bytes32 _poolID = balancerPool.getPoolId();

        (IERC20[] memory tokens, , ) = balancerVault.getPoolTokens(_poolID);
        uint256 _numTokens = uint8(tokens.length);
        require(_numTokens > 0, "Empty Pool");

        uint256 _tokenIndex = type(uint8).max;
        for (uint8 i = 0; i < _numTokens; i++) {
            if (tokens[i] == want) {
                _tokenIndex = i;
            }
        }
        require(_tokenIndex != type(uint8).max, "token not supported in pool!");
    }

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
        // ASSUMPTION: balancer pool tokens are always 18 decimals
        return (_balance * _pricePerShare) / 1e18;
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

    function investWantIntoBalancerPool(uint256 _wantAmount) internal virtual;

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (block.timestamp - lastDepositTime < minDepositPeriod) {
            return;
        }

        uint256 _balanceOfWant = want.balanceOf(address(this));
        if (_balanceOfWant > _debtOutstanding) {
            uint256 _amountToInvest = _balanceOfWant - _debtOutstanding;
            _amountToInvest = Math.min(_amountToInvest, maxSingleInvest);
            investWantIntoBalancerPool(_amountToInvest);
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

            (, uint256 _withdrawalLoss) = withdrawSome(_toWithdraw);
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
            } else if (_liquidAssets < _debtPayment - _profit) {
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
            (_liquidatedAmount, _loss) = withdrawSome(_toWithdraw);
        }

        _liquidatedAmount = Math.min(
            _amountNeeded,
            _liquidatedAmount + _liquidAssets
        );
    }

    // safe to request more than we have
    function liquidateBPTsToWant(uint256 _bptAmount) internal virtual;

    function withdrawSome(uint256 _amountToWithdraw)
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
            liquidateBPTsToWant(_bptsToLiquidate);
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
        // we can request a lot, but don't use max because of overflow
        (_amountFreed, ) = liquidatePosition(1e36);
    }

    // === MISC FUNCTIONS ===

    // Examples: SSB_DAI_NORMAL_FUD, SSB_USDC_PHANTOM_bb-a-USD
    function extensionName() internal view virtual returns (string memory);

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

    function updateMinDepositPeriod(uint256 _minDepositPeriod)
        public
        onlyVaultManagers
    {
        minDepositPeriod = _minDepositPeriod;
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

/* All extensions must implement the following:
 * function extensionName() returns (string memory)
 * function investWantIntoBalancerPool(uint256 _wantAmount)
 * function liquidateBPTsToWant(uint256 _bptAmount)
 *
 * Extensions can optionally add other functions which allow vault managers
 * to manually manage the position.
 */
