# Nvidia (ADVN)

A fixed-supply ERC-20 with a transfer tax, for a custom token launch on Ethereum (chain id 1).

| | |
|---|---|
| Solidity contract | `NvidiaToken` (`src/NvidiaToken.sol`) |
| Token name | Nvidia |
| Symbol | ADVN |
| Decimals | 18 |
| Total supply | 1,000,000,000 ADVN = `1000000000000000000000000000` minor units, minted once to the deployer in the constructor |
| Tribute | 0.5% of every taxed transfer to Jensen Huang, `0xc59b0c072f73ceEA3Dc354031165501c0Ff25023` |
| Burn | 1% of every taxed transfer, removed from `totalSupply` |
| Receiver gets | 98.5% of the amount sent |
| Admin | None. No owner, minter, pauser, blacklist, fee setter or upgrade path. |

Thank you for all you have done for the industry, Jensen.

## What it does

Every transfer that is not a launch flow is split three ways inside `_update`:

```
tribute = amount / 200               // 0.5% (= amount * 50 / 10_000, rounded down), to TRIBUTE_RECIPIENT
burned  = amount / 100               // 1%   (= amount * 100 / 10_000, rounded down), burned
net     = amount - tribute - burned  // 98.5%, to the receiver
```

Each cut rounds down, so rounding dust stays with the receiver. Amounts under 200 wei pay no tribute and amounts under 100 wei pay nothing. The sender's balance drops by the full amount, `transferFrom` spends the full amount of allowance, and three `Transfer` events plus one `TransferTaxed` event are emitted. The tribute recipient is an ordinary holder: when he sends, he pays the tax like anyone else (his own 0.5% returns to him, the 1% is burned).

`splitTransfer(amount)` returns the three parts for any `uint256` amount (it divides by the reduced denominators, so it cannot overflow), and `isExempt(account)` says whether transfers both from and to an account move untaxed (the factory and the distributor; not the PoolManager, which is exempt only as a receiver).

### Launch flows move exactly what they say

These transfers are untaxed:

- the launch factory (`factory`, immutable), which receives the whole supply at deploy and pays out the swarm's share, the pool seed and the requester's remainder;
- transfers **into** the Uniswap v4 PoolManager (`poolManager`, immutable), so the seed and every sell settle exactly. Transfers **out of** the PoolManager (pool buys, liquidity withdrawals, `take`) are taxed: the whole tax is taken from the PoolManager's balance and the receiver gets 98.5%;
- the launch's MerkleDistributor, read from the factory with `distributorOf(launchNumber)` the first time an ordinary transfer needs it, then cached in `distributor` and announced with `DistributorCached`. Until the factory knows it, nothing is exempt on that account.

The PoolManager settles a seed or a sell by measuring its own balance change (`sync`/`settle`), so tokens entering it must arrive whole, or every sell would revert. Tokens leaving it are not measured that way: `take` and swap payouts transfer out and the PoolManager does not re-check its balance, so taxing the outbound leg keeps its accounting whole. Taxing that leg closes the bypass where anyone could `sync`, transfer in, `settle` and `take` to another address inside one `unlock` and move ADVN wallet-to-wallet untaxed; that route now pays 1.5% on the `take`.

The lookup on the factory is a `staticcall` capped at `LOOKUP_GAS` (50,000) that treats any failure (no code, a revert, running out of gas, an answer that is not exactly one word, a word that is not an address) as "not known yet", so ordinary transfers never depend on the factory, and the constructor makes no external call at all.

## Assumptions

1. **"Trade" means transfer.** The brief says the fee is taken "from every trade". An ERC-20 cannot tell a trade from any other transfer, so the tax applies to every transfer that is not one of the launch flows above: wallet-to-wallet transfers, deposits to exchanges, transfers to or from Uniswap v2/v3 pairs, aggregators, bridges and any other contract.
2. **Buys from v4 pools are taxed, sells into them are not.** Tokens entering the PoolManager must arrive exactly (the launch seed and every sell), so that direction is exempt. Tokens leaving it (buys, LP withdrawals, any `take`) pay the 1.5% like any transfer. In the launch pool a buyer therefore receives 98.5% of the pool's quoted output, and a seller pays no token tax. Taxing sells too would need a v4 hook, which this launch does not deploy. ERC-6909 claim balances inside the PoolManager move untaxed, but converting them back to ADVN ends in a taxed `take`. **Requester to confirm** this reading of "from every trade".
3. **"1% burn of supply from every fee"** is read as: 1% of the transferred amount is burned on every taxed transfer, alongside the 0.5% tribute, for a total 1.5% tax. The alternative reading, burning 1% of the 0.5% tribute, would be 0.005% of the amount and was judged not to be the intent. If that reading was meant, `BURN_BPS` is the one constant to change. **Requester to confirm** before admission.
4. **The tribute recipient is fixed.** `0xc59b0c072f73ceEA3Dc354031165501c0Ff25023` is a `constant`, exactly as given in the brief. If that key is ever lost or the address is wrong, the 0.5% is unrecoverable; there is no setter by design, since the brief asked for no administrator.
5. **Rates are fixed.** 50 bps and 100 bps are constants. Changing them means a new token.
6. **No application contracts.** The launch deploys the token only.

## Deployment parameters

The launch factory deploys `NvidiaToken` from its bytecode and is `msg.sender` in the constructor, so it receives the whole supply. Constructor arguments, all static, in order:

| Position | Type | Argument | Manifest value |
|---|---|---|---|
| 0 | `address` | `factory_` | `$factory` |
| 1 | `address` | `poolManager_` | `$poolManager` |
| 2 | `uint64` | `launchNumber_` | `$launchNumber` |

`factory_` and `poolManager_` must be non-zero; the constructor reverts with `ZeroAddress()` otherwise. The constructor calls no other contract.

Manifest facts for the token: `contract` = `NvidiaToken`, `name` = `Nvidia`, `symbol` = `ADVN`, `decimals` = 18, `totalSupply` = `1000000000000000000000000000`. `launch.json` is written by the manifest step after acceptance, not by this repository.

Named constants, all in `src/NvidiaToken.sol`:

| Constant | Value | Meaning |
|---|---|---|
| `INITIAL_SUPPLY` | `1_000_000_000e18` | Whole supply, minted once |
| `TRIBUTE_BPS` | `50` | 0.5% tribute |
| `BURN_BPS` | `100` | 1% burn |
| `BPS_DENOMINATOR` | `10_000` | Basis points |
| `LOOKUP_GAS` | `50_000` | Gas cap on the factory's `distributorOf` lookup |
| `TRIBUTE_RECIPIENT` | `0xc59b0c072f73ceEA3Dc354031165501c0Ff25023` | Jensen Huang's wallet, from the brief |

Build settings in `foundry.toml`: `solc = "0.8.26"`, `evm_version = "cancun"`, optimizer on with 200 runs, `bytecode_hash = "none"` (required so the launch can compare deployed bytes), `ffi = false`, no filesystem permissions.

### After launch

Nothing to set. The token has no owner and no post-deploy configuration. The distributor address is discovered from the factory automatically on the first ordinary transfer after the factory records it.

### Local deployment script

`script/DeployNvidiaToken.s.sol` exists for local forks and dry runs only. Its `deploy(Config)` function takes the three constructor values explicitly and is what the tests call; `run()` reads `ADVN_FACTORY`, `ADVN_POOL_MANAGER` and `ADVN_LAUNCH_NUMBER` from the environment (reverting with `LaunchNumberTooLarge` if the number does not fit a `uint64`) and broadcasts. Running it directly mints the supply to whoever runs it, not to the factory, so it is not the production launch. The production launch is performed by IMD's deployer through the factory.

## Operational responsibilities

- **Nobody operates the token.** There is no key to hold, no parameter to tune and no pause to trigger. Any incident response is limited to communication.
- **Tribute recipient.** The address was supplied by the requester and is baked in. The requester should confirm, before the launch is admitted, that it is the intended wallet on Ethereum mainnet and that its holder can transact. As of 2026-11-12 the address had no code, no balance and no transactions on mainnet, so there is no on-chain evidence of control; a signed message from its key would settle it.
- **Integrators.** Exchanges, bridges, routers and vaults that assume `balanceOf(to)` increases by exactly `amount` will see 98.5% arrive. Deposit flows should read the balance delta. Uniswap v2 venues need their "supporting fee on transfer tokens" swap functions. Uniswap v3 has no such functions and its pools check the input balance exactly, so selling ADVN into a v3 pool reverts; a v3 pool would be buy-only. In the launch's v4 pool, sells settle exactly and buys deliver 98.5% of the quoted output.
- **Supply.** `totalSupply` only decreases, by the 1% burn on taxed transfers. Nothing can mint. Dashboards that reconcile supply should subtract the sum of `Transfer(_, address(0), _)` events or the `burned` field of `TransferTaxed`.
- **Launch policy items** (pool fee 1.25%, tick spacing 60, 88% of supply to the pool, 10 ETH opening cap, remainder to `0xd3959c80d11b4d2841fda01de9a0d9b36c52217e`) are the manifest step's and are not encoded in the contract.

## Security notes

- Built on OpenZeppelin Contracts v5.7.0 `ERC20`; the only override is `_update`. `transferFrom` moves tokens only against the caller's allowance.
- No `delegatecall`, `callcode`, `selfdestruct`, proxies, initializers, assembly in the contract, `abi.encodePacked`, or shifts. The only external call is a read-only `staticcall` to the factory, before any state write in the same function, and it cannot re-enter.
- The whole-amount balance check happens before the split so an insufficient balance reverts with `ERC20InsufficientBalance(sender, balance, amountRequested)`.
- Tests passing is not an audit. The token holds no funds, but an independent adversarial review before launch is still the right step. Slither was not available on this machine and was not run; the code avoids the detectors the verifier rejects on by construction.

## Tests

```
forge build
forge test
forge fmt --check
FOUNDRY_FUZZ_SEED=0x329ff73a672b06b30678c85198cf5a01f6b43dc29fa5584a20495b66b237949f forge test
```

43 tests across two suites, all passing locally with the seed above:

- `test/NvidiaToken.t.sol`: metadata and supply; constructor rejections; the deploy function; exact flows for the factory and the distributor, exact inbound and taxed outbound for the PoolManager, a sync/settle/take escrow route that pays the tax, the distributor (including caching, another launch's distributor, and factories with no code, a reverting answer, a short answer, a non-address word, a gas-burning answer or a huge answer); `splitTransfer(type(uint256).max)`; the three-way split with events; rounding on tiny amounts; `transferFrom` and allowance; the tribute recipient and self transfers paying tax; insufficient balance and allowance reverts with exact arguments; absence of mint, owner and admin entry points; a runtime bytecode scan for `DELEGATECALL`, `CALLCODE` and `SELFDESTRUCT`; fuzz tests for value conservation, the split, exempt flows, overspending and supply never growing.
- `test/NvidiaToken.invariant.t.sol`: a handler drives random `transfer` and `transferFrom` calls among users, the three launch addresses and the tribute recipient, with an independent model of the burn and of the recipient's balance. Invariants: `totalSupply == INITIAL_SUPPLY - burned`, balances sum to `totalSupply`, the recipient's balance matches the model, and the cached distributor is only ever the factory's.

Tests read no environment variables and depend on no caller address.

## Dependencies

Vendored as ordinary files under `lib/` (no submodules):

| Library | Version | Commit |
|---|---|---|
| forge-std | v1.9.7 | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` |
| OpenZeppelin Contracts | v5.7.0 | `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` |

Remappings are in `remappings.txt`.
