// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {NvidiaToken, ILaunchFactory} from "src/NvidiaToken.sol";
import {MockLaunchFactory} from "../mocks/MockLaunchFactory.sol";

/// @notice A closed ledger of seven active holders and the token itself as a passive recipient.
/// Approvals are separate actions: transferFrom never manufactures a fresh approval for its spend.
contract NvidiaTokenStateHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000e18;
    uint64 public constant LAUNCH = 71;
    address public constant JENSEN = 0xc59b0c072f73ceEA3Dc354031165501c0Ff25023;
    NvidiaToken public immutable token;
    MockLaunchFactory public immutable factory;
    // factory, pool, distributor, Jensen, Alice, Bob, spender, passive token contract
    address[8] public actors;
    uint256[8] public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public burned;
    bool public published;
    bool public factoryAvailable = true;
    bool public cached;
    uint256 public positiveTaxedCalls;
    uint256 public positiveExemptCalls;
    uint256 public positiveDelegatedCalls;
    uint256 public rejectedCalls;

    constructor(NvidiaToken token_, MockLaunchFactory factory_, address[8] memory actors_) {
        token = token_;
        factory = factory_;
        actors = actors_;
        for (uint256 i; i < 8; ++i) {
            expectedBalance[i] = token_.balanceOf(actors_[i]);
        }
        // Seed persistent finite and unlimited approvals, then allow the fuzzer to replace/revoke them.
        for (uint256 i; i < 7; ++i) {
            _approve(i, 5, SUPPLY / 20);
            _approve(i, 6, type(uint256).max);
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 value, uint8 mode) external {
        uint256 amount = mode % 3 == 0 ? _bound(value, 0, SUPPLY) : mode % 3 == 1 ? type(uint256).max : 0;
        _approve(ownerSeed % 7, 3 + spenderSeed % 4, amount);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 value, uint8 mode) external {
        uint256 from = fromSeed % 7;
        _move(from, toSeed % 8, 0, _amount(value, mode, expectedBalance[from]), false);
    }

    function selfTransfer(uint256 fromSeed, uint256 value, uint8 mode) external {
        uint256 from = fromSeed % 7;
        _move(from, from, 0, _amount(value, mode, expectedBalance[from]), false);
    }

    function transferFrom(uint256 fromSeed, uint256 toSeed, uint256 spenderSeed, uint256 value, uint8 mode) external {
        uint256 from = fromSeed % 7;
        // Ordinary operators ensure a delegated taxed transfer cannot acquire a launch exemption
        // merely because its operator is a launch address.
        uint256 operator = 3 + spenderSeed % 4;
        uint256 limit = _min(expectedBalance[from], expectedAllowance[actors[from]][actors[operator]]);
        _move(from, toSeed % 8, operator, _amount(value, mode, limit), true);
    }

    /// @dev Raw uint256 inputs reach allowance errors, balance errors and successes. A failed call
    /// must match the precise expected error; global ledger checks then verify complete rollback.
    function attemptTransferFrom(uint256 fromSeed, uint256 toSeed, uint256 spenderSeed, uint256 amount) external {
        uint256 from = fromSeed % 7;
        uint256 to = toSeed % 8;
        uint256 operator = 3 + spenderSeed % 4;
        uint256 allowance_ = expectedAllowance[actors[from]][actors[operator]];
        bytes memory error;
        if (allowance_ != type(uint256).max && amount > allowance_) {
            error = abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, actors[operator], allowance_, amount
            );
        } else if (amount > expectedBalance[from]) {
            error = abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, actors[from], expectedBalance[from], amount
            );
        } else {
            _move(from, to, operator, amount, true);
            return;
        }
        vm.prank(actors[operator]);
        (bool ok, bytes memory reason) =
            address(token).call(abi.encodeCall(token.transferFrom, (actors[from], actors[to], amount)));
        assertFalse(ok, "invalid delegated spend unexpectedly succeeded");
        assertEq(reason, error, "invalid delegated spend returned the wrong error");
        rejectedCalls++;
    }

    function rejectTransfer(uint256 fromSeed, uint256 toSeed, bool zeroRecipient, bool maximum) external {
        uint256 from = fromSeed % 7;
        uint256 amount = zeroRecipient ? expectedBalance[from] : maximum ? type(uint256).max : expectedBalance[from] + 1;
        address to = zeroRecipient ? address(0) : actors[toSeed % 8];
        bytes memory error = zeroRecipient
            ? abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
            : abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, actors[from], expectedBalance[from], amount
            );
        vm.prank(actors[from]);
        (bool ok, bytes memory reason) = address(token).call(abi.encodeCall(token.transfer, (to, amount)));
        assertFalse(ok, "invalid transfer unexpectedly succeeded");
        assertEq(reason, error, "invalid transfer returned the wrong error");
        rejectedCalls++;
    }

    function publishDistributor() external {
        factory.setDistributor(LAUNCH, actors[2]);
        published = true;
    }

    function setFactoryAvailable(bool available) external {
        if (available) {
            vm.clearMockedCalls();
        } else {
            vm.mockCallRevert(address(factory), abi.encodeCall(ILaunchFactory.distributorOf, (LAUNCH)), "");
        }
        factoryAvailable = available;
    }

    function expectedExempt(uint256 index) public view returns (bool) {
        return index < 2 || (index == 2 && (cached || (published && factoryAvailable)));
    }

    function _approve(uint256 owner, uint256 operator, uint256 amount) private {
        vm.prank(actors[owner]);
        assertTrue(token.approve(actors[operator], amount));
        expectedAllowance[actors[owner]][actors[operator]] = amount;
    }

    function _move(uint256 from, uint256 to, uint256 operator, uint256 amount, bool delegated) private {
        bool exempt = expectedExempt(from) || expectedExempt(to);
        uint256 supplyBefore = token.totalSupply();
        if (delegated) {
            vm.prank(actors[operator]);
            assertTrue(token.transferFrom(actors[from], actors[to], amount));
            uint256 allowance_ = expectedAllowance[actors[from]][actors[operator]];
            if (allowance_ != type(uint256).max) {
                expectedAllowance[actors[from]][actors[operator]] = allowance_ - amount;
            }
            if (amount > 0) positiveDelegatedCalls++;
        } else {
            vm.prank(actors[from]);
            assertTrue(token.transfer(actors[to], amount));
        }
        // The oracle never calls splitTransfer or isExempt. Rates come from the economic spec,
        // and roles come from the fixture; ordered credits also handle all address aliases.
        uint256 tribute = exempt ? 0 : amount / 200;
        uint256 burn = exempt ? 0 : amount / 100;
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount - tribute - burn;
        expectedBalance[3] += tribute;
        burned += burn;
        if (amount != 0) {
            if (exempt) positiveExemptCalls++;
            else positiveTaxedCalls++;
            if (from >= 2 && to >= 2 && published && factoryAvailable) cached = true;
        }
        assertLe(token.totalSupply(), supplyBefore, "a transfer increased supply");
    }

    function _amount(uint256 value, uint8 mode, uint256 limit) private pure returns (uint256) {
        uint256 which = mode % 8;
        if (which == 0) return 0;
        if (which == 1) return _min(1, limit);
        if (which == 2) return _min(99, limit);
        if (which == 3) return _min(100, limit);
        if (which == 4) return _min(199, limit);
        if (which == 5) return _min(200, limit);
        if (which == 6) return limit;
        return _bound(value, 0, limit);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
