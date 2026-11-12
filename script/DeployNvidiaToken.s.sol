// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {NvidiaToken} from "../src/NvidiaToken.sol";

/// @title Local deployment helper for NvidiaToken
/// @notice For local forks and dry runs only. The production launch is performed by IMD's deployer
/// through the launch factory, which deploys the token from its bytecode with the manifest's
/// constructor arguments; this script is never that launch. Deploying it directly mints the whole
/// supply to whatever address runs it, because the token mints to `msg.sender`.
contract DeployNvidiaToken is Script {
    /// @notice ADVN_LAUNCH_NUMBER does not fit the token's uint64 launch number.
    error LaunchNumberTooLarge(uint256 value);

    struct Config {
        address factory;
        address poolManager;
        uint64 launchNumber;
    }

    /// @notice Deploys the token with an explicit configuration. Tests call this directly.
    function deploy(Config memory config) public returns (NvidiaToken token) {
        token = new NvidiaToken(config.factory, config.poolManager, config.launchNumber);
    }

    /// @notice Reads the configuration from the environment and deploys. Only `run()` touches the
    /// environment; tests never call it.
    function run() external returns (NvidiaToken token) {
        uint256 launchNumber = vm.envUint("ADVN_LAUNCH_NUMBER");
        if (launchNumber > type(uint64).max) revert LaunchNumberTooLarge(launchNumber);
        Config memory config = Config({
            factory: vm.envAddress("ADVN_FACTORY"),
            poolManager: vm.envAddress("ADVN_POOL_MANAGER"),
            // forge-lint: disable-next-line(unsafe-typecast)
            launchNumber: uint64(launchNumber)
        });
        vm.startBroadcast();
        token = deploy(config);
        vm.stopBroadcast();
    }
}
