// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {NvidiaTokenFixture} from "./helpers/NvidiaTokenFixture.sol";
import {NvidiaTokenStateHandler} from "./handlers/NvidiaTokenStateHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
contract NvidiaTokenStatefulTest is NvidiaTokenFixture {
    NvidiaTokenStateHandler internal handler;
    address[8] internal actors;

    function setUp() public override {
        super.setUp();
        actors = [address(factory), pool, distributor, JENSEN, alice, bob, spender, address(token)];
        for (uint256 i = 1; i < 7; ++i) {
            _fund(actors[i], SUPPLY / 10);
        }
        handler = new NvidiaTokenStateHandler(token, factory, actors);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.approve.selector;
        selectors[1] = handler.transfer.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.attemptTransferFrom.selector;
        selectors[4] = handler.rejectTransfer.selector;
        selectors[5] = handler.publishDistributor.selector;
        selectors[6] = handler.setFactoryAvailable.selector;
        selectors[7] = handler.selfTransfer.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_everyHolderMatchesIndependentLedger() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), handler.expectedBalance(i), "holder ledger diverged");
        }
    }

    function invariant_supplyEqualsAllBalancesAndInitialLessBurns() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(token.totalSupply(), sum, "balances do not add up to circulating supply");
        assertEq(token.totalSupply() + handler.burned(), SUPPLY, "burn ledger diverged");
        assertEq(token.balanceOf(address(0)), 0, "burn must not accumulate a zero-address balance");
    }

    function invariant_allowancesMatchPersistentAuthorizations() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(
                    token.allowance(actors[i], actors[j]),
                    handler.expectedAllowance(actors[i], actors[j]),
                    "an approval was lost, created or spent incorrectly"
                );
            }
        }
    }

    function invariant_discoveryMatchesPublicationAndSuccessfulCalls() public view {
        assertEq(token.distributor(), handler.cached() ? distributor : address(0));
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.isExempt(actors[i]), handler.expectedExempt(i), "exemption state diverged");
        }
        assertFalse(token.isExempt(address(0)));
    }

    /// @dev A deterministic reachability check guards against a vacuous handler: success, failure,
    /// self-transfer, donation, revoked approval, delayed discovery and recovery all execute.
    function test_handlerExercisesMeaningfulSuccessAndFailureSequences() public {
        handler.transfer(4, 5, 0, 5); // ordinary transfer of 200
        _checkAll();
        handler.transferFrom(4, 3, 3, 0, 5); // unlimited allowance to Jensen
        _checkAll();
        handler.approve(4, 3, 0, 2); // revoke Alice -> spender
        handler.attemptTransferFrom(4, 5, 3, 1);
        _checkAll();
        handler.attemptTransferFrom(5, 4, 3, type(uint256).max); // balance failure, unlimited allowance
        _checkAll();
        handler.selfTransfer(3, 0, 5); // Jensen self-transfer
        _checkAll();
        handler.rejectTransfer(4, 5, false, true);
        handler.rejectTransfer(4, 5, true, false);
        _checkAll();
        handler.transfer(4, 7, 0, 5); // passive token recipient is included in conservation
        _checkAll();
        handler.publishDistributor();
        handler.setFactoryAvailable(false);
        handler.transfer(2, 4, 0, 5); // unavailable lookup cannot yet grant an exemption
        _checkAll();
        handler.setFactoryAvailable(true);
        handler.transfer(2, 4, 0, 5); // first successful discovery
        _checkAll();
        handler.setFactoryAvailable(false);
        handler.transfer(2, 4, 0, 5); // cached claims remain live
        _checkAll();
        handler.transfer(4, 1, 0, 5); // a sell into the pool arrives whole
        _checkAll();
        handler.transfer(1, 4, 0, 6); // the pool's whole balance leaves it, taxed
        _checkAll();
        assertEq(token.balanceOf(pool), 0, "the pool's balance drops by the gross amount");
        handler.transfer(0, 4, 0, 6); // exhaust an exempt holder
        _checkAll();
        assertGt(handler.positivePoolOutboundTaxedCalls(), 0);
        assertGt(handler.positiveTaxedCalls(), 0);
        assertGt(handler.positiveExemptCalls(), 0);
        assertGt(handler.positiveDelegatedCalls(), 0);
        assertGe(handler.rejectedCalls(), 4);
        assertTrue(handler.cached());
    }

    function _checkAll() private view {
        invariant_everyHolderMatchesIndependentLedger();
        invariant_supplyEqualsAllBalancesAndInitialLessBurns();
        invariant_allowancesMatchPersistentAuthorizations();
        invariant_discoveryMatchesPublicationAndSuccessfulCalls();
    }
}
