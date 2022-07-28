// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;

import {StrategyFixture} from "./utils/StrategyFixture.sol";
import {StrategyParams, IVault} from "../interfaces/Yearn/Vault.sol";
import {BaseSingleSidedBalancer} from "../SingleSidedBalancer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@yearnvaults/contracts/yToken.sol";


contract StrategyShutdownTest is StrategyFixture {
    function setUp() public override {
        super.setUp();
    }

    function testVaultShutdownCanWithdraw(uint256 _fuzzAmount) public {
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

            uint256 bal = want.balanceOf(user);
            if (bal > 0) {
                vm.prank(user);
                want.transfer(address(0), bal);
            }

            // Harvest 1: Send funds through the strategy
            skip(7 hours);
            vm.prank(strategist);
            strategy.harvest();
            assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

            // Set Emergency
            vm.prank(gov);
            vault.setEmergencyShutdown(true);

            // Withdraw (does it work, do you get what you expect)
            vm.startPrank(user);
            vault.withdraw(vault.balanceOf(user), user, 10); // allow 10 bips loss
            vm.stopPrank();

            assertRelApproxEq(want.balanceOf(user), _amount, DELTA);
        }
    }

    function testBasicShutdown(uint256 _fuzzAmount) public {
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

            // Harvest 1: Send funds through the strategy
            skip(1 days);
            vm.prank(strategist);
            strategy.harvest();
            assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

            // Earn interest
            skip(1 days);

            // Harvest 2: Realize profit
            vm.prank(strategist);
            strategy.harvest();
            skip(6 hours);

            // Set emergency
            vm.prank(strategist);
            strategy.setEmergencyExit();

            vm.prank(strategist);
            strategy.harvest(); // Remove funds from strategy

            assertEq(want.balanceOf(address(strategy)), 0);
            assertRelApproxEq(want.balanceOf(address(vault)), _amount, DELTA); // The vault has all funds
            // NOTE: May want to tweak this based on potential loss during migration
        }       
    }
}
