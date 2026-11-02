# Local validation record

Revision: HamsterRun v3 certified-wheel training. Checked 2026-11-02 with Foundry 1.8.3 and the repository-pinned Solidity 0.8.26 compiler. No transaction was broadcast. These are local results, not independent acceptance or an audit attestation.

| Check | Result |
| --- | --- |
| `forge build` and `forge build --sizes` | Pass; Solidity compilation/type checking succeeds |
| `forge lint src` | Exit 0 with reviewed warnings; dispositions in `SECURITY.md` |
| `forge test` | **198 passed, 0 failed, 0 skipped**, 12 suites |
| `forge fmt --check` | Pass |
| `node tools/export-abis.mjs --check` | Pass; both app ABIs, read interface, published Core ABI match and file hashes checked |
| `node --test --test-isolation=none test/Tools.test.mjs` | **19 passed, 0 failed** |
| README's local `DeployHamsterRunNFT.run(address)` rehearsal | Pass; no RPC or broadcast; local gas used 4372590 |

All fuzzing used `0xbaf830ada79f2a3ded3bca9b270689b5115b737c37d804cb61cdc9a8b18ed84f`, both set explicitly for the final run and pinned in `foundry.toml`. Standard fuzz tests ran 512 cases. The general game invariant campaign ran 128 × 64 = 8192 calls with zero unexpected reverts. The broader world-state campaign ran 96 × 96 = 9216 calls with zero unexpected reverts; its seeded walk additionally verifies that its success/failure branches are actually reached. Foundry reports each grouped invariant campaign as one test in the 198 total.

## Application size and launch checks

| Application | Runtime bytes | Initcode bytes before constructor arguments | Arguments |
| --- | ---: | ---: | ---: |
| HamsterRunNFT | 18553 | 19713 | 64 bytes |
| MatchQueue | 10631 | 10877 | 32 bytes |

Both are below EIP-170's 24576-byte runtime and EIP-3860's 49152-byte initcode limits. The factory rehearsal checks explicit ownership, dependency references, constructor success without dependency code, size limits and absence of reachable forbidden application opcodes. The root build uses no linked external libraries, FFI, filesystem permissions, path-pinned compiler, or network-dependent imports.

`MatchQueue.sol` and `PointsLedger.sol` remain byte-for-byte equal to the pinned parent's source, including after formatting. Their SHA-256 digests are:

```text
MatchQueue.sol   c325e51a845447f42d09a24a7ffb06a1c7a255f7842ce230256ea809cef52c18
PointsLedger.sol 7f3f7684da40c712007df76b9020112a8986b8f00c5ac785ae92153e19b6a21f
```

## Core-specific evidence

`CoreTraining.t.sol` exercises booking phases, round 1, frontier lag despite elapsed time, partial certification, sparse/all-active/zero-work windows, backlog and later work exclusion, independently overlapping pets, permissionless once-only settlement, cancellation without Core, unavailable/malformed reads, safe-transfer locks, configuration changes, round/stamina overflow and strict food-tier arithmetic.

`CoreAbi.t.sol` consumes raw read responses from the actual SqueekCore proxy at finalized Sepolia block 12047523. It checks configuration and one-based current round, frontier 1973, and the inclusive historical interval 1868–1873. That page starts at cumulative work 143148, ends at 144160, and has three active records, so certified work is 1012. High food yields 4048 stamina from that window. The test is offline and has no reliance on `test/scratch/`, local environment variables or the RPC provider.

The optional Node tools' tests verify finality/block-hash pinning, exact runtime checks with both immutable dependencies, wrong chain/code/owner/bindings, failed Core reads, strict ABI encodings, and the distinct waiting/ready-zero/ready-positive/paused messages. They call a local RPC fixture and write no deployment record.

## Limits of this validation

The protected network harness was read but not run using fabricated launch environment values. Its final manifest, actual CREATE2 addresses, independent owner checks and deployment receipts belong to later network steps. No new suite is live yet, and the pending address record contains no invented application address.

No independent audit, Slither run, Mythril run, wheel-sensor verification, live v3 transaction, mainnet test, or website test is claimed. The live Core read proves ABI compatibility at the recorded block; it does not prove future Reporter availability, immutable upstream governance, or economically secure race randomness.
