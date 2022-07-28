// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;
import "forge-std/console.sol";

import {StrategyFixture} from "./utils/StrategyFixture.sol";
import {StrategyParams, IVault} from "../interfaces/Yearn/Vault.sol";
import {BaseSingleSidedBalancer} from "../SingleSidedBalancer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@yearnvaults/contracts/yToken.sol";
import {BaseStrategy} from "@yearnvaults/contracts/BaseStrategy.sol";

contract StrategyOperationsTest is StrategyFixture {
    // setup is run on before each test
    function setUp() public override {
        // setup vault
        super.setUp();
    }

    /// Test Operations
    function testStrategyOperation(uint256 _fuzzAmount) public {
        vm.assume(_fuzzAmount > minFuzzAmt && _fuzzAmount < maxFuzzAmt);
        for (uint8 i = 0; i < strategyFixtures.length; ++i) {
            BaseSingleSidedBalancer strategy = strategyFixtures[i];
            IVault vault = IVault(address(strategy.vault()));
            IERC20 want = IERC20(strategy.want());

            uint256 _amount = _fuzzAmount;
            uint8 _wantDecimals = IERC20Metadata(address(want)).decimals();
            if (_wantDecimals != 18) {
                uint256 _decimalDifference = 18 - _wantDecimals;

                _amount = _amount / (10**_decimalDifference);
            }
            console.log("Amount", _amount);
            console.log("User balance b4", want.balanceOf(address(user)));

            deal(address(want), user, _amount);
            console.log("User balance", want.balanceOf(address(user)));

            uint256 balanceBefore = want.balanceOf(address(user));
            vm.prank(user);
            want.approve(address(vault), _amount);
            vm.prank(user);
            vault.deposit(_amount);
            assertRelApproxEq(want.balanceOf(address(vault)), _amount, DELTA);

            skip(3 minutes);
            vm.prank(strategist);
            strategy.harvest();
            assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

            // tend
            vm.prank(strategist);
            strategy.tend();

            vm.startPrank(user);
            vault.withdraw(vault.balanceOf(user), user, 10); // allow 10 bips loss
            vm.stopPrank();

            assertRelApproxEq(want.balanceOf(user), balanceBefore, DELTA);
        }
    }

    function testEmergencyExit(uint256 _fuzzAmount) public {
        vm.assume(_fuzzAmount > minFuzzAmt && _fuzzAmount < maxFuzzAmt);
        for (uint8 i = 0; i < strategyFixtures.length; ++i) {
            BaseSingleSidedBalancer strategy = strategyFixtures[i];
            IVault vault = IVault(address(strategy.vault()));
            IERC20 want = IERC20(strategy.want());

            uint256 _amount = _fuzzAmount;
            uint8 _wantDecimals = IERC20Metadata(address(want)).decimals();
            if (_wantDecimals != 18) {
                uint256 _decimalDifference = 18 - _wantDecimals;

                _amount = _amount / (10**_decimalDifference);
            }

            deal(address(want), user, _amount);
            // Deposit to the vault
            vm.prank(user);
            want.approve(address(vault), _amount);
            vm.prank(user);
            vault.deposit(_amount);
            skip(1);
            vm.prank(strategist);
            strategy.harvest();
            assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

            // set emergency and exit
            vm.prank(gov);
            strategy.setEmergencyExit();
            skip(1);
            vm.prank(strategist);
            strategy.harvest();
            assertLt(strategy.estimatedTotalAssets(), _amount);
        }
    }

    function testProfitableHarvest(uint256 _fuzzAmount) public {
        vm.assume(_fuzzAmount > minFuzzAmt && _fuzzAmount < maxFuzzAmt);
        for (uint8 i = 0; i < strategyFixtures.length; ++i) {
            BaseSingleSidedBalancer strategy = strategyFixtures[i];
            IVault vault = IVault(address(strategy.vault()));
            IERC20 want = IERC20(strategy.want());

            uint256 _amount = _fuzzAmount;
            uint8 _wantDecimals = IERC20Metadata(address(want)).decimals();
            if (_wantDecimals != 18) {
                uint256 _decimalDifference = 18 - _wantDecimals;

                _amount = _amount / (10**_decimalDifference);
            }

            deal(address(want), user, _amount);
            // Deposit to the vault
            vm.prank(user);
            want.approve(address(vault), _amount);
            vm.prank(user);
            vault.deposit(_amount);
            assertRelApproxEq(want.balanceOf(address(vault)), _amount, DELTA);

            uint256 beforePps = vault.pricePerShare();

            // Harvest 1: Send funds through the strategy
            skip(1);
            vm.prank(strategist);
            strategy.harvest();
            assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

            // simulate yield by throwing some bpts in the underlying vault
            address bptToken = address(strategy.balancerPool());
            IVault autoCompounder = strategy.bptVault();
            BaseStrategy autoCompounderStrategy = BaseStrategy(
                autoCompounder.withdrawalQueue(0)
            );
            uint256 autoCompounderDebt = autoCompounder.totalDebt();
            deal(
                bptToken,
                address(autoCompounderStrategy),
                autoCompounderDebt / 200
            ); // 0.5% gain
            vm.prank(autoCompounderStrategy.strategist());
            autoCompounderStrategy.harvest();
            skip(6 hours);

            // Harvest 2: Realize profit
            skip(1);
            vm.prank(strategist);
            strategy.harvest();
            skip(6 hours);

            uint256 profit = want.balanceOf(address(vault));
            assertGt(strategy.estimatedTotalAssets() + profit, _amount);
            assertGt(vault.pricePerShare(), beforePps);
        }
    }

    function testChangeDebt(uint256 _fuzzAmount) public {
        vm.assume(_fuzzAmount > minFuzzAmt && _fuzzAmount < maxFuzzAmt);
        for (uint8 i = 0; i < strategyFixtures.length; ++i) {
            BaseSingleSidedBalancer strategy = strategyFixtures[i];
            IVault vault = IVault(address(strategy.vault()));
            IERC20 want = IERC20(strategy.want());

            uint256 _amount = _fuzzAmount;
            uint8 _wantDecimals = IERC20Metadata(address(want)).decimals();
            if (_wantDecimals != 18) {
                uint256 _decimalDifference = 18 - _wantDecimals;

                _amount = _amount / (10**_decimalDifference);
            }

            deal(address(want), user, _amount);
            // Deposit to the vault and harvest
            vm.prank(user);
            want.approve(address(vault), _amount);
            vm.prank(user);
            vault.deposit(_amount);
            vm.prank(gov);
            vault.updateStrategyDebtRatio(address(strategy), 5_000);
            skip(1);
            vm.prank(strategist);
            strategy.harvest();
            uint256 half = uint256(_amount / 2);
            assertRelApproxEq(strategy.estimatedTotalAssets(), half, DELTA);

            vm.prank(gov);
            vault.updateStrategyDebtRatio(address(strategy), 10_000);
            skip(1);
            vm.prank(strategist);
            strategy.harvest();
            assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

            // In order to pass these tests, you will need to implement prepareReturn.
            // TODO: uncomment the following lines.
            // vm.prank(gov);
            // vault.updateStrategyDebtRatio(address(strategy), 5_000);
            // skip(1);
            // vm.prank(strategist);
            // strategy.harvest();
            // assertRelApproxEq(strategy.estimatedTotalAssets(), half, DELTA);
        }
    }

    function testProfitableHarvestOnDebtChange(uint256 _fuzzAmount) public {
        vm.assume(_fuzzAmount > minFuzzAmt && _fuzzAmount < maxFuzzAmt);
        for (uint8 i = 0; i < strategyFixtures.length; ++i) {
            BaseSingleSidedBalancer strategy = strategyFixtures[i];
            IVault vault = IVault(address(strategy.vault()));
            IERC20 want = IERC20(strategy.want());

            uint256 _amount = _fuzzAmount;
            uint8 _wantDecimals = IERC20Metadata(address(want)).decimals();
            if (_wantDecimals != 18) {
                uint256 _decimalDifference = 18 - _wantDecimals;

                _amount = _amount / (10**_decimalDifference);
            }

            deal(address(want), user, _amount);
            // Deposit to the vault
            vm.prank(user);
            want.approve(address(vault), _amount);
            vm.prank(user);
            vault.deposit(_amount);
            assertRelApproxEq(want.balanceOf(address(vault)), _amount, DELTA);

            uint256 beforePps = vault.pricePerShare();

            // Harvest 1: Send funds through the strategy
            skip(1);
            vm.prank(strategist);
            strategy.harvest();
            assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

            // TODO: Add some code before harvest #2 to simulate earning yield

            vm.prank(gov);
            vault.updateStrategyDebtRatio(address(strategy), 5_000);

            // In order to pass these tests, you will need to implement prepareReturn.
            // TODO: uncomment the following lines.
            /*
            // Harvest 2: Realize profit
            skip(1);
            vm.prank(strategist);
            strategy.harvest();
            //Make sure we have updated the debt ratio of the strategy
            assertRelApproxEq(
                strategy.estimatedTotalAssets(),
                _amount / 2,
                DELTA
            );
            skip(6 hours);

            //Make sure we have updated the debt and made a profit
            uint256 vaultBalance = want.balanceOf(address(vault));
            StrategyParams memory params = vault.strategies(address(strategy));
            //Make sure we got back profit + half the deposit
            assertRelApproxEq(
                _amount / 2 + params.totalGain,
                vaultBalance,
                DELTA
            );
            assertGe(vault.pricePerShare(), beforePps);
            */
        }
    }

    // removing this test for now because of foundry bug
    // function testSweep(uint256 _fuzzAmount) public {
    //     vm.assume(_fuzzAmount > minFuzzAmt && _fuzzAmount < maxFuzzAmt);
    //     for (uint8 i = 0; i < strategyFixtures.length; ++i) {
    //         BaseSingleSidedBalancer strategy = strategyFixtures[i];
    //         IVault vault = IVault(address(strategy.vault()));
    //         IERC20 want = IERC20(strategy.want());

    //         uint256 _amount = _fuzzAmount;
    //         uint8 _wantDecimals = IERC20Metadata(address(want)).decimals();
    //         if (_wantDecimals != 18) {
    //             uint256 _decimalDifference = 18 - _wantDecimals;

    //             _amount = _amount / (10**_decimalDifference);
    //         }

    //         deal(address(want), user, _amount);
    //         // Strategy want token doesn't work
    //         vm.prank(user);
    //         want.transfer(address(strategy), _amount);
    //         assertEq(address(want), address(strategy.want()));
    //         assertGt(want.balanceOf(address(strategy)), 0);

    //         vm.prank(gov);
    //         vm.expectRevert("!want");
    //         strategy.sweep(address(want));

    //         // Vault share token doesn't work
    //         vm.prank(gov);
    //         vm.expectRevert();
    //         strategy.sweep(address(vault));

    //         uint256 beforeBalance = weth.balanceOf(gov);
    //         uint256 wethAmount = 1 ether;
    //         deal(address(weth), user, wethAmount);
    //         vm.prank(user);
    //         weth.transfer(address(strategy), wethAmount);
    //         assertNeq(address(weth), address(strategy.want()));
    //         assertEq(weth.balanceOf(user), 0);
    //         vm.prank(gov);
    //         strategy.sweep(address(weth));
    //         assertRelApproxEq(
    //             weth.balanceOf(gov),
    //             wethAmount + beforeBalance,
    //             DELTA
    //         );
    //     }
    // }

    function testTriggers(uint256 _fuzzAmount) public {
        vm.assume(_fuzzAmount > minFuzzAmt && _fuzzAmount < maxFuzzAmt);
        for (uint8 i = 0; i < strategyFixtures.length; ++i) {
            BaseSingleSidedBalancer strategy = strategyFixtures[i];
            IVault vault = IVault(address(strategy.vault()));
            IERC20 want = IERC20(strategy.want());

            uint256 _amount = _fuzzAmount;
            uint8 _wantDecimals = IERC20Metadata(address(want)).decimals();
            if (_wantDecimals != 18) {
                uint256 _decimalDifference = 18 - _wantDecimals;

                _amount = _amount / (10**_decimalDifference);
            }

            deal(address(want), user, _amount);

            // Deposit to the vault and harvest
            vm.prank(user);
            want.approve(address(vault), _amount);
            vm.prank(user);
            vault.deposit(_amount);
            vm.prank(gov);
            vault.updateStrategyDebtRatio(address(strategy), 5_000);
            skip(1);
            vm.prank(strategist);
            strategy.harvest();

            strategy.harvestTrigger(0);
            strategy.tendTrigger(0);
        }
    }
}
