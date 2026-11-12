// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NvidiaToken} from "src/NvidiaToken.sol";
import {MockLaunchFactory} from "../mocks/MockLaunchFactory.sol";

abstract contract NvidiaTokenFixture is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    address internal constant JENSEN = 0xc59b0c072f73ceEA3Dc354031165501c0Ff25023;
    uint64 internal constant LAUNCH = 71;

    MockLaunchFactory internal factory;
    NvidiaToken internal token;
    address internal alice = makeAddr("adversarial.alice");
    address internal bob = makeAddr("adversarial.bob");
    address internal spender = makeAddr("adversarial.spender");
    address internal pool = makeAddr("adversarial.pool");
    address internal distributor = makeAddr("adversarial.distributor");

    function setUp() public virtual {
        factory = new MockLaunchFactory();
        vm.prank(address(factory));
        token = new NvidiaToken(address(factory), pool, LAUNCH);
    }

    function _fund(address account, uint256 amount) internal {
        vm.prank(address(factory));
        assertTrue(token.transfer(account, amount));
    }

    function _approve(address owner, address operator, uint256 amount) internal {
        vm.prank(owner);
        assertTrue(token.approve(operator, amount));
    }

    /// @dev Covers every holder and allowance used by the failure-path tests, including the cache.
    function _stateHash() internal view returns (bytes32 state) {
        address[8] memory accounts = [address(factory), pool, distributor, alice, bob, spender, JENSEN, address(token)];
        state = keccak256(abi.encode(token.totalSupply(), token.distributor(), token.balanceOf(address(0))));
        for (uint256 i; i < accounts.length; ++i) {
            state = keccak256(abi.encode(state, token.balanceOf(accounts[i])));
            for (uint256 j; j < accounts.length; ++j) {
                state = keccak256(abi.encode(state, token.allowance(accounts[i], accounts[j])));
            }
        }
    }
}
