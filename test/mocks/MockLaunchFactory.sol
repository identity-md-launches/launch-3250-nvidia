// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Stands in for the launch factory: answers `distributorOf` the way the factory does.
contract MockLaunchFactory {
    mapping(uint64 => address) public distributorOf;

    function setDistributor(uint64 launchNumber, address distributor) external {
        distributorOf[launchNumber] = distributor;
    }
}

/// @notice A factory whose `distributorOf` always reverts, to show the token tolerates it.
contract RevertingFactory {
    function distributorOf(uint64) external pure returns (address) {
        revert("no distributor");
    }
}

/// @notice A factory whose `distributorOf` answers with the wrong shape, to show the token tolerates it.
contract MalformedFactory {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 1)
            return(0, 16)
        }
    }
}
