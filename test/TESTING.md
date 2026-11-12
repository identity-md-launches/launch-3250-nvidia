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
supply. The supplied launch checks require exact factory, distributor and pool
flows, so those endpoints are tested as exempt. This includes pool trades: these
tests do not claim that trades through that pool collect the ordinary transfer tax.
The burn is a supply reduction, not a balance assigned to the zero address.

The supplied protected tests also exercise a complete Uniswap v4 launch in the
verification harness. This repository's new tests check the token boundary; they
do not claim to reproduce those external factory and pool contracts locally.

Two confirmed limitations are reported in `.imd-findings.json`, each with its
complete self-contained Foundry proof source and the observed failure:

- An exactly 32-byte factory result with nonzero address padding reverts during
  decoding instead of being treated as unknown. This requires a faulty trusted
  dependency before discovery is cached.
- `splitTransfer(type(uint256).max)` panics on intermediate multiplication. This
  affects large preview inputs, not transferable amounts within the fixed supply.

Both proofs were executed and failed for the reported reasons. They are embedded
in the findings rather than submitted as passing tests that endorse the defects.
The wrong-length response fuzz test covers lengths other than 32 explicitly; the
reported proof covers the missing malformed 32-byte case. Actual transfer fuzzing
uses feasible balances, while the maximum preview limitation remains reported.
