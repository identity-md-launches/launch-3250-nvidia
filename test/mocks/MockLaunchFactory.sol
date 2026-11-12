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

/// @notice A factory that answers one 32-byte word which is not a valid address (high bits set).
contract DirtyWordFactory {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, not(0))
            return(0, 32)
        }
    }
}

/// @notice A factory that burns all the gas it is given.
contract GasBurningFactory {
    fallback() external {
        assembly ("memory-safe") {
            invalid()
        }
    }
}

/// @notice A factory that answers with a very large return buffer.
contract HugeAnswerFactory {
    fallback() external {
        assembly ("memory-safe") {
            return(0, 600000)
        }
    }
}

/// @notice The part of Uniswap v4's PoolManager flash accounting a pass-through route uses.
contract MiniPoolManager {
    address internal syncedCurrency;
    uint256 internal syncedReserve;
    mapping(address => mapping(address => int256)) public delta;

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallbackLike(msg.sender).unlockCallback(data);
    }

    function sync(address currency) external {
        syncedCurrency = currency;
        syncedReserve = IERC20Like(currency).balanceOf(address(this));
    }

    function settle() external returns (uint256 paid) {
        paid = IERC20Like(syncedCurrency).balanceOf(address(this)) - syncedReserve;
        delta[msg.sender][syncedCurrency] += int256(paid);
        syncedCurrency = address(0);
    }

    function take(address currency, address to, uint256 amount) external {
        delta[msg.sender][currency] -= int256(amount);
        require(IERC20Like(currency).transfer(to, amount), "transfer failed");
    }
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IUnlockCallbackLike {
    function unlockCallback(bytes calldata) external returns (bytes memory);
}

/// @notice Sends tokens to a recipient through the PoolManager's sync/settle/take escrow.
contract EscrowRoute is IUnlockCallbackLike {
    MiniPoolManager internal immutable pm;
    address internal immutable token;

    constructor(MiniPoolManager pm_, address token_) {
        pm = pm_;
        token = token_;
    }

    function send(address to, uint256 amount) external {
        pm.unlock(abi.encode(to, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address to, uint256 amount) = abi.decode(data, (address, uint256));
        pm.sync(token);
        require(IERC20Like(token).transfer(address(pm), amount), "in");
        pm.settle();
        pm.take(token, to, amount);
        require(pm.delta(address(this), token) == 0, "unsettled");
        return "";
    }
}
