// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {NvidiaToken, ILaunchFactory} from "src/NvidiaToken.sol";
import {NvidiaTokenFixture} from "./helpers/NvidiaTokenFixture.sol";

/// forge-config: default.fuzz.runs = 1000
contract NvidiaTokenDiscoveryTest is NvidiaTokenFixture {
    function test_distributorCanBeDiscoveredAfterAnEarlierUnknownLookup() public {
        _fund(distributor, 2_000);
        vm.prank(distributor);
        assertTrue(token.transfer(alice, 1_000));
        assertEq(token.balanceOf(alice), 985);
        assertEq(token.balanceOf(JENSEN), 5);
        assertEq(token.totalSupply(), SUPPLY - 10);
        assertEq(token.distributor(), address(0));

        factory.setDistributor(LAUNCH, distributor);
        vm.expectEmit(address(token));
        emit NvidiaToken.DistributorCached(distributor);
        vm.prank(distributor);
        assertTrue(token.transfer(bob, 1_000));
        assertEq(token.balanceOf(bob), 1_000, "newly discovered claim must arrive whole");
        assertEq(token.balanceOf(distributor), 0);
        assertEq(token.balanceOf(JENSEN), 5);
        assertEq(token.totalSupply(), SUPPLY - 10);
        assertEq(token.distributor(), distributor);
    }

    function test_exemptionQueriesDoNotCacheOrFreezeAnUnknownDistributor() public {
        factory.setDistributor(LAUNCH, distributor);
        assertTrue(token.isExempt(distributor));
        assertEq(token.distributor(), address(0));
        factory.setDistributor(LAUNCH, bob);
        assertFalse(token.isExempt(distributor));
        assertTrue(token.isExempt(bob));
        assertFalse(token.isExempt(address(0)));
        assertEq(token.distributor(), address(0));
        _fund(bob, 200);
        vm.prank(bob);
        assertTrue(token.transfer(alice, 200));
        assertEq(token.distributor(), bob);
        assertEq(token.balanceOf(alice), 200);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_cachedDistributorSurvivesFactoryFailureAndEmitsOnlyOnce() public {
        factory.setDistributor(LAUNCH, distributor);
        _fund(distributor, 2_000);
        vm.recordLogs();
        vm.prank(distributor);
        assertTrue(token.transfer(alice, 1_000));
        assertEq(_cacheEvents(vm.getRecordedLogs()), 1);

        vm.mockCallRevert(
            address(factory), abi.encodeCall(ILaunchFactory.distributorOf, (LAUNCH)), abi.encodePacked("offline")
        );
        assertTrue(token.isExempt(distributor));
        assertFalse(token.isExempt(bob));
        vm.recordLogs();
        vm.prank(distributor);
        assertTrue(token.transfer(bob, 1_000));
        assertEq(_cacheEvents(vm.getRecordedLogs()), 0);
        assertEq(token.balanceOf(bob), 1_000);
        assertEq(token.distributor(), distributor);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_cachedDistributorCannotBeReplacedByAnotherFactoryAnswer() public {
        factory.setDistributor(LAUNCH, distributor);
        _fund(distributor, 2_000);
        vm.prank(distributor);
        token.transfer(alice, 1_000);
        factory.setDistributor(LAUNCH, spender);
        assertTrue(token.isExempt(distributor));
        assertFalse(token.isExempt(spender));
        vm.prank(alice);
        token.transfer(spender, 1_000);
        assertEq(token.balanceOf(spender), 985);
        assertEq(token.balanceOf(JENSEN), 5);
        assertEq(token.totalSupply(), SUPPLY - 10);
        vm.prank(distributor);
        token.transfer(bob, 1_000);
        assertEq(token.balanceOf(bob), 1_000);
        assertEq(token.distributor(), distributor);
    }

    function test_validDistributorWordIsUsedBeforeAnyTaxIsCharged() public {
        vm.mockCall(address(factory), abi.encodeCall(ILaunchFactory.distributorOf, (LAUNCH)), abi.encode(distributor));
        _fund(alice, 1_000);
        _approve(alice, spender, 1_000);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, distributor, 1_000));
        assertEq(token.balanceOf(distributor), 1_000);
        assertEq(token.balanceOf(JENSEN), 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.distributor(), distributor);
        assertEq(token.allowance(alice, spender), 0);
    }

    function test_failedFirstDistributorClaimDoesNotCache() public {
        factory.setDistributor(LAUNCH, distributor);
        _fund(distributor, 199);
        _approve(distributor, spender, 200);
        bytes32 beforeState = _stateHash();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, distributor, 199, 200));
        vm.prank(spender);
        token.transferFrom(distributor, alice, 200);
        assertEq(_stateHash(), beforeState);
    }

    function testFuzz_wrongLengthFactoryResponseIsIgnored(uint256 length) public {
        // The separate defect proof covers a 32-byte word with noncanonical address padding.
        length = bound(length, 0, 96);
        if (length == 32) length = 33;
        bytes memory response = new bytes(length);
        bytes memory canonical = abi.encode(distributor);
        for (uint256 i; i < length; ++i) {
            response[i] = canonical[i % 32];
        }
        vm.mockCall(address(factory), abi.encodeCall(ILaunchFactory.distributorOf, (LAUNCH)), response);
        _fund(alice, 1_000);
        _approve(alice, spender, 1_000);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 1_000));
        assertEq(token.balanceOf(bob), 985);
        assertEq(token.balanceOf(JENSEN), 5);
        assertEq(token.totalSupply(), SUPPLY - 10);
        assertEq(token.distributor(), address(0));
        assertFalse(token.isExempt(distributor));
        assertEq(token.allowance(alice, spender), 0);
    }

    function test_revertingLookupCanRecoverLater() public {
        _fund(alice, 1_000);
        vm.mockCallRevert(address(factory), abi.encodeCall(ILaunchFactory.distributorOf, (LAUNCH)), "");
        vm.prank(alice);
        token.transfer(bob, 200);
        assertEq(token.distributor(), address(0));
        assertEq(token.balanceOf(bob), 197);
        vm.clearMockedCalls();
        factory.setDistributor(LAUNCH, distributor);
        vm.prank(alice);
        token.transfer(distributor, 800);
        assertEq(token.balanceOf(distributor), 800);
        assertEq(token.distributor(), distributor);
        assertEq(token.balanceOf(JENSEN), 1);
        assertEq(token.totalSupply(), SUPPLY - 2);
    }

    function testFuzz_launchNumberSelectsOnlyItsOwnDistributor(uint64 launch) public {
        address foreignDistributor = makeAddr("foreign.distributor");
        factory.setDistributor(launch, distributor);
        factory.setDistributor(launch ^ 1, foreignDistributor);
        vm.prank(address(factory));
        NvidiaToken fresh = new NvidiaToken(address(factory), pool, launch);
        assertEq(fresh.launchNumber(), launch);
        assertTrue(fresh.isExempt(distributor));
        assertFalse(fresh.isExempt(foreignDistributor));
        vm.prank(address(factory));
        fresh.transfer(distributor, 1_000);
        vm.prank(distributor);
        fresh.transfer(alice, 1_000);
        assertEq(fresh.balanceOf(alice), 1_000);
        assertEq(fresh.distributor(), distributor);
        assertEq(fresh.totalSupply(), SUPPLY);
    }

    function testFuzz_exemptEndpointsStillRequireGrossAllowance(uint8 role, bool inbound, uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        factory.setDistributor(LAUNCH, distributor);
        address exempt = role % 3 == 0 ? address(factory) : role % 3 == 1 ? pool : distributor;
        address from = inbound ? alice : exempt;
        address to = inbound ? exempt : alice;
        if (from != address(factory)) _fund(from, amount);
        _approve(from, spender, amount - 1);
        bytes32 beforeState = _stateHash();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, amount - 1, amount)
        );
        vm.prank(spender);
        token.transferFrom(from, to, amount);
        assertEq(_stateHash(), beforeState);
        uint256 recipientBefore = token.balanceOf(to);
        uint256 sourceBefore = token.balanceOf(from);
        _approve(from, spender, amount);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        assertEq(token.balanceOf(to) - recipientBefore, amount);
        assertEq(sourceBefore - token.balanceOf(from), amount);
        assertEq(token.allowance(from, spender), 0);
        assertEq(token.balanceOf(JENSEN), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _cacheEvents(Vm.Log[] memory logs) private view returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(token) && logs[i].topics[0] == NvidiaToken.DistributorCached.selector) {
                count++;
            }
        }
    }
}
