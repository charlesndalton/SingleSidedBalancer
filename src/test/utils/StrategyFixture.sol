// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;
pragma abicoder v2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ExtendedTest} from "./ExtendedTest.sol";
import {Vm} from "forge-std/Vm.sol";
import {IVault} from "../../interfaces/Yearn/Vault.sol";
import {IAsset} from "../../interfaces/Balancer/IAsset.sol";
import {BaseStrategy} from "@yearnvaults/contracts/BaseStrategy.sol";

import {BaseSingleSidedBalancer, BasicSingleSidedBalancer, PhantomSingleSidedBalancer} from "../../SingleSidedBalancer.sol";

// Artifact paths for deploying from the deps folder, assumes that the command is run from
// the project root.
string constant vaultArtifact = "artifacts/Vault.json";

// Base fixture deploying Vault
contract StrategyFixture is ExtendedTest {
    using SafeERC20 for IERC20;

    BaseSingleSidedBalancer[] public strategyFixtures;

    IERC20 public weth;

    enum SSBType {
        BASIC,
        PHANTOM
    }

    mapping(string => address) internal tokenAddrs;
    mapping(string => uint256) internal tokenPrices;
    // Have 1 bpt vault per want
    mapping(string => address) internal bptVaults;
    mapping(string => SSBType) internal ssbTypes;
    mapping(string => uint256) internal maxSlippagesIn;
    mapping(string => uint256) internal maxSlippagesOut;
    mapping(string => uint256) internal maxSingleInvests;

    // only relevant for phantom BPT pools
    mapping(string => bytes32[]) internal swapPathPoolIDs;
    mapping(string => IAsset[]) internal swapPathAssets;
    mapping(string => uint256[]) internal swapPathAssetIndexes;

    address public gov = 0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52;
    address public user = address(1);
    address public whale = address(2);
    address public rewards = address(3);
    address public guardian = address(4);
    address public strategist = address(5); // strategy strategist and vault manager
    address public keeper = address(6);

    // Used for integer approximation
    uint256 public constant DELTA = 10**2;
    uint256 public minFuzzAmt = 100 ether; // 10 cents
    uint256 public maxFuzzAmt = 25_000_000 ether; // $25M

    function setUp() public virtual {
        _setTokenPrices();
        _setTokenAddrs();
        _setBPTVaults();
        _setSSBTypes();
        _setMaxSlippagesIn();
        _setMaxSlippagesOut();
        _setMaxSingleInvests();
        _setSwapPathPoolIDs();
        _setSwapPathAssets();
        _setSwapPathAssetIndexes();

        // // Choose a token from the tokenAddrs mapping, see _setTokenAddrs for options
        // weth = IERC20(tokenAddrs["WETH"]);

        string[2] memory _tokensToTest = ["USDC", "DAI"];

        for (uint8 i = 0; i < _tokensToTest.length; ++i) {
            string memory _tokenToTest = _tokensToTest[i];
            IERC20 _want = IERC20(tokenAddrs[_tokenToTest]);

            (address _vault, address _strategy) = deployVaultAndStrategy(
                _tokenToTest
            );

            strategyFixtures.push(BaseSingleSidedBalancer(_strategy));

            vm.label(
                address(_vault),
                string(abi.encodePacked(_tokenToTest, "Vault"))
            );
            vm.label(
                address(_strategy),
                string(abi.encodePacked(_tokenToTest, "Strategy"))
            );
            vm.label(address(_want), _tokenToTest);
        }

        vm.label(gov, "Gov");
        vm.label(user, "User");
        vm.label(whale, "Whale");
        vm.label(rewards, "Rewards");
        vm.label(guardian, "Guardian");
        vm.label(strategist, "Strategist");
        vm.label(keeper, "Keeper");

        // do here additional setup
    }

    // Deploys a vault
    function deployVault(
        address _token,
        address _gov,
        address _rewards,
        string memory _name,
        string memory _symbol,
        address _guardian,
        address _management
    ) public returns (address) {
        vm.prank(_gov);
        address _vaultAddress = deployCode(vaultArtifact);
        IVault _vault = IVault(_vaultAddress);

        vm.prank(_gov);
        _vault.initialize(
            _token,
            _gov,
            _rewards,
            _name,
            _symbol,
            _guardian,
            _management
        );

        vm.prank(_gov);
        _vault.setDepositLimit(type(uint256).max);

        return address(_vault);
    }

    function deployBasicSSB(
        address _vault,
        address _bptVault,
        uint256 _maxSlippageIn,
        uint256 _maxSlippageOut,
        uint256 _maxSingleInvest
    ) internal returns (address) {
        BasicSingleSidedBalancer _ssb = new BasicSingleSidedBalancer(
            _vault,
            _bptVault,
            _maxSlippageIn,
            _maxSlippageOut,
            _maxSingleInvest
        );

        return address(_ssb);
    }

    function deployPhantomSSB(
        address _vault,
        address _bptVault,
        uint256 _maxSlippageIn,
        uint256 _maxSlippageOut,
        uint256 _maxSingleInvest,
        bytes32[] memory _swapPathPoolIDs,
        IAsset[] memory _swapPathAssets,
        uint256[] memory _swapPathAssetIndexes
    ) internal returns (address) {
        PhantomSingleSidedBalancer _ssb = new PhantomSingleSidedBalancer(
            _vault,
            _bptVault,
            _maxSlippageIn,
            _maxSlippageOut,
            _maxSingleInvest,
            _swapPathPoolIDs,
            _swapPathAssets,
            _swapPathAssetIndexes
        );

        return address(_ssb);
    }

    // Deploys a vault and strategy attached to vault
    function deployVaultAndStrategy(string memory _tokenToTest)
        public
        returns (address _vaultAddr, address _strategyAddr)
    {
        address _token = tokenAddrs[_tokenToTest];
        _vaultAddr = deployVault(
            _token,
            gov,
            rewards,
            "",
            "",
            guardian,
            strategist
        );
        IVault _vault = IVault(_vaultAddr);

        vm.prank(strategist);

        SSBType _ssbType = ssbTypes[_tokenToTest];

        if (_ssbType == SSBType.BASIC) {
            _strategyAddr = deployBasicSSB(
                _vaultAddr,
                bptVaults[_tokenToTest],
                maxSlippagesIn[_tokenToTest],
                maxSlippagesOut[_tokenToTest],
                maxSingleInvests[_tokenToTest]
            );
        } else if (_ssbType == SSBType.PHANTOM) {
            _strategyAddr = deployPhantomSSB(
                _vaultAddr,
                bptVaults[_tokenToTest],
                maxSlippagesIn[_tokenToTest],
                maxSlippagesOut[_tokenToTest],
                maxSingleInvests[_tokenToTest],
                swapPathPoolIDs[_tokenToTest],
                swapPathAssets[_tokenToTest],
                swapPathAssetIndexes[_tokenToTest]
            );
        }
        BaseSingleSidedBalancer _strategy = BaseSingleSidedBalancer(
            _strategyAddr
        );

        vm.prank(strategist);
        _strategy.setKeeper(keeper);

        vm.prank(gov);
        _vault.addStrategy(_strategyAddr, 10_000, 0, type(uint256).max, 1_000);

        skip(1); // can't harvest in same block you add
        vm.prank(strategist);
        _strategy.setHealthCheck(address(0)); // otherwise, it doesn't allow even 1 bip losses

        return (address(_vault), address(_strategy));
    }

    function simulateYield(BaseSingleSidedBalancer strategy) internal {
        address bptToken = address(strategy.balancerPool());
        IVault autoCompounder = strategy.bptVault();
        BaseStrategy autoCompounderStrategy = BaseStrategy(
            autoCompounder.withdrawalQueue(0)
        );

        uint256 autoCompounderAssets = autoCompounder.totalAssets();
        deal(
            bptToken,
            address(autoCompounderStrategy),
            autoCompounderAssets / 200
        ); // 0.5% gain
        vm.prank(autoCompounderStrategy.strategist());
        autoCompounderStrategy.harvest();
        skip(6 hours);
    }

    function _setTokenAddrs() internal {
        tokenAddrs["WBTC"] = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        tokenAddrs["YFI"] = 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e;
        tokenAddrs["WETH"] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        tokenAddrs["LINK"] = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
        tokenAddrs["USDT"] = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        tokenAddrs["DAI"] = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        tokenAddrs["USDC"] = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    }

    function _setTokenPrices() internal {
        tokenPrices["WBTC"] = 60_000;
        tokenPrices["WETH"] = 4_000;
        tokenPrices["LINK"] = 20;
        tokenPrices["YFI"] = 35_000;
        tokenPrices["USDT"] = 1;
        tokenPrices["USDC"] = 1;
        tokenPrices["DAI"] = 1;
    }

    function _setBPTVaults() internal {
        bptVaults["USDC"] = 0xA9412Ffd7E0866755ae0dda3318470A61F62abe8; // FUD
        vm.label(0xA9412Ffd7E0866755ae0dda3318470A61F62abe8, "FUDVault");
        bptVaults["DAI"] = 0xCf9D867d869ab6aAAC1b9406ED3175aEb9FAb49C; // Boosted
        vm.label(0xCf9D867d869ab6aAAC1b9406ED3175aEb9FAb49C, "BoostedVault");
    }

    function _setSSBTypes() internal {
        ssbTypes["USDC"] = SSBType.BASIC;
        ssbTypes["DAI"] = SSBType.PHANTOM;
    }

    function _setMaxSlippagesIn() internal {
        maxSlippagesIn["USDC"] = 30;
        maxSlippagesIn["DAI"] = 50;
    }

    function _setMaxSlippagesOut() internal {
        maxSlippagesOut["USDC"] = 50;
        maxSlippagesIn["DAI"] = 50;
    }

    function _setMaxSingleInvests() internal {
        maxSingleInvests["USDC"] = 250_000 * 1e6;
        maxSingleInvests["DAI"] = 250_000 * 1e18;
    }

    function _setSwapPathPoolIDs() internal {
        swapPathPoolIDs["DAI"] = new bytes32[](2);
        swapPathPoolIDs["DAI"][
            0
        ] = 0x804cdb9116a10bb78768d3252355a1b18067bf8f0000000000000000000000fb; // boosted DAI pool
        swapPathPoolIDs["DAI"][
            1
        ] = 0x7b50775383d3d6f0215a8f290f2c9e2eebbeceb20000000000000000000000fe; // boosted USD pool
    }

    function _setSwapPathAssets() internal {
        swapPathAssets["DAI"] = new IAsset[](3);
        swapPathAssets["DAI"][0] = IAsset(
            0x6B175474E89094C44Da98b954EedeAC495271d0F
        ); // DAI
        swapPathAssets["DAI"][1] = IAsset(
            0x7B50775383d3D6f0215A8F290f2C9e2eEBBEceb2
        ); // bb-a-USD
        swapPathAssets["DAI"][2] = IAsset(
            0x804CdB9116a10bB78768D3252355a1b18067bF8f
        ); // bb-a-DAI
    }

    function _setSwapPathAssetIndexes() internal {
        swapPathAssetIndexes["DAI"] = new uint256[](3);
        swapPathAssetIndexes["DAI"][0] = 0;
        swapPathAssetIndexes["DAI"][1] = 2;
        swapPathAssetIndexes["DAI"][2] = 1;
    }

    // mapping(string => bytes32[]) internal swapPathPoolIDs;
    // mapping(string => IAsset[]) internal swapPathAssets;
    // mapping(string => uint256[]) internal swapPathAssetIndexes;
}
