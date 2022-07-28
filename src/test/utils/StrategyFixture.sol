// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;
pragma abicoder v2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ExtendedTest} from "./ExtendedTest.sol";
import {Vm} from "forge-std/Vm.sol";
import {IVault} from "../../interfaces/Yearn/Vault.sol";

import {BaseSingleSidedBalancer, BasicSingleSidedBalancer} from "../../SingleSidedBalancer.sol";

// Artifact paths for deploying from the deps folder, assumes that the command is run from
// the project root.
string constant vaultArtifact = "artifacts/Vault.json";

// Base fixture deploying Vault
contract StrategyFixture is ExtendedTest {
    using SafeERC20 for IERC20;

    BaseSingleSidedBalancer[] public strategyFixtures;

    IERC20 public weth;

    enum SSBType {
        BASIC
    }

    mapping(string => address) internal tokenAddrs;
    mapping(string => uint256) internal tokenPrices;
    // Have 1 bpt vault per want
    mapping(string => address) internal bptVaults;
    mapping(string => SSBType) internal ssbTypes;
    mapping(string => uint256) internal maxSlippagesIn;
    mapping(string => uint256) internal maxSlippagesOut;
    mapping(string => uint256) internal maxSingleInvests;
    mapping(string => uint256) internal minDepositPeriods;

    address public gov = 0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52;
    address public user = address(1);
    address public whale = address(2);
    address public rewards = address(3);
    address public guardian = address(4);
    address public management = address(5);
    address public strategist = address(6);
    address public keeper = address(7);

    // Used for integer approximation
    uint256 public constant DELTA = 10**3;
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
        _setMinDepositPeriods();

        // // Choose a token from the tokenAddrs mapping, see _setTokenAddrs for options
        // weth = IERC20(tokenAddrs["WETH"]);

        string[1] memory _tokensToTest = ["USDC"];

        for (uint8 i = 0; i < _tokensToTest.length; ++i) {
            string memory _tokenToTest = _tokensToTest[i];
            IERC20 _want = IERC20(tokenAddrs[_tokenToTest]);

            (address _vault, address _strategy) = deployVaultAndStrategy(
                address(_want),
                _tokenToTest,
                "",
                ""
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
        vm.label(management, "Management");
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
        uint256 _maxSingleInvest,
        uint256 _minDepositPeriod
    ) internal returns (address) {
        BasicSingleSidedBalancer _ssb = new BasicSingleSidedBalancer(
            _vault,
            _bptVault,
            _maxSlippageIn,
            _maxSlippageOut,
            _maxSingleInvest,
            _minDepositPeriod
        );

        return address(_ssb);
    }

    // Deploys a vault and strategy attached to vault
    function deployVaultAndStrategy(
        address _token,
        string memory _tokenToTest,
        string memory _name,
        string memory _symbol
    ) public returns (address _vaultAddr, address _strategyAddr) {
        _vaultAddr = deployVault(
            _token,
            gov,
            rewards,
            _name,
            _symbol,
            guardian,
            management
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
                maxSingleInvests[_tokenToTest],
                minDepositPeriods[_tokenToTest]
            );
        }
        BaseSingleSidedBalancer _strategy = BaseSingleSidedBalancer(
            _strategyAddr
        );

        vm.prank(strategist);
        _strategy.setKeeper(keeper);

        vm.prank(gov);
        _vault.addStrategy(_strategyAddr, 10_000, 0, type(uint256).max, 1_000);

        return (address(_vault), address(_strategy));
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
    }

    function _setSSBTypes() internal {
        ssbTypes["USDC"] = SSBType.BASIC;
    }

    function _setMaxSlippagesIn() internal {
        maxSlippagesIn["USDC"] = 50;
    }

    function _setMaxSlippagesOut() internal {
        maxSlippagesOut["USDC"] = 50;
    }

    function _setMaxSingleInvests() internal {
        maxSingleInvests["USDC"] = 250_000 * 1e6;
    }

    function _setMinDepositPeriods() internal {
        minDepositPeriods["USDC"] = 3 days;
    }
}
