// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NvidiaToken} from "../src/NvidiaToken.sol";
import {MockLaunchFactory} from "./mocks/MockLaunchFactory.sol";

/// @notice Drives random transfers and transferFroms among holders, launch addresses and the tribute
/// recipient, keeping an independent tally of what should have been burned and paid as tribute.
contract TransferHandler is Test {
    NvidiaToken public immutable token;
    address public immutable factory;
    address public immutable poolManager;
    address public immutable distributor;
    address[] public actors;

    uint256 public ghostBurned;
    uint256 public ghostTribute;
    /// @dev An independent model of the tribute recipient's balance.
    uint256 public ghostRecipientBalance;
    uint256 public taxedTransfers;
    uint256 public exemptTransfers;

    constructor(
        NvidiaToken token_,
        address factory_,
        address poolManager_,
        address distributor_,
        address[] memory users
    ) {
        token = token_;
        factory = factory_;
        poolManager = poolManager_;
        distributor = distributor_;
        actors.push(factory_);
        actors.push(poolManager_);
        actors.push(distributor_);
        actors.push(token_.TRIBUTE_RECIPIENT());
        for (uint256 i; i < users.length; ++i) {
            actors.push(users[i]);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from));
        _tally(from, to, amount);
        vm.prank(from);
        token.transfer(to, amount);
    }

    function transferFrom(uint256 fromSeed, uint256 toSeed, uint256 spenderSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.approve(spender, amount);
        _tally(from, to, amount);
        vm.prank(spender);
        token.transferFrom(from, to, amount);
    }

    function _tally(address from, address to, uint256 amount) private {
        address recipient = token.TRIBUTE_RECIPIENT();
        bool exempt = from == factory || to == factory || from == poolManager || to == poolManager
            || from == distributor || to == distributor;
        if (exempt || amount == 0) {
            exemptTransfers++;
            if (from == recipient) ghostRecipientBalance -= amount;
            if (to == recipient) ghostRecipientBalance += amount;
            return;
        }
        taxedTransfers++;
        uint256 tribute = (amount * 50) / 10_000;
        uint256 burned = (amount * 100) / 10_000;
        ghostTribute += tribute;
        ghostBurned += burned;
        if (from == recipient) ghostRecipientBalance -= amount;
        if (to == recipient) ghostRecipientBalance += amount - tribute - burned;
        ghostRecipientBalance += tribute;
    }
}

contract NvidiaTokenInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint64 constant LAUNCH_NUMBER = 9;

    MockLaunchFactory factory;
    NvidiaToken token;
    TransferHandler handler;
    address poolManager = makeAddr("poolManager");
    address distributor = makeAddr("distributor");

    function setUp() public {
        factory = new MockLaunchFactory();
        vm.prank(address(factory));
        token = new NvidiaToken(address(factory), poolManager, LAUNCH_NUMBER);
        factory.setDistributor(LAUNCH_NUMBER, distributor);

        address[] memory users = new address[](4);
        users[0] = makeAddr("u0");
        users[1] = makeAddr("u1");
        users[2] = makeAddr("u2");
        users[3] = makeAddr("u3");

        // Spread the supply so every actor, launch addresses included, has something to move.
        vm.startPrank(address(factory));
        token.transfer(poolManager, SUPPLY / 10);
        token.transfer(distributor, SUPPLY / 10);
        for (uint256 i; i < users.length; ++i) {
            token.transfer(users[i], SUPPLY / 20);
        }
        vm.stopPrank();

        handler = new TransferHandler(token, address(factory), poolManager, distributor, users);
        targetContract(address(handler));
    }

    function _sumOfBalances() internal view returns (uint256 sum) {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
    }

    function invariant_supplyIsInitialMinusBurned() public view {
        assertEq(token.totalSupply(), SUPPLY - handler.ghostBurned());
        assertLe(token.totalSupply(), SUPPLY);
    }

    function invariant_balancesSumToSupply() public view {
        assertEq(_sumOfBalances(), token.totalSupply());
    }

    function invariant_tributeRecipientBalanceMatchesModel() public view {
        assertEq(token.balanceOf(token.TRIBUTE_RECIPIENT()), handler.ghostRecipientBalance());
    }

    function invariant_distributorCachedOnceKnown() public view {
        address cached = token.distributor();
        assertTrue(cached == address(0) || cached == distributor);
    }
}
