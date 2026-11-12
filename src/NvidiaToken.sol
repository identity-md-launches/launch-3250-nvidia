// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The part of the launch factory the token reads: which MerkleDistributor belongs to its launch.
interface ILaunchFactory {
    function distributorOf(uint64 launchNumber) external view returns (address);
}

/// @title Nvidia (ADVN)
/// @notice A fixed-supply ERC-20 with a transfer tax. Every ordinary transfer sends 0.5% of the amount to
/// Jensen Huang's wallet (the tribute) and burns 1% of the amount; the receiver gets the remaining 98.5%.
/// The whole supply, 1,000,000,000 ADVN, is minted once to the deployer (the launch factory) in the
/// constructor. Nothing can mint afterwards, and there is no owner, pause, blacklist or upgrade path.
/// @dev Launch flows are exempt from the tax so they move exactly what they say: transfers from or to
/// the factory, from or to the Uniswap v4 PoolManager, and from or to the launch's MerkleDistributor
/// (looked up on the factory at transfer time, then cached). The PoolManager settles a swap by checking
/// its own balance change, so a tax on either side of a pool swap would make every sell revert; this is
/// why pool swaps through the PoolManager are untaxed while wallet-to-wallet transfers, transfers to
/// other venues and exchange deposits are taxed.
contract NvidiaToken is ERC20 {
    // ------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------

    /// @notice The whole supply, minted once in the constructor: 1,000,000,000 ADVN with 18 decimals.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000e18;

    /// @notice Basis-point denominator for the two rates.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice 0.5% of every taxed transfer goes to the tribute recipient.
    uint256 public constant TRIBUTE_BPS = 50;

    /// @notice 1% of every taxed transfer is burned, reducing totalSupply.
    uint256 public constant BURN_BPS = 100;

    /// @notice Jensen Huang's wallet, as given by the requester. Fixed for the life of the token.
    address public constant TRIBUTE_RECIPIENT = 0xc59b0c072f73ceEA3Dc354031165501c0Ff25023;

    // ------------------------------------------------------------------------
    // Launch addresses (exempt from the tax)
    // ------------------------------------------------------------------------

    /// @notice The launch factory: receives the whole supply at deploy and pays it out untaxed.
    address public immutable factory;

    /// @notice The Uniswap v4 PoolManager: seeds and swaps settle exactly.
    address public immutable poolManager;

    /// @notice This launch's number on the factory, used to look up its MerkleDistributor.
    uint64 public immutable launchNumber;

    /// @notice The launch's MerkleDistributor once the factory knows it; zero until then.
    address public distributor;

    // ------------------------------------------------------------------------
    // Events and errors
    // ------------------------------------------------------------------------

    /// @notice A taxed transfer happened: `net` reached `to`, `tribute` went to the recipient, `burned` left supply.
    event TransferTaxed(address indexed from, address indexed to, uint256 net, uint256 tribute, uint256 burned);

    /// @notice The distributor was read from the factory and cached.
    event DistributorCached(address indexed distributor);

    /// @notice A launch address given to the constructor was zero.
    error ZeroAddress();

    // ------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------

    /// @param factory_ The launch factory (`$factory` in the manifest). It is `msg.sender` at launch and
    /// receives the whole supply.
    /// @param poolManager_ The chain's Uniswap v4 PoolManager (`$poolManager` in the manifest).
    /// @param launchNumber_ This launch's number on the factory (`$launchNumber` in the manifest).
    constructor(address factory_, address poolManager_, uint64 launchNumber_) ERC20("Nvidia", "ADVN") {
        if (factory_ == address(0) || poolManager_ == address(0)) revert ZeroAddress();
        factory = factory_;
        poolManager = poolManager_;
        launchNumber = launchNumber_;
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    // ------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------

    /// @notice How a taxed transfer of `amount` splits: what the receiver gets, what the tribute recipient
    /// gets and what is burned. Rounding favours the receiver: each cut is rounded down.
    function splitTransfer(uint256 amount) public pure returns (uint256 net, uint256 tribute, uint256 burned) {
        tribute = (amount * TRIBUTE_BPS) / BPS_DENOMINATOR;
        burned = (amount * BURN_BPS) / BPS_DENOMINATOR;
        net = amount - tribute - burned;
    }

    /// @notice Whether transfers from or to `account` move untaxed. True for the factory, the PoolManager
    /// and the launch's distributor (once the factory knows it).
    function isExempt(address account) public view returns (bool) {
        if (account == factory || account == poolManager) return true;
        address d = distributor;
        if (d == address(0)) d = _lookupDistributor();
        return d != address(0) && account == d;
    }

    // ------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------

    /// @dev Mints, burns and launch flows move exactly `value`. Everything else is split three ways.
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || value == 0 || _isLaunchFlow(from, to)) {
            super._update(from, to, value);
            return;
        }

        // Check the whole amount up front so the failure names the amount the sender asked for, not a slice.
        uint256 fromBalance = balanceOf(from);
        if (fromBalance < value) revert ERC20InsufficientBalance(from, fromBalance, value);

        (uint256 net, uint256 tribute, uint256 burned) = splitTransfer(value);
        super._update(from, to, net);
        if (tribute != 0) super._update(from, TRIBUTE_RECIPIENT, tribute);
        if (burned != 0) super._update(from, address(0), burned);
        emit TransferTaxed(from, to, net, tribute, burned);
    }

    /// @dev A transfer is a launch flow when either side is the factory, the PoolManager or the distributor.
    /// The distributor is read from the factory the first time it is needed and cached once it is known.
    function _isLaunchFlow(address from, address to) private returns (bool) {
        if (from == factory || to == factory || from == poolManager || to == poolManager) return true;
        address d = distributor;
        if (d == address(0)) {
            d = _lookupDistributor();
            if (d != address(0)) {
                distributor = d;
                emit DistributorCached(d);
            }
        }
        return d != address(0) && (from == d || to == d);
    }

    /// @dev Reads `distributorOf(launchNumber)` from the factory. Any failure (no code, a revert, a short
    /// answer) reads as "not known yet" so ordinary transfers never depend on the factory being reachable.
    function _lookupDistributor() private view returns (address) {
        (bool ok, bytes memory data) = factory.staticcall(abi.encodeCall(ILaunchFactory.distributorOf, (launchNumber)));
        if (!ok || data.length != 32) return address(0);
        return abi.decode(data, (address));
    }
}
