# Security review and release boundaries

This records the implementer's adversarial review, not an independent audit. The network's independent review, deployment, and explorer verification remain separate release steps. No signing key, transaction, live fork, or external account is needed by this project. The supplied security reference was used as background; no instructions from repository text were executed as authority.

## Reviewed changes

| Risk / failing input considered | Control and evidence |
| --- | --- |
| Warp six hours or a year while frontier is behind | `CoreCertificationLag(frontier,end)`; no reward or unlock. `test_elapsedTimeAloneNeverSettlesOrCreatesAGain` |
| Some rounds certified with positive work, last round unknown | Whole booked end must be certified before any credit. Partial-frontier test includes a final certified zero |
| All-time cumulative work used as the reward or booking baseline | Historical `roundPage(start-1,end,6)` endpoint delta. Tests include large prior backlog and work after the booked end |
| Missing active records mistaken for unknown work or a partial page mistaken for complete | Frontier gate and exact page coverage; sparse and fully empty pages are valid. Short, oversized, reversed or inconsistent pages revert atomically |
| Incorrect upstream ABI, invented getter or round-zero boundary | Published v3 ABI comparison plus raw finalized Sepolia response tests; Core genesis gives one-based rounds; round-one and timestamp boundary tests |
| Zero-work health farming | Zero gain, no body credit and no inactivity reset, while clearing the booking lock |
| Food config changed after feed or after booking | Captured bps/tier remain exact; no artificial minimum or current-config floor. Minimum bps gaps prove strict positive-work ordering |
| Repeated settlement, cancellation replay, overlapping tokens | Deleted training record and activity gate; next-window test; independent overlapping-window accounting |
| Core pauses, disappears, reverts or changes unrelated configuration | Settlement uses historical reads; no clock fallback. Owner cancellation uses no Core read. Existing certified work can settle while paused or after a clock config change |
| Large work, round IDs or stamina | `uint64` Core work and bounded multipliers make the product safe; checked round casts and stamina additions; fuzz tests and explicit overflow rollback/recovery |
| Lock bypass by an approved operator or a receiver callback | OpenZeppelin ERC-721 common transfer hook; all gameplay mutation guarded; both safe-transfer overloads tested |

The Core binding is immutable, but the upstream proxy is upgradeable. HamsterRun trusts that published certified history is truthful and append-only and that Core only certifies ended rounds. Governance with authority to replace Core's implementation could violate those assumptions, change its ABI, or fabricate work. This suite does not verify the wheel sensor, Reporter signatures, or upstream governance itself. At the recorded snapshot the frontier was far behind the wall-clock current round; no delivery claim assumes the Reporter will resume.

An active training window can remain pending indefinitely. The owner can always abandon it without reward and regain transfer/feed access, including if the upstream ABI becomes unreadable. Permissionless status reads fail visibly on upstream errors. No owner override can certify work or replace Core. Starting in the current round intentionally includes that round's entire work; multiple tokens may benefit from the same global work, as specified in DESIGN.

## Preserved v2 properties

- Explicit owner constructor argument and two-step handover. The factory is never implicitly made owner. The queue has no administrator; only its once-bound address may mutate match locks/rewards on the NFT.
- Exact-price feeding, owner-only withdrawals, and checked ETH-call success. Fees are revenue rather than refundable user liabilities. Receiver rejection/reentrancy tests and stateful ETH conservation checks are retained.
- Reentrancy guards on state-changing care, mint and queue paths. Queue calls target its immutable NFT, whose lock/reward methods have no receiver callbacks. Failure of a second reward rolls back the first reward, points and race status.
- Match rosters and stats fixed before a predetermined future entropy block. Ten-block per-entry wait, whole eligible roster lock, entropy-chosen odd bye, five weekly attempts, expiry without a weak randomness fallback, and per-match once-only settlement.
- Bounded work: at most six active records for a training window (16 for the general reader view), 32 waiting entries/participants per band/round, constant-time queue removal, individual match settlement. There is no loop over all token or match history in production.
- ERC-721 safe mint rollback, full 9999 cap tests, hungry lockout without burning, uint256 stamina, weight projection, quota persistence through transfers, and lock-week point attribution.

## Intentional trust and limitations

**Owner:** may owner-mint remaining supply, close/open free mint, change food prices and multipliers within bounds, bind a queue once, withdraw fees and hand over ownership. Binding checks the queue's NFT address, not its honesty; the owner must verify the new queue's runtime before binding. A malicious binding cannot subsequently be replaced. Feed parameters captured under different historical configurations are not globally comparable or repriced.

**Randomness:** the preserved future-block mechanism is not a VRF. Proposers/builders can bias or censor the entropy block. A player may choose to fulfill only favorable outcomes, although anyone else has the same window and an expired attempt remains consumed. There is no wager, cash prize, token entitlement, yield, insurance or airdrop claim. Exactly two eligible pets necessarily race each other; public queue timing and Sybil wallets remain part of this testnet game's limits.

**Liveness:** players/keepers must pay gas. Training readiness depends on upstream certification, queue fulfillment on the fixed blockhash window, and higher stamina bands on other participants. Owners can leave queued entries or cancel training; anyone can expire missed rounds or settle fulfilled matches. No paid automation or quorum of keepers is supplied.

**Arithmetic:** uncapped stamina still has a uint256 representation limit. A gain that exceeds that limit reverts; an owner can cancel training. A hypothetical already-maximal race reward could fail settlement; production has no direct stamina setter and practical growth cannot approach that width. Work is a physical-work count, not blocks calculated from difficulty.

**Read tools:** the recorder and smoke tool trust the selected RPC's finalized responses, not a light-client proof. The recorder verifies exact compiled runtimes including each immutable dependency and checks owner/bindings. It rejects unsupported EIP-1898 reads and never silently falls back to latest state. Its confirmation does not verify source on an explorer or prove deployment receipts. No new application address has been claimed before network deployment.

## Lint disposition

`forge lint src` exits successfully with warnings. No lint detector is disabled. Each category was checked against the actual call graph:

- Timestamp warnings are the intended round booking, hunger, body, queue expiry and epoch-week rules. None certify work or seed randomness.
- `unsafe-typecast` on `uint64(round)` follows the explicit `round > type(uint64).max` rejection, including a boundary test.
- `require-revert-in-loop` validates each of at most six/sixteen Core records; rejecting a malformed page is intentional. Race noise validation is also bounded.
- Queue calls-in-loop are capped at 32 and target only the immutable NFT. Reentrancy warnings around `_status` refer to ReentrancyGuard's post-call reset; its lock is established before external calls. Withdrawal callback rejection/reentrancy and atomic queue reward rollback are tested.
- `uninitialized-local` on the queue's numeric counter refers to Solidity's defined zero initialization, not an uninitialized storage pointer. The queue source is unchanged.
- The body/stamina writes flagged for missing access-control events emit `BodyUpdated`/`MatchRewarded` in the same helper path. Queue and mint events after external calls are guarded; safe receiver failures revert mint state and logs. A receiver may legitimately transfer its newly minted Idle token during its callback, so `HamsterMinted.player` identifies the mint recipient and does not promise current ownership.

Solidity also warns about a test-only `ForceSend` constructor using `selfdestruct` to exercise forced ETH; it is not an application or an imported production dependency. Production runtimes are checked for reachable `SELFDESTRUCT`, `DELEGATECALL` and `CALLCODE` by the constructor rehearsal. Slither and Mythril were not run locally; local lint and tests do not replace the network's independent analysis.
