// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;

import {StrategyFixture} from "./utils/StrategyFixture.sol";
import {StrategyParams, IVault} from "../interfaces/Yearn/Vault.sol";
import {BaseSingleSidedBalancer} from "../SingleSidedBalancer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@yearnvaults/contracts/yToken.sol";

contract StrategyMigrationTest is StrategyFixture {
    function setUp() public override {
        super.setUp();
    }

    // TODO: Add tests that show proper migration of the strategy to a newer one
    // Use another copy of the strategy to simmulate the migration
    // Show that nothing is lost.
    function testMigration(uint256 _fuzzAmount) public {
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
            skip(1);
            vm.prank(strategist);
            strategy.harvest();
            assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

            // Migrate to a new strategy
            vm.prank(strategist);

            string memory _wantSymbol = IERC20Metadata(address(want)).symbol();
            BaseSingleSidedBalancer newStrategy;
            SSBType _ssbType = ssbTypes[_wantSymbol];
            if (_ssbType == SSBType.BASIC) {
                newStrategy = BaseSingleSidedBalancer(
                    deployBasicSSB(
                        address(vault),
                        bptVaults[_wantSymbol],
                        maxSlippagesIn[_wantSymbol],
                        maxSlippagesOut[_wantSymbol],
                        maxSingleInvests[_wantSymbol],
                        minDepositPeriods[_wantSymbol]
                    )
                );
            } else if (_ssbType == SSBType.PHANTOM) {
                newStrategy = BaseSingleSidedBalancer(
                    deployPhantomSSB(
                        address(vault),
                        bptVaults[_wantSymbol],
                        maxSlippagesIn[_wantSymbol],
                        maxSlippagesOut[_wantSymbol],
                        maxSingleInvests[_wantSymbol],
                        minDepositPeriods[_wantSymbol],
                        swapPathPoolIDs[_wantSymbol],
                        swapPathAssets[_wantSymbol],
                        swapPathAssetIndexes[_wantSymbol]
                    )
                );
            }
            vm.prank(gov);
            vault.migrateStrategy(address(strategy), address(newStrategy));
            assertRelApproxEq(
                newStrategy.estimatedTotalAssets(),
                _amount,
                DELTA
            );
        }
    }
}
