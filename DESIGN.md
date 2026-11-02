# HamsterRun v3 contract design

## Scope and deployment

Two fresh Sepolia applications replace the v2 product path: `HamsterRunNFT(address initialOwner,address coreAddress)` and `MatchQueue(address nftAddress)`. There is no proxy, initializer, upgrade hook or embedded deployment. Both nonpayable constructors accept only static addresses and call no dependency. The owner is supplied explicitly, never inferred from a factory or transaction origin. The queue has no owner. `CoreReader` is inherited by the NFT and has no separate deployed instance.

The Core constructor argument is the brief's Sepolia proxy `0x74665dAecA35A2303e767E76a2FF1FB6F93e119f`; it is immutable. New application addresses come from the network deployment. Binding the queue after launch is a one-time owner operation that checks nonzero code and that `queue.nft()` points back to this NFT. The owner must verify the intended bytecode first. Care operates before that binding; queue operations revert `QueueNotConfigured` until it exists.

## NFT and locks

Name `hamsterrun`, symbol `HMR`, ERC-721 with on-chain JSON metadata. IDs start at 1 and lifetime supply is at most 9999. Free `mint()` requires `mintOpen` and a never-before-used `freeMinted[wallet]`; transfer does not reset it. Owner mints bypass the free-mint flag but share the cap and starting stats. Each pet starts with `uint256 stamina = 10`, body score 50, Normal weight, Idle activity, and no feed. There is no burn-on-hunger path.

The state machine is:

```text
Idle --fed owner startTraining--> Training --Core-certified settle--> Idle
                                       \--owner cancel (no gain)--> Idle
Idle --fed owner enqueue-------> Queued   --owner leave / eviction--> Idle
                                    \----round lock---------------> Matched
Matched --settle reward / expiry / entropy-chosen bye---------------> Idle
```

Only the actual NFT owner plays care, training and enqueue actions; ERC-721 operators do not acquire those rights. All transfers, including safe and approved transfers, share `_update` and require Idle. Feeding is allowed while Idle **or Training** and refused while Queued or Matched; it cannot alter an active training or race snapshot. Read functions never mutate care state. Safe mint and mutating gameplay functions use reentrancy guards, and state is established before receiver callbacks.

## Food and hunger

`feed(id,tier)` requires the owner, an activity of Idle or Training, valid tier 0–2, and exactly its configured price. Defaults are 0.0001/0.0002/0.0003 ETH and 10000/15000/20000 bps. Payment is retained as owner revenue. Overpayment and underpayment revert; there is no race pot or refundable escrow.

Feeding during Training exists because the Training lock lasts until SqueekCore certifies the booked end round, which is unbounded and outside the player's control (about 6.8 days behind the clock on Sepolia when reviewed). A booking snapshots `lastFeedBps` and `tier` at `startTraining` and settlement reads only that snapshot, so a feed during the wait changes nothing about the reward: it only renews the 72-hour window, applies the usual food body effect, and sets the food the *next* booking will capture. Queued and Matched stay closed to feeding because those locks hold a stamina/weight snapshot a race depends on.

Feeding projects prior neglect, sets `fedUntil = now + 259200`, and captures `foodTier` and `trainBps`. It resets the hunger-damage counter, not the inactivity clock. Food durations do not stack. Hunger is `fedUntil == 0 || now > fedUntil`; exact equality remains fed. Hungry pets cannot start training or enter/lock a queue round. Food expiry does not erase certified booked work or an existing match outcome. Hunger never destroys stamina or tokens.

The owner may change prices and bps, subject to:

```text
0 < price0 < price1 < price2
10000 <= bps0 < bps1 < bps2 <= 50000
bps1 - bps0 >= 5000
bps2 - bps1 >= 5000
```

Already-fed pets keep the old bps. Existing bookings keep their exact captured bps and tier. Strict ordering compares equal work under one configuration; pets fed under different historical configurations are not repriced to today's tiers. This replaces v2's artificial lower-tier reward floor, which could change a fed pet's gain when the owner changed configuration.

## Round booking and certified work

SqueekCore's pinned ABI defines `configuration()`, `state()` and `roundPage(uint64,uint64,uint256)`. It has **no `currentRound()` getter**. HamsterRun derives its own:

```text
G = Core.configuration().genesisTimestamp
R = floor((block.timestamp - G) / 600) + 1
start = R
end   = R + TRAIN_ROUNDS - 1 = R + 5
```

Round 1 starts at `G`; its interval is `[G,G+600)`. Round `r` ends at `G+r*600`. Before genesis, booking reverts `CoreNotStarted(G)`. Zero genesis or a duration other than 600 reverts `UnsupportedCoreConfiguration`. Explicit range checks reject current/end round overflow before narrowing to `uint64`. `TRAIN_ROUNDS=6` is fixed; neither owner nor caller chooses a historical start or custom duration.

`startTraining(id)` checks owner, Idle and currently fed, reads the Core configuration, stores `(trainStartRound,trainEndRound,lastFeedBps,tier)`, records the booking timestamp in the private care clock (`trainBookedAt`), and locks the token. It does not read all-time work as a baseline: at booking, the upstream frontier may be far behind the start. The correct lower endpoint is looked up in history after certification.

Both endpoints are **inclusive**. Since the brief starts at the current round, the first round is counted whole, including wheel work earlier in that round before the booking transaction. Six booked rounds therefore finish in just over 50 to 60 minutes of wall time, followed by an unbounded certification delay. There is no time prorating, six-hour completion rule, or claim of exactly sixty minutes after the transaction. Each token independently uses the global wheel-work ledger; this is not an exclusive allocation of work across tokens or a proof of the holder's own exercise.

Settlement algorithm:

1. Require an existing token in Training.
2. Read `Core.state().settledThroughRound = F`. If `F < end`, revert **`CoreCertificationLag(F,end)`**. The whole call rolls back; no partial reward or unlock occurs.
3. Read exactly `Core.roundPage(start-1,end,6)`. The first argument is exclusive, the second inclusive. Six consecutive rounds contain at most six active records, so this budget must cover the whole window in one bounded read.
4. Require `page.certifiedThroughRound == end`, at most six records, increasing in-window record IDs, strictly increasing record cumulative work, and a consistent final cumulative endpoint. Reject a short/malformed page with `InvalidCorePage`; never treat it as a complete or zero-work window.
5. `W = page.end.cumulativeWork - page.start.cumulativeWork`. This counts only booked physical work, even if earlier backlog or much later rounds were certified in the same batch. Zero-work rounds have no active record; a complete empty page with equal endpoints has `W=0` and is valid.
6. Compute the gain below, apply care projection and any positive-work body credit, delete the training record, return to Idle and emit the certified work and actual gain.

`state()` is the certification authority, not a timestamp or missing-record heuristic. Settlement does not re-read genesis, duration, difficulty, maximum batch size or current configuration; an unrelated future config change must not invalidate readable historical work. Core pause stops its new certifications but not reads of already-certified work. Typed calls use `STATICCALL`; no Core write, token claim, Reporter role or work submission exists in this suite.

## Stamina arithmetic

For certified physical work `W` (Core's `uint64` cumulative-work units) and captured multiplier `b`:

```text
baseGain = STAMINA_PER_WORK * W = 2 * W
gain     = floor(baseGain * b / 10000)
S_next   = S + gain
```

There is no dependence on training duration, settlement timestamp, cumulative work outside the interval, difficulty, or the pet's current stamina. The chosen two-stamina conversion avoids rounding away the default half-step food tier. For defaults, the formula simplifies to `2W`, `3W`, `4W`.

| Certified work | Low | Mid | High |
| ---: | ---: | ---: | ---: |
| 0 | 0 | 0 | 0 |
| 1 | 2 | 3 | 4 |
| 5 | 10 | 15 | 20 |
| 1012 | 2024 | 3036 | 4048 |

For any positive integer `W`, increasing `b` by at least 5000 increases the unfloored expression by at least `W`, so the floored gain is strictly larger. Zero work must remain zero in all tiers. The work product is at most `(2^64-1)*100000`, far below `uint256` capacity. Non-default bps round down; no bonus is invented to compensate for rounding.

Scale against the live ledger: the pinned Sepolia window 1868–1873 carried 1012 work (2024 / 3036 / 4048 stamina by tier), the long-run average is about 75 work per round (roughly 450 per window, 900–1800 stamina), active windows reach 2000–3300 work, and single rounds up to 1303. Certified work therefore dominates every other stamina source by design: a match pays +3/+1 and the body credit `min(gain,10)` saturates at 5 work on high food. Stamina is a cumulative record of certified wheel work, not a balanced per-session reward, which is why the MatchQueue pairs pets by stamina *ratio* (below) rather than by a fixed-width grid.

Stamina and its addition remain checked `uint256` values without a gameplay ceiling. At the machine representation limit, settlement reverts atomically and the owner can cancel; it never wraps or saturates. Race math uses OpenZeppelin full-precision `mulDiv`. Uncapped does not mean infinite machine integers.

Permissionless settlement remains allowed after food expires; the brief only gates booking on being fed. It applies hunger neglect at settlement and awards only the booked certified work. `cancelTraining` requires the owner, does not read Core, deletes the booking and unlocks without stamina, body credit, fee refund, or inactivity reset; like a zero-work settlement it resumes the paused inactivity clock (below). A cancelled record cannot be settled. Successful settlement is once-only; under Core's rule that only ended rounds can be certified, the next current-round booking is strictly after the previous end.

## Body score

Score `B` remains in 0–100. Fit is `B>=70`, Normal is 35–69, Obese is below 35. Lazy projection applies only newly accrued neglect:

```text
idleUntil   = activity == Training ? trainBookedAt : now
idleDays    = floor((idleUntil - lastTrainAt) / 86400)
hungerStart = fedUntil != 0 ? fedUntil : bornAt + 259200
hungerDays  = now > hungerStart ? 1 + floor((now - hungerStart - 1) / 86400) : 0
damage      = 5 * (idleDays - idleDaysApplied) + 5 * (hungerDays - hungerDaysApplied)
B           = max(0, B - damage)
```

This charges each completed inactivity day and each begun hungry day once. Newborns are immediately Hungry for actions but receive a 72-hour grace period for hunger damage. Transfers, views and repeated touches cannot reset fractional-day accounting.

**The inactivity clock pauses while a pet is in Training.** A booked pet is waiting on the Core frontier, which it cannot influence, so no day of that wait counts as idle (`idleUntil` stops at the booking time). The hunger clock does not pause: the owner can and should keep feeding through the wait. Leaving Training:

```text
positive-work settle:     lastTrainAt = now; idleDaysApplied = 0        (reset, as in v2)
zero-work settle, cancel: lastTrainAt += now - trainBookedAt            (resume: the locked span is excised,
                                                                         the partial day in progress at booking
                                                                         carries over, nothing is reset)
```

So a pet booked 20 hours into a day and settled with zero work four days later still completes that idle day four hours after unlocking, while the four locked days cost nothing. Booking cannot be used to *reset* the clock without certified work; it can only stop it, and only while the pet is genuinely unavailable for every other action.

After prior neglect, low feed subtracts 4 (floor zero), mid adds 6 (ceiling 100), high adds 12 (ceiling 100). For **positive certified work**, training uses the v2 rule:

```text
cap = capturedTier == 0 ? 60 : 100
credit = 2 + 2 * capturedTier + min(gain, 10)
if B < cap: B = min(cap, B + credit)
lastTrainAt = now
idleDaysApplied = 0
```

A score already above the cheap-food cap is not immediately reduced by training. Cheap feeds and neglect still lower it over time. Only mid/high training can build Fit weight. Zero-work settlement projects hunger neglect and unlocks but grants **no body credit and no inactivity reset**, preventing health farming from certified inactivity; the paused clock simply resumes. Cancellation has the same no-credit, resume-only rule. Feeding often is allowed; there is no cooldown.

Worked example at the review-time Sepolia lag (about 7 days) with the pinned 1012-work window on high food, fed every 72 hours: body 62 at booking, two feeds during the wait (+12 each) reach 86 with no idle or hunger damage, and settlement adds 16 to reach the 100 cap: Fit. Before this revision the same sequence was charged 35 idle points plus 20 hunger points the owner could not prevent, and ended Obese.

## MatchQueue (preserved from v2, geometric bands)

Bands pair pets by stamina ratio, because one certified window moves stamina by thousands (see the live-ledger scale above) and v2's 25-point grid would put two pets whose windows differed by a few percent tens of bands apart:

```text
BAND_WIDTH = 500
band(s) = 0                         for s < 500
band(s) = floor(log2(s / 500)) + 1  for s >= 500,  i.e. band k >= 1 is [500 * 2^(k-1), 500 * 2^k)
```

| Stamina | 0–499 | 500–999 | 1000–1999 | 2000–3999 | 4000–7999 | 8000–15999 | 16000–31999 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Band | 0 | 1 | 2 | 3 | 4 | 5 | 6 |

Any two pets in one band above band 0 are within a factor of two of each other, so the weight multiplier (±15%) and noise (±10%) still decide close races while a pet cannot meet one many times its size. Band 0 holds untrained and match-only pets (start 10, +3/+1 per race, five races a week), which is where v2's whole grid lived. Two pets trained on live-sized windows of 2213 and 2000 work at high food (8862 and 8010 stamina) share band 5 and can race; the pinned 1012-work window yields bands 3 / 3 / 4 across the three food tiers. `bandForStamina(uint256)` is a public pure view of the rule. `log2` is OpenZeppelin's internal `Math.log2`, inlined; the maximum `uint256` stamina maps to band 248.

At most 32 waiting pets per band and one active token per address across bands. Enqueue requires owner, Idle, fed, and a remaining weekly attempt. It spends no attempt yet. Owners can leave before lock; anyone can evict a Hungry entry or an entry with `now > joinedAt+86400`. Exact TTL equality is live. Removal uses swap-and-pop with repaired indexes and preserves each entry's own joined block.

An entry becomes eligible at `block.number >= joinedBlock+10`. `requestRound(band)` prunes expired entries and locks **every** eligible live pet, requiring 2–32. It cannot choose a subset, seed or opponent. If fewer than two remain, pruning rolls back with the call; individual eviction still works. Each pet becomes Matched, spends one attempt, and snapshots its owner, stamina and projected weight. Odd counts are included. A later round may form in the same band independently.

The request fixes `entropyBlock=requestBlock+2`. Permissionless fulfillment requires:

```text
entropyBlock < block.number <= entropyBlock + 256
entropy = blockhash(entropyBlock) != 0
seed = keccak256(abi.encode(entropy, chainId, address(queue), roundId))
```

There is no alternative entropy if the hash is absent or expires. Fisher–Yates shuffles the fixed roster with swap index `uint256(keccak256(abi.encode(seed,"PAIR",i))) % (i+1)`, descending from last index to one. Adjacent shuffled entries form races. An odd last entry is the entropy-chosen bye: it unlocks, earns nothing, and gets its consumed attempt refunded.

For pair index `p` and token `id`:

```text
noise = uint256(keccak256(abi.encode(seed,"NOISE",p,id))) % 2001
weightBps = Fit ? 11500 : Normal ? 10000 : 8500
score = floor(snapshotStamina * (weightBps - 1000 + noise) / 20000)
```

Higher score wins. A tie chooses A iff `uint256(keccak256(abi.encode(seed,"TIE",p))) % 2 == 0`. Weight/noise give a multiplier in 7500–12500; the final score fits even at maximum `uint256` stamina. Hash-modulo bias is negligible, not mathematically absent. Proposers can bias/censor block hashes, and keepers can decline fulfillment. This preserves the requested non-financial testnet game and is not a VRF or secure wagering protocol.

Anyone may settle each fulfilled match once, with no expiry. Winner gains 3 stamina and 10 points, loser 1 and 2. Effects precede reward calls; failure of either reward rolls back both pets, points and settled status. No ETH, ERC-20 or NFT is sent to a user during settlement. Later hunger, care/config changes or a noncooperating player cannot change a persisted outcome.

If still Pending at `block.number > entropyBlock+256`, anyone can expire the round and unlock everyone without reward or quota refund. Fulfilled rounds cannot expire. Weeks are `floor(timestamp/604800)` (Unix-epoch Thursday boundaries). Five attempts per NFT are consumed at lock, persist through transfer, and reset in a new week; only a fulfilled bye refunds an attempt. Address points are non-transferable totals and `weeklyPoints[lockWeek][ownerAtLock]`, with no redemption or promised prize. There is no per-pair cooldown.

## Operations and client semantics

`trainingStatus` returns `(active,start,end,frontier,ready,waitingForCertification,corePaused,work,gain)`. The public struct's ABI names are `trainStartRound` and `trainEndRound`. For an inactive booking, fields are zero and `active=false`; it makes no Core call. For an active but incomplete window, `work/gain` are unknown even though the fields encode zero. Only `ready=true` makes them meaningful. A certified zero-work window has `ready=true,work=0,gain=0`. `previewTrainingGain(id)` requires active training and full certification; it never estimates future work. A Core revert or malformed response propagates or fails validation, never silently becomes zero.

Keepers pay gas and monitor Core certification separately from queue blockhash deadlines. No paid keeper or uptime guarantee exists. Observed on Sepolia at review time (block timestamp 1793618844): `settledThroughRound = 1973` against a derived current round of 2952, a lag of about 980 rounds or 6.8 days, unchanged since the pinned snapshot block 12047523. A pet books one six-round window and stays locked (no transfer or queue entry; feeding stays open) until the Reporter certifies through its end round, so effective throughput is one window per lag period and `cancelTraining` is the only early exit. Core is an upgradeable proxy behind an immutable binding: a `roundDuration` change makes `currentRound()` revert `UnsupportedCoreConfiguration` and stops new bookings for good, and an ABI change would stop settlement; existing bookings could still be cancelled. The owner can close free mint, owner-mint within the cap, change food configuration within its bounds, withdraw feed revenue, bind the queue once, and transfer ownership with acceptance. There is no arbitrary work, stamina or points setter, Core replacement, upgrade, pause that traps users, or ownership renunciation. Upstream Reporter/governance availability and accuracy remain external trust assumptions. New deployments require the separate independent release review.
