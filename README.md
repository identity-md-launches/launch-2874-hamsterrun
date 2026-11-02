# HamsterRun v3 — certified wheel training

Training now earns stamina only from physical work certified by SqueekCore on Sepolia. Starting training books six rounds; elapsed time alone never pays. The NFT name is **hamsterrun**, symbol **HMR**.

This delivery is a **new, versioned suite**, ready for the IdentityMD network deployment. No transaction was signed or broadcast. New addresses are pending in [deployments/sepolia.json](deployments/sepolia.json); the old v2 addresses are separately labeled in [deployments/sepolia-v2.json](deployments/sepolia-v2.json). Do not use the old NFT with the new ABI.

## Contracts and deployment parameters

| Order | Application | Nonpayable constructor arguments |
| --- | --- | --- |
| 1 | `HamsterRunNFT` | `initialOwner`: `0x6c14430adacc99e27f6180bc5a74d6768616bf4a`; `coreAddress`: `0x74665dAecA35A2303e767E76a2FF1FB6F93e119f` |
| 2 | `MatchQueue` | `nftAddress`: the new `HamsterRunNFT` address from step 1 |

Chain: **Sepolia, 11155111**. Both contracts are immutable implementations, without proxies. Constructors perform no external calls and work on an empty chain. The manifest step supplies `$owner` and the backward reference `$contract:HamsterRunNFT`; this repository deliberately contains no `launch.json`. `CoreReader` is an abstract component inherited by the NFT. `GameMath` is entirely internal; `PointsLedger` is abstract. Deploy only the two applications above.

The Core binding is immutable. No owner can replace it, supply work, or bypass its frontier. Core itself is an upstream governance-upgradeable proxy: [published Core reference](https://docs.squeekchain.com/developers/core/). The exact v3 ABI is pinned in [abi/SqueekCore.upstream.json](abi/SqueekCore.upstream.json), its read subset in [abi/ISqueekCore.json](abi/ISqueekCore.json), and all ABI SHA-256 hashes in [abi/SHA256.json](abi/SHA256.json).

## Build and verification

Foundry at the repository root pins Solidity **0.8.26**, Cancun, optimizer 200 runs, and `bytecode_hash = "none"`. Dependencies are vendored ordinary files with licenses and pins in [dependencies.json](dependencies.json). No network, environment variables, submodules, FFI, filesystem cheatcodes, npm install, or keys are needed by the tests. The verifier supplies the pinned compiler. Node 22+ is sufficient for the optional dependency-free tooling checks.

```sh
forge build
FOUNDRY_FUZZ_SEED=0xbaf830ada79f2a3ded3bca9b270689b5115b737c37d804cb61cdc9a8b18ed84f forge test
forge fmt --check
node tools/export-abis.mjs --check
node --test --test-isolation=none test/Tools.test.mjs
```

The seed is also pinned in `foundry.toml`. Run `node tools/export-abis.mjs` after changing the contracts and rebuilding. It exports both application ABIs and checks the Core interface against the independently published upstream ABI. Foundry compilation is the Solidity type check; its built-in lint output is reviewed in [SECURITY.md](SECURITY.md).

Tests cover certification lag, all-zero and sparse windows, work before/after the booked interval, food snapshots, hunger, overflow, malformed/unavailable Core responses, real Sepolia ABI return bytes, ownership, ERC-721 callbacks, the full supply cap, queue randomness/recovery, and stateful fee/reward/lock invariants. See [docs/VALIDATION.md](docs/VALIDATION.md) for the final run record.

## Rules and formulas

Full boundaries and arithmetic are pinned in [DESIGN.md](DESIGN.md).

| Rule | Value |
| --- | --- |
| Supply | 9999 per new collection; one free mint per wallet, starting stamina 10 |
| Newborn | Body score 50, Normal, Hungry until fed; never burned for hunger |
| Food lifetime | 72 hours from the latest feed; exact expiry is still fed |
| Low / mid / high price | 0.0001 / 0.0002 / 0.0003 ETH |
| Low / mid / high multiplier | 10000 / 15000 / 20000 bps |
| Current round | `floor((now - Core.configuration().genesisTimestamp) / 600) + 1` |
| Booked interval | `[currentRound, currentRound + 5]`, both endpoints inclusive |
| Ready | `Core.state().settledThroughRound >= trainEndRound` |
| Certified work `W` | `Core.roundPage(start-1, end, 6).end.cumulativeWork - .start.cumulativeWork` |
| Training gain | `floor(2 * W * lastFeedBps / 10000)` |
| Default gain per physical work unit | 2 / 3 / 4 stamina; all tiers earn 0 when `W = 0` |
| Weight | Fit at body score ≥70; Normal 35–69; Obese 0–34 |
| Feeding while booked | Allowed (Idle or Training); the booking keeps the food snapshot taken at `startTraining` |
| Inactivity while booked | The idle clock pauses at booking; positive work resets it, zero work or cancel resumes it |
| Match band / wait | Band 0 below 500 stamina, then `floor(log2(stamina / 500)) + 1` (each band spans ×2) / 10 blocks per entry |
| Match attempts | 5 per NFT per Unix-epoch week |
| Match reward | Winner +3 stamina/+10 points; loser +1 stamina/+2 points |

Two stamina per physical work unit is a chosen game conversion, not an upstream unit definition or token exchange rate. It keeps the existing 1×/1.5×/2× food multipliers strictly ordered even at one unit of work. Configurable multipliers must have gaps of at least 5000 bps and remain within 10000–50000. For positive work, tiers under the same configuration strictly order; zero work gives zero for everyone. Existing feeds retain their captured multiplier across configuration changes. No diminishing term, minimum reward, or time-based reward remains.

Stamina uses checked `uint256` addition with no gameplay cap. The last feed's tier and bps are captured at booking. Only the token owner may start while fed and Idle. Anyone may settle once certified, including after food expiry. The owner may cancel at any time, forfeiting all work. Cancellation remains possible if Core is paused, unavailable, or incompatible.

Zero-work settlement clears the lock without a training body bonus or inactivity reset. Positive-work settlement keeps v2's body formula and cheap-food ceiling. The time a pet spends locked waiting for certification is never charged as inactivity, and the owner can keep feeding on the 72-hour cadence through that wait; hunger is still the owner's to prevent. MatchQueue keeps the pinned parent's queue, randomness, quota and points accounting; only its band rule changed from a 25-point grid to the geometric bands above, because one certified window pays thousands of stamina at live Sepolia work levels (the pinned 1012-work window pays 2024 / 3036 / 4048) and a linear grid would never pair two trained pets. Its future-block randomness is the existing non-financial testnet mechanism, not a VRF; [SECURITY.md](SECURITY.md) documents proposer bias and missed-fulfillment recovery.

## After launch

| Responsibility | Operation |
| --- | --- |
| Network deployer | Deploy the NFT and queue in the order above; publish receipts, verify source, and complete the independent release review |
| Owner | Verify the new queue's runtime and `nft()` binding; call `setMatchQueue(newQueue)` **once** |
| Owner | Call `setMintOpen(true)` when ready; it defaults to false |
| Owner | Keep the default food parameters or call `setFoodConfig(prices,bps)` within the documented bounds; default setup needs no config transaction |
| Owner | Withdraw earned feed fees with `withdraw(amount)`; transfers go only to the current owner |
| Players / keeper | Settle certified training, request queue rounds, fulfill within the blockhash window, settle matches, and evict/expire stale queue states |
| Squeekchain Reporter / governance | Certify upstream work and maintain Core availability; HamsterRun cannot perform or accelerate this role |
| Client operator | Publish confirmed v3 addresses and ABI hashes, display frontier versus booked end with the certification-lag banner, keep feeding available during the wait, and monitor upstream ABI/clock changes |
| Squeekchain Reporter (trust assumption) | Throughput is one booked window per certification lag (about 6.8 days behind at review time). A `roundDuration` or ABI change on the upgradeable Core proxy stops new bookings or settlement for good; cancellation always remains |

Owner handover uses two-step acceptance. Owner mints share the 9999 supply limit. Queue replacement and ownership renunciation are disabled. No keeper subscription, scheduled service, or transaction funding is bundled. Feed payments buy care and are not escrowed against work: zero work, cancellation, and a delayed Reporter do not create a refund claim.

Local constructor rehearsals, with no broadcast:

```sh
forge script script/Deploy.s.sol:DeployHamsterRunNFT --chain-id 11155111 --sig 'run(address)' 0x6c14430adacc99e27f6180bc5a74d6768616bf4a
```

`DeployMatchQueue.run(address)` accepts the new NFT address. The network factory handles the actual deployment.

After deployment reaches finality, invoke the read-only recorder with actual arguments:

```text
node tools/record-deployment.mjs RPC_URL NFT_ADDRESS QUEUE_ADDRESS
```

It checks Sepolia, both exact runtimes (including both immutable dependency addresses), the specified owner, Core ABI/clock, and the queue bindings at one finalized block. It then writes `deployments/sepolia.json`. It may record before owner setup, reporting `queueBound` and `mintOpen` explicitly. It never signs, broadcasts, reads environment variables, or stores the RPC URL. Use a provider supporting EIP-1898 block-hash references. A mismatch leaves the pending record untouched.

## Smoke: mint → feed → book → certify → settle → match

The deterministic smoke test runs without real waiting:

```sh
forge test --match-test test_endToEndMintFeedTrainQueueRandomMatchSettle -vv
forge test --match-path test/CoreTraining.t.sol -vv
```

On Sepolia after owner setup:

1. Two wallets each `mint()` and find their IDs in `HamsterMinted`/`Transfer`. Check stamina 10 with `hamster(id)`.
2. Each `feed(id,2)` with exactly 0.0003 ETH, then `startTraining(id)`. Read `training(id)`: `(trainStartRound,trainEndRound,lastFeedBps,tier)`. There is no `readyAt` or promised gain.
3. Read `trainingStatus(id)` or run `node tools/training-status.mjs RPC_URL NFT_ADDRESS TOKEN_ID`. Show **Core frontier** and **booked end** side by side. While `waitingForCertification` is true, display:

   **WAITING FOR CORE CERTIFICATION — settle is unavailable. No gain is known yet.**

   A wall-clock countdown is not readiness. Disable settlement while lagging. Display an unavailable error on RPC/Core read failure, not zero work. Keep the feed button enabled while the banner shows: the pet's 72-hour food window keeps running during the wait and `feed(id,tier)` is allowed in Training (the booked tier is unaffected). Show the pet's body score without an idle penalty for the wait. If the owner wants to leave, `cancelTraining(id)` unlocks without a reward. At review time the live frontier was about 6.8 days (980 rounds) behind the clock, so expect this banner to be the normal state of a fresh booking.
4. Once `ready` is true, `work` and `gain` are authoritative for that call. Anyone calls `settleTraining(id)`. For a five-unit window, high food adds 20; for zero units, it adds zero. A false `ready` must never be interpreted as a known zero reward. Observations from the CLI use finality and may lag the latest block.
5. Each owner calls `MatchQueue.enqueue(id)`. Use the actual `bandOf(id)` (or `bandForStamina(stamina)` to preview): below 500 stamina every pet is in band 0, and above that pets within a factor of two share a band, so two pets trained on comparable windows (say 8862 and 8010 stamina) both sit in band 5. The wallets need the same band. After each has waited ten blocks, anyone calls `requestRound(band)` when `eligibleCount(band) >= 2`.
6. After `entropyBlock` and no later than `entropyBlock + 256`, anyone calls `fulfillRound(roundId)`, then `settleMatch(matchId)` for each emitted match. The pair's combined stamina grows by 4 and points by 12; both unlock. An odd roster receives one random bye with its attempt refunded.

The raw [Core snapshot](docs/core-sepolia-snapshot.json) is pinned to finalized Sepolia block **12047523**. It reports frontier **1973**, genesis **1791847800**, duration **600**, implementation version **3**, and timestamp **1793614932** (derived current round **2946**). A new booking at that observation would end at 2951 and wait for certification. This is historical evidence, not a claim that the Reporter has caught up or a substitute for a fresh read. The offline ABI test also decodes a real sparse window with 1012 certified work units.

## Versioned replacement of v2

Care is fused into v2's immutable NFT, so its six-hour training cannot be patched at the existing address. Deploy both v3 applications anew, keep the old suite clearly labeled, and update any future client integration to the new addresses and ABIs. Existing v2 tokens, stamina, points, quota and mint history stay in v2; there is no state migration, bridge, forced burn, or conversion claim. The v3 wallet-mint flag and supply cap apply independently to its new collection.

No website, SQK issuance, SqueekMining claims, MatchBook challenge flow, insurance, airdrop entitlement, ERC-20, pool, or mainnet deployment is included. Provenance and exact retained dependencies are in [docs/PROVENANCE.md](docs/PROVENANCE.md).
