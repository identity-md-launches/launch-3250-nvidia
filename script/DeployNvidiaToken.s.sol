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
        Config memory config = Config({
            factory: vm.envAddress("ADVN_FACTORY"),
            poolManager: vm.envAddress("ADVN_POOL_MANAGER"),
            launchNumber: uint64(vm.envUint("ADVN_LAUNCH_NUMBER"))
        });
        vm.startBroadcast();
        token = deploy(config);
        vm.stopBroadcast();
    }
}
