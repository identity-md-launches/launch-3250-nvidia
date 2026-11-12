// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {NvidiaToken} from "src/NvidiaToken.sol";
import {NvidiaTokenFixture} from "./helpers/NvidiaTokenFixture.sol";
import {DirtyWordFactory} from "./mocks/MockLaunchFactory.sol";

/// @notice A factory that answers one 32-byte word chosen by the test, so every non-address word can be tried.
contract ChosenWordFactory {
    uint256 public word;

    function setWord(uint256 word_) external {
        word = word_;
    }

    fallback() external {
        uint256 w = word;
        assembly ("memory-safe") {
            mstore(0, w)
            return(0, 32)
        }
    }
}

/// @notice Tests for the revised PoolManager rule (inbound exact, outbound taxed from the gross amount),
/// for the two defects the revision fixed (non-address factory words and full-range previews), and
/// for a caller who limits the gas of a distributor claim to try to make it pay the tax.
/// forge-config: default.fuzz.runs = 1000
contract NvidiaTokenPoolTest is NvidiaTokenFixture {
    // ------------------------------------------------------------------------
    // PoolManager: inbound exact, outbound taxed
    // ------------------------------------------------------------------------

    /// Spec oracle: 0.5% and 1% of the gross amount, rounded down, computed the way the brief states it.
    function _spec(uint256 amount) private pure returns (uint256 net, uint256 tribute, uint256 burn) {
        tribute = Math.mulDiv(amount, 50, 10_000);
        burn = Math.mulDiv(amount, 100, 10_000);
        net = amount - tribute - burn;
    }

    function testFuzz_poolOutboundIsTaxedFromTheGrossAmount(uint256 amount, uint8 toSeed, bool delegated) public {
        amount = bound(amount, 1, SUPPLY / 2);
        _fund(alice, amount);
        vm.prank(alice);
        assertTrue(token.transfer(pool, amount)); // a sell arrives whole
        assertEq(token.balanceOf(pool), amount);
        assertEq(token.totalSupply(), SUPPLY);

        address to = toSeed % 3 == 0 ? bob : toSeed % 3 == 1 ? alice : spender;
        if (delegated) _approve(pool, spender, amount);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(delegated ? spender : pool);
        assertTrue(delegated ? token.transferFrom(pool, to, amount) : token.transfer(to, amount));

        (uint256 net, uint256 tribute, uint256 burn) = _spec(amount);
        assertEq(token.balanceOf(pool), 0, "the pool must lose exactly the gross amount, no more");
        assertEq(token.balanceOf(to) - toBefore, net);
        assertEq(token.balanceOf(JENSEN), tribute);
        assertEq(token.totalSupply(), SUPPLY - burn);
        assertEq(token.allowance(pool, spender), 0, "a delegated payout spends the gross allowance");
    }

    function testFuzz_sellThenBuyBackNeverGainsAndLosesExactlyTheTax(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY / 2);
        _fund(alice, amount);
        vm.prank(alice);
        token.transfer(pool, amount);
        vm.prank(pool);
        token.transfer(alice, amount);
        (uint256 net,, uint256 burn) = _spec(amount);
        assertEq(token.balanceOf(alice), net);
        assertLe(token.balanceOf(alice), amount);
        assertEq(token.totalSupply(), SUPPLY - burn);
        assertEq(token.balanceOf(alice) + token.balanceOf(JENSEN) + burn, amount, "value leaked");
    }

    function test_poolToFactoryIsExact() public {
        _fund(pool, 1_000e18);
        uint256 before = token.balanceOf(address(factory));
        vm.prank(pool);
        token.transfer(address(factory), 1_000e18);
        assertEq(token.balanceOf(address(factory)) - before, 1_000e18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(JENSEN), 0);
    }

    function test_poolToDistributorIsExactOnlyOnceTheFactoryNamesIt() public {
        _fund(pool, 2_000e18);
        // Unknown distributor: an ordinary taxed payout.
        vm.prank(pool);
        token.transfer(distributor, 1_000e18);
        (uint256 net,, uint256 burn) = _spec(1_000e18);
        assertEq(token.balanceOf(distributor), net);
        assertEq(token.distributor(), address(0));
        // Named: exact, and the transfer out of the pool caches it.
        factory.setDistributor(LAUNCH, distributor);
        vm.prank(pool);
        token.transfer(distributor, 1_000e18);
        assertEq(token.balanceOf(distributor), net + 1_000e18);
        assertEq(token.distributor(), distributor);
        assertEq(token.totalSupply(), SUPPLY - burn);
    }

    function test_poolOutboundCachesTheDistributor() public {
        factory.setDistributor(LAUNCH, distributor);
        _fund(pool, 1_000);
        vm.prank(pool);
        token.transfer(alice, 1_000);
        assertEq(token.distributor(), distributor, "a buy consults the factory like any taxed transfer");
    }

    function test_poolSelfTransferIsExact() public {
        _fund(pool, 1_000e18);
        vm.prank(pool);
        token.transfer(pool, 1_000e18);
        assertEq(token.balanceOf(pool), 1_000e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_poolIsNotExemptInIsExempt() public view {
        assertFalse(token.isExempt(pool));
        assertTrue(token.isExempt(address(factory)));
    }

    function testFuzz_poolOverspendRevertsWithGrossAmountAndChangesNothing(uint256 balance, uint256 amount) public {
        balance = bound(balance, 0, SUPPLY / 2);
        amount = bound(amount, balance + 1, type(uint256).max);
        _fund(pool, balance);
        bytes32 beforeState = _stateHash();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, pool, balance, amount));
        vm.prank(pool);
        token.transfer(alice, amount);
        assertEq(_stateHash(), beforeState);
    }

    function test_poolDelegatedPayoutNeedsTheGrossAllowance() public {
        _fund(pool, 1_000e18);
        _approve(pool, spender, 1_000e18 - 1);
        bytes32 beforeState = _stateHash();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 1_000e18 - 1, 1_000e18)
        );
        vm.prank(spender);
        token.transferFrom(pool, bob, 1_000e18);
        assertEq(_stateHash(), beforeState);
    }

    function test_poolOutboundEmitsTheThreeLegsAndTheTaxEvent() public {
        _fund(pool, 10_000);
        vm.recordLogs();
        vm.prank(pool);
        token.transfer(bob, 10_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        uint256 transfers;
        uint256 taxed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == transferTopic) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), pool, "every leg debits the pool");
                transfers++;
            } else if (logs[i].topics[0] == NvidiaToken.TransferTaxed.selector) {
                (uint256 net, uint256 tribute, uint256 burned) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(net, 9_850);
                assertEq(tribute, 50);
                assertEq(burned, 100);
                taxed++;
            }
        }
        assertEq(transfers, 3);
        assertEq(taxed, 1);
    }

    // ------------------------------------------------------------------------
    // Fixed defects: non-address factory words, full-range preview
    // ------------------------------------------------------------------------

    function testFuzz_nonAddressFactoryWordIsIgnoredAndLaterAnswerStillCaches(uint256 word) public {
        word = bound(word, uint256(type(uint160).max) + 1, type(uint256).max);
        ChosenWordFactory bad = new ChosenWordFactory();
        bad.setWord(word);
        vm.prank(address(bad));
        NvidiaToken fresh = new NvidiaToken(address(bad), pool, LAUNCH);
        vm.prank(address(bad));
        fresh.transfer(alice, 10_000);

        assertFalse(fresh.isExempt(address(uint160(word))));
        vm.prank(alice);
        assertTrue(fresh.transfer(bob, 10_000), "a malformed factory answer must not block transfers");
        assertEq(fresh.balanceOf(bob), 9_850);
        assertEq(fresh.distributor(), address(0), "a non-address word must not be cached");

        bad.setWord(uint256(uint160(distributor)));
        vm.prank(address(bad));
        fresh.transfer(distributor, 1_000);
        vm.prank(distributor);
        fresh.transfer(alice, 1_000);
        assertEq(fresh.balanceOf(alice), 1_000, "the real answer is honoured once it arrives");
        assertEq(fresh.distributor(), distributor);
    }

    function test_allOnesFactoryWordDoesNotRevertTransfers() public {
        address bad = address(new DirtyWordFactory());
        vm.prank(bad);
        NvidiaToken fresh = new NvidiaToken(bad, pool, LAUNCH);
        vm.prank(bad);
        fresh.transfer(alice, 1_000);
        vm.prank(alice);
        assertTrue(fresh.transfer(bob, 1_000));
        assertEq(fresh.balanceOf(bob), 985);
    }

    function testFuzz_splitTransferMatchesTheSpecOverTheWholeRange(uint256 amount) public view {
        (uint256 net, uint256 tribute, uint256 burned) = token.splitTransfer(amount);
        (uint256 eNet, uint256 eTribute, uint256 eBurn) = _spec(amount);
        assertEq(tribute, eTribute);
        assertEq(burned, eBurn);
        assertEq(net, eNet);
    }

    function test_splitTransferEdges() public view {
        uint256[6] memory amounts = [uint256(0), 1, 99, 100, 200, type(uint256).max];
        for (uint256 i; i < amounts.length; ++i) {
            (uint256 net, uint256 tribute, uint256 burned) = token.splitTransfer(amounts[i]);
            assertEq(net + tribute + burned, amounts[i]);
        }
        (, uint256 t, uint256 b) = token.splitTransfer(199);
        assertEq(t, 0);
        assertEq(b, 1);
    }

    // ------------------------------------------------------------------------
    // A gas-limited distributor claim is exact or reverts, never taxed
    // ------------------------------------------------------------------------

    /// A claim on a MerkleDistributor is often callable by anyone on behalf of the claimant. The first
    /// claim is also the first lookup, so a caller who limits its gas so that the capped lookup fails
    /// could make the claim look like an ordinary transfer. Every gas limit must give either a revert
    /// or an exact claim.
    function testFuzz_gasLimitedFirstClaimIsExactOrReverts(uint256 gasLimit) public {
        gasLimit = bound(gasLimit, 5_000, 200_000);
        factory.setDistributor(LAUNCH, distributor);
        vm.prank(address(factory));
        token.transfer(distributor, 1_000e18);

        vm.prank(distributor);
        (bool ok,) = address(token).call{gas: gasLimit}(abi.encodeCall(token.transfer, (alice, 1_000e18)));
        if (ok) {
            assertEq(token.balanceOf(alice), 1_000e18, "a gas-limited claim arrived short");
            assertEq(token.totalSupply(), SUPPLY);
            assertEq(token.balanceOf(JENSEN), 0);
        } else {
            assertEq(token.balanceOf(alice), 0);
            assertEq(token.balanceOf(distributor), 1_000e18);
        }
    }
}
