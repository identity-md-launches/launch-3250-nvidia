// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {NvidiaToken} from "src/NvidiaToken.sol";
import {NvidiaTokenFixture} from "./helpers/NvidiaTokenFixture.sol";

/// forge-config: default.fuzz.runs = 1000
contract NvidiaTokenAdversarialTest is NvidiaTokenFixture {
    function test_constructorMintsOnceToActualDeployer() public {
        vm.recordLogs();
        vm.prank(alice);
        NvidiaToken fresh = new NvidiaToken(address(factory), pool, type(uint64).max);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "only the constructor mint may emit a Transfer");
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(alice))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
        assertEq(fresh.balanceOf(alice), SUPPLY);
        assertEq(fresh.balanceOf(address(factory)), 0);
        assertEq(fresh.balanceOf(JENSEN), 0);
        assertEq(fresh.balanceOf(address(0)), 0);
        assertEq(fresh.totalSupply(), SUPPLY);
    }

    function test_approvalOverwritesAndRevocationTakesEffectImmediately() public {
        _fund(alice, 1_000);
        _approve(alice, spender, 900);
        vm.expectEmit(address(token));
        emit IERC20.Approval(alice, spender, 200);
        _approve(alice, spender, 200);
        assertEq(token.allowance(alice, spender), 200);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 200));
        assertEq(token.allowance(alice, spender), 0);
        _approve(alice, spender, type(uint256).max);
        vm.expectEmit(address(token));
        emit IERC20.Approval(alice, spender, 0);
        _approve(alice, spender, 0);
        bytes32 beforeState = _stateHash();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        assertEq(_stateHash(), beforeState);
    }

    function test_finiteAllowancePersistsAcrossSeveralSpends() public {
        _fund(alice, 1_000);
        _approve(alice, spender, 600);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 200));
        assertEq(token.allowance(alice, spender), 400);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, JENSEN, 400));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 400);
        assertEq(token.balanceOf(bob), 197);
        assertEq(token.balanceOf(JENSEN), 397);
        assertEq(token.totalSupply(), SUPPLY - 6);
        bytes32 beforeState = _stateHash();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        assertEq(_stateHash(), beforeState);
    }

    function test_infiniteAllowanceIsNotSpentButCanBeRevoked() public {
        _fund(alice, 1_000);
        _approve(alice, spender, type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 200));
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 800));
        assertEq(token.allowance(alice, spender), type(uint256).max);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 985);
        assertEq(token.balanceOf(JENSEN), 5);
        assertEq(token.totalSupply(), SUPPLY - 10);
        _approve(alice, spender, 0);
        assertEq(token.allowance(alice, spender), 0);
    }

    function test_approvalIsIsolatedByOwnerAndSpender() public {
        _approve(alice, spender, 400);
        _approve(alice, bob, 500);
        _approve(bob, spender, 600);
        _approve(alice, spender, 0);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.allowance(alice, bob), 500);
        assertEq(token.allowance(bob, spender), 600);
        assertEq(token.allowance(spender, alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_maximumMinusOneAllowanceIsFinite() public {
        _fund(alice, 200);
        _approve(alice, spender, type(uint256).max - 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 200));
        assertEq(token.allowance(alice, spender), type(uint256).max - 201);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 197);
        assertEq(token.balanceOf(JENSEN), 1);
        assertEq(token.totalSupply(), SUPPLY - 2);
    }

    function test_approveZeroSpenderRejectsZeroAndMaximum() public {
        bytes32 beforeState = _stateHash();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(alice);
        token.approve(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(alice);
        token.approve(address(0), type(uint256).max);
        assertEq(token.allowance(alice, address(0)), 0);
        assertEq(_stateHash(), beforeState);
    }

    function test_transferFromDoesNotGiveOwnerImplicitAllowance() public {
        _fund(alice, 200);
        bytes32 beforeState = _stateHash();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 200));
        vm.prank(alice);
        token.transferFrom(alice, bob, 200);
        assertEq(_stateHash(), beforeState);
    }

    function test_grossAmountMustFitEvenWhenNetFits() public {
        _fund(alice, 985);
        bytes32 beforeState = _stateHash();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 985, 1_000));
        vm.prank(alice);
        token.transfer(bob, 1_000);
        assertEq(_stateHash(), beforeState);
    }

    function test_netOnlyAllowanceCannotAuthorizeGrossTransfer() public {
        _fund(alice, 1_000);
        _approve(alice, spender, 985);
        bytes32 beforeState = _stateHash();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 985, 1_000));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1_000);
        assertEq(_stateHash(), beforeState);
    }

    function test_failedTransferFromRollsBackAllowanceAndNewCache() public {
        factory.setDistributor(LAUNCH, distributor);
        _fund(alice, 199);
        _approve(alice, spender, 200);
        bytes32 beforeState = _stateHash();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 199, 200));
        vm.prank(spender);
        token.transferFrom(alice, bob, 200);
        assertEq(_stateHash(), beforeState, "failed debit must undo allowance spending and cache discovery");
        _fund(alice, 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 200));
        assertEq(token.distributor(), distributor);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(bob), 197);
    }

    function test_zeroRecipientRollsBackFiniteAllowanceAndBalances() public {
        _fund(alice, 1_000);
        _approve(alice, spender, 1_000);
        bytes32 beforeState = _stateHash();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(alice, address(0), 1_000);
        assertEq(_stateHash(), beforeState);
    }

    function test_zeroAmountStillRejectsZeroEndpoints() public {
        bytes32 beforeState = _stateHash();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(alice, address(0), 0);
        // transferFrom spends allowance first; its approval-owner check rejects the zero source.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(0), bob, 0);
        assertEq(_stateHash(), beforeState);
    }

    function test_zeroTransferFromWithoutApprovalOnlyEmitsTransfer() public {
        factory.setDistributor(LAUNCH, distributor);
        bytes32 beforeState = _stateHash();
        vm.recordLogs();
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(token));
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(alice))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(bob))));
        assertEq(abi.decode(logs[0].data, (uint256)), 0);
        assertEq(_stateHash(), beforeState, "zero transfer must not cache, tax, burn or spend approval");
    }

    function test_maximumTransferRevertsForBalanceBeforeTaxArithmetic() public {
        _fund(alice, 1_000);
        _approve(alice, spender, type(uint256).max);
        bytes32 beforeState = _stateHash();
        bytes memory reason =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1_000, type(uint256).max);
        vm.expectRevert(reason);
        vm.prank(alice);
        token.transfer(bob, type(uint256).max);
        vm.expectRevert(reason);
        vm.prank(spender);
        token.transferFrom(alice, bob, type(uint256).max);
        assertEq(_stateHash(), beforeState);
    }

    function test_fullSupplyTransferBurnsExactlyOnePercent() public {
        _fund(alice, SUPPLY);
        vm.prank(alice);
        assertTrue(token.transfer(bob, SUPPLY));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 985_000_000e18);
        assertEq(token.balanceOf(JENSEN), 5_000_000e18);
        assertEq(token.totalSupply(), 990_000_000e18);
        assertEq(token.balanceOf(address(0)), 0, "burn removes supply instead of crediting zero");
    }

    function test_roundingBoundaryTable() public view {
        uint256[9] memory amounts = [uint256(0), 1, 99, 100, 101, 199, 200, 201, 10_000];
        uint256[9] memory nets = [uint256(0), 1, 99, 99, 100, 198, 197, 198, 9_850];
        uint256[9] memory tributes = [uint256(0), 0, 0, 0, 0, 0, 1, 1, 50];
        uint256[9] memory burns = [uint256(0), 0, 0, 1, 1, 1, 2, 2, 100];
        for (uint256 i; i < amounts.length; ++i) {
            (uint256 net, uint256 tribute, uint256 burned) = token.splitTransfer(amounts[i]);
            assertEq(net, nets[i]);
            assertEq(tribute, tributes[i]);
            assertEq(burned, burns[i]);
        }
    }

    function test_oneWeiMovesEvenWhenSenderIsEmptied() public {
        _fund(alice, 1);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 1));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 1);
        assertEq(token.balanceOf(JENSEN), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferToJensenCreditsNetAndTributeExactlyOnce() public {
        _fund(alice, 1_000);
        vm.prank(alice);
        assertTrue(token.transfer(JENSEN, 1_000));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(JENSEN), 990);
        assertEq(token.totalSupply(), SUPPLY - 10);
    }

    function test_jensenSelfTransferOnlyLosesBurnButSpendsGrossAllowance() public {
        _fund(JENSEN, 1_000);
        _approve(JENSEN, spender, 1_000);
        vm.prank(spender);
        assertTrue(token.transferFrom(JENSEN, JENSEN, 1_000));
        assertEq(token.balanceOf(JENSEN), 990);
        assertEq(token.totalSupply(), SUPPLY - 10);
        assertEq(token.allowance(JENSEN, spender), 0);
    }

    function test_selfTransferCannotSpendMoreThanBalance() public {
        _fund(alice, 1_000);
        bytes32 beforeState = _stateHash();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1_000, 1_001));
        vm.prank(alice);
        token.transfer(alice, 1_001);
        assertEq(_stateHash(), beforeState);
    }

    function test_taxedTransferToTokenContractStillConservesSupply() public {
        _fund(alice, 1_000);
        vm.prank(alice);
        assertTrue(token.transfer(address(token), 1_000));
        assertEq(token.balanceOf(address(token)), 985);
        assertEq(token.balanceOf(JENSEN), 5);
        assertEq(token.totalSupply(), SUPPLY - 10);
    }

    function testFuzz_rejectedTransferFromPreservesAllState(uint256 balance, uint256 amount) public {
        balance = bound(balance, 0, SUPPLY);
        amount = bound(amount, balance + 1, type(uint256).max);
        _fund(alice, balance);
        _approve(alice, spender, amount);
        factory.setDistributor(LAUNCH, distributor);
        bytes32 beforeState = _stateHash();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, amount));
        vm.prank(spender);
        token.transferFrom(alice, bob, amount);
        assertEq(_stateHash(), beforeState);
    }

    function testFuzz_insufficientAllowancePreservesAllState(uint256 amount, uint256 allowance_) public {
        amount = bound(amount, 1, SUPPLY);
        allowance_ = bound(allowance_, 0, amount - 1);
        _fund(alice, amount);
        _approve(alice, spender, allowance_);
        bytes32 beforeState = _stateHash();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance_, amount)
        );
        vm.prank(spender);
        token.transferFrom(alice, bob, amount);
        assertEq(_stateHash(), beforeState);
    }

    function testFuzz_selfTransferChargesOnlyTheTwoCuts(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        _fund(alice, amount);
        _approve(alice, spender, amount);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, alice, amount));
        uint256 lost = amount - token.balanceOf(alice);
        assertEq(lost, token.balanceOf(JENSEN) + SUPPLY - token.totalSupply());
        assertEq(token.balanceOf(JENSEN), amount / 200);
        assertEq(SUPPLY - token.totalSupply(), amount / 100);
        assertEq(token.allowance(alice, spender), 0);
    }

    function testFuzz_roundTripCannotCreateValue(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        _fund(alice, amount);
        vm.prank(alice);
        assertTrue(token.transfer(bob, amount));
        uint256 received = token.balanceOf(bob);
        vm.prank(bob);
        assertTrue(token.transfer(alice, received));
        assertEq(token.balanceOf(bob), 0);
        assertLe(token.balanceOf(alice), amount);
        assertEq(amount - token.balanceOf(alice), token.balanceOf(JENSEN) + SUPPLY - token.totalSupply());
        if (amount >= 200) assertLt(token.balanceOf(alice), amount);
    }

    function testFuzz_previewMatchesActualAndCutsRoundDown(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        (uint256 net, uint256 tribute, uint256 burned) = token.splitTransfer(amount);
        // Quotient/remainder bounds characterize floor rounding independently of basis-point multiplication.
        assertLe(tribute * 200, amount);
        assertLt(amount, (tribute + 1) * 200);
        assertLe(burned * 100, amount);
        assertLt(amount, (burned + 1) * 100);
        assertEq(net + tribute + burned, amount);
        _fund(alice, amount);
        vm.prank(alice);
        assertTrue(token.transfer(bob, amount));
        assertEq(token.balanceOf(bob), net);
        assertEq(token.balanceOf(JENSEN), tribute);
        assertEq(token.totalSupply(), SUPPLY - burned);
    }

    function testFuzz_addingOneRatePeriodAddsExactlyThreeWeiOfTax(uint256 amount) public view {
        amount = bound(amount, 0, SUPPLY - 200);
        (uint256 net, uint256 tribute, uint256 burned) = token.splitTransfer(amount);
        (uint256 nextNet, uint256 nextTribute, uint256 nextBurned) = token.splitTransfer(amount + 200);
        assertEq(nextTribute - tribute, 1);
        assertEq(nextBurned - burned, 2);
        assertEq(nextNet - net, 197);
    }
}
