# Nvidia adversarial test coverage

The existing suites are retained. The additional tests use the vendored Foundry and
OpenZeppelin libraries and require no network, environment-supplied addresses, fork,
FFI, new dependencies or configuration changes.

Run from the repository root:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x329ff73a672b06b30678c85198cf5a01f6b43dc29fa5584a20495b66b237949f forge test
```

The new stateless fuzz suites specify 1,000 runs in their source files. The new
stateful suite specifies 256 sequences of depth 64. Existing configuration still
makes unexpected handler reverts fail the invariant campaign.

## Discovery and property plan

The supplied Pashov fizz discovery guides were applied as five manual review
passes, with the Trail of Bits guidance used to check input bounds, independent
oracles, nonvacuity and failure classification. These are the selected properties
and their concrete source anchors; no helper agents were used.

| Pass | Property and basis | Delivered coverage |
| --- | --- | --- |
| Conservation | All balances add to supply; supply plus cumulative burns equals the constructor supply (`src/NvidiaToken.sol:84`, `src/NvidiaToken.sol:124`). | Independent per-holder ledger, aggregate supply invariant, full-supply transfer and passive token recipient. |
| Rounding and round trips | Tribute and burn round down (`src/NvidiaToken.sol:91`); moving tokens out and back cannot create value. | Literal boundary table, quotient/remainder bounds, preview versus executed transfer, 200-wei periodicity, round trip loss accounting. |
| State transitions | Approvals persist, overwrite and revoke; failed transfers undo allowance consumption and cache discovery. Discovery is initially unknown and becomes cached on a successful transfer (`src/NvidiaToken.sol:132`, inherited ERC20 `approve`, `transferFrom`, `_spendAllowance`). | Finite/infinite/max-minus-one approvals, full state snapshots around failures, delayed publication, read-only lookup, cache stability and dependency outages. |
| Adversarial inputs | Neither insufficient balance nor insufficient authorization may move value; factory failures must not block funded holders (`src/NvidiaToken.sol:121`, `src/NvidiaToken.sol:145`). | Exact errors, maximum uint256 transfer attempts, net-only authorization, zero endpoints, wrong-length/reverting dependency responses; malformed address proof reported separately. |
| Token-specific behavior | No post-constructor minting; zero-address balance remains zero; launch transfers arrive whole; sender/recipient/tribute aliases must preserve accounting (`src/NvidiaToken.sol:112`). | Constructor event and deployer assertions, burns, launch endpoint authorization in both directions, self-transfers, Jensen as source/destination/both, zero transfers and events. Existing admin-entry-point checks remain in place. |

The accounting identities and explicit transfer/allowance guarantees are required
properties. The full-domain preview and malformed lookup hypotheses were tested
separately, then classified by their actual impact rather than assumed to be
critical failures.

## Stateful harness

`NvidiaToken.stateful.t.sol` targets only the eight action selectors in
`handlers/NvidiaTokenStateHandler.sol`. Seven active holders include the factory,
pool, distributor, Jensen and three ordinary accounts. The token contract is also
tracked as a passive recipient, so direct token deposits cannot disappear from the
balance sum. Every destination is inside this closed ledger.

The handler retains approvals across calls, including finite and unlimited grants;
successful `transferFrom` calls do not automatically approve themselves. Ordinary
operators exercise delegated spends. Raw delegated attempts independently predict
allowance and balance errors, and failed direct transfers include zero recipients,
balance plus one and maximum uint256. Both successful and failed calls are checked
against every modeled balance and allowance after each step.

Amounts deliberately include zero, one, 99, 100, 199, 200, full available balances
and arbitrary bounded values. Self-transfers have a dedicated action. Distributor
publication and factory availability vary independently; the model distinguishes
live lookup from a permanently cached address. It never calls the token's
`splitTransfer` or `isExempt` to calculate expected amounts or roles.

The deterministic handler test checks the invariants between actions and verifies
that positive taxed, exempt and delegated transfers, rejected spends and cache
discovery actually execute. This supplements random selector coverage without
assuming every individual random sequence contains every action.

## Economics and limits

Ordinary transfers use the accepted implementation's documented interpretation:
0.5% of the gross amount goes to Jensen and 1% of the gross amount is removed from
supply. The burn is a supply reduction, not a balance assigned to the zero address.

Launch flows follow the revised implementation: the factory and the published
distributor are exempt in both directions; the Uniswap v4 PoolManager is exempt only
as a receiver (seeds and sells arrive whole). Transfers out of it (buys, withdrawals,
`take`) are taxed, and the whole gross amount leaves its balance. The stateful model
encodes exactly that rule (`to == pool` is exempt, `from == pool` is not) and counts
that taxed pool payouts actually happen. Where the token consults the factory (any
transfer whose receiver is not the pool and where neither side is the factory,
including transfers out of the pool) the model expects the distributor to be cached.

`test/NvidiaToken.pool.t.sol` covers the pool rule directly with an independent spec
oracle (`Math.mulDiv(amount, 50, 10_000)` and `Math.mulDiv(amount, 100, 10_000)`):
outbound payouts directly and via `transferFrom` (gross allowance spent), a sell and
buy-back round trip that loses exactly the tax, pool to factory and pool to
distributor (taxed until the factory names it, exact after), pool self-transfers,
overspend and short-allowance reverts with full rollback, and the emitted legs.

It also covers a griefing angle: a first distributor claim submitted with a chosen
gas limit, so the capped factory lookup might fail and the claim be taxed. A fuzz
test checks the claim is either exact or reverts; an exhaustive scratch sweep over
gas limits 5,000 to 120,000 in steps of 7 found 8,605 exact claims, 7,824 reverts and
no short claim.

The two limitations reported in the previous round are fixed by the revision and are
now regression tests rather than findings:

- a 32-byte factory answer that is not an address is treated as unknown, not cached,
  does not block transfers, and a later valid answer is still honoured (fuzzed over
  every word above `type(uint160).max`);
- `splitTransfer` matches the spec over the whole `uint256` range, including
  `type(uint256).max`.

The supplied protected tests exercise a complete Uniswap v4 launch in the
verification harness. These tests check the token boundary with a minimal escrow
PoolManager; they do not reproduce the external factory and pool contracts locally.
No open findings remain for the revised implementation.
