# HamsterRun v3 website validation

Date: 2026-11-02 UTC. These are worker-run checks, not independent network certification.

## Scope and completion

**Complete for the assigned static-site implementation scope.** `dist/index.html` and its complete relative runtime assets exist with the React/TypeScript source, npm manifest/lockfile, design documentation and an optional invite-service implementation. Hosting and the public HTTPS name are supplied by the IdentityMD plane after review; no hosting command or chain transaction was run by this task.

The existing Solidity, root ABIs, Foundry configuration, vendored dependencies and deployment scripts remain unchanged. The original pinned contract `DESIGN.md` is preserved verbatim in `docs/CONTRACT-DESIGN-v3.md`; the root document now describes the final website.

The shared invite service has no supplied URL, so it is intentionally offline, as the brief permits. Local handle links and first attribution work. No global leaderboard is simulated or claimed to be live.

## Requirement coverage

| Brief requirement | Result and evidence |
| --- | --- |
| Light Game Boy green palette and plastic shell/LCD inset | Met: exact pinned colors in `web/src/styles.css`; actual 390/1440 screenshots inspected |
| Pixel type, hard edges and nearest-neighbor sprites | Met: local Press Start 2P plus original crisp SVG hamster/landscape; loaded fonts confirmed in Chromium |
| Chunky A/B-style actions and RPG HUD | Met: raised action buttons, block meters, exact stamina/body/fed/quota values, separate Core status |
| Mobile portrait and 44px tap targets | Met for measured default view: all 12 probe controls are at least 44px; action/field/dialog/guide/table targets have explicit minimums |
| Product and main action on first 390px screen | Met: HamsterRun, live state, habitat and Connect wallet visible in `390-live-first.png` and probe screenshot |
| Title, favicon, description, OG title/image | Met: `web/index.html`, matching `favicon.svg`, real 1200×630 `og.png`; probe share check passes |
| v3 only; exact Sepolia addresses, ABI provenance and runtime checks | Met: pinned source, canonical hashes, deployed-runtime comparison and live binding reads; no v1/v2 data in runtime handoff/assets |
| Live mintOpen / matchQueue, honest closed / unbound status | Met: public live reads plus closed/unbound browser fixture; no fabricated defaults |
| Owner setup in order, public player transactions only | Met: guide names setMatchQueue then setMintOpen; source review confirms only player/permissionless action handlers |
| EIP-1193 / EIP-6963 wallet discovery, Sepolia switch | Met in intercepted-provider tests: distinct MetaMask/Rabby rows, no duplicate generic row, switch and 4902 add-chain fallback |
| No wallet sheet on first paint | Met: fresh context has no dialog and no eth_requestAccounts call; connection starts on a chosen row |
| Mobile wallet browsers and Coinbase Smart Wallet | Implemented: all four “Open in” links, vendor marks, Coinbase SDK connector; mobile sheet rendered/tested; native app/passkey handoffs not exercised |
| Free mint, supply and owned IDs | Met: receipt-confirmed mint, live supply, Transfer/ownerOf discovery and ID inspection; unused mint remains available after an owned transfer |
| Care HUD and accurate body/hunger/quota rules | Met: on-chain views plus boundary tests; body classes at 35 and 70, hunger exact-expiry behavior, weekly five-attempt display |
| Feed while Idle or Training; prices/bps live | Met: exact 0.0002 and 0.0003 ETH test requests, Training feed remains enabled, Queued/Matched care disabled |
| Six Core rounds and captured multiplier | Met: booked `[R,R+5]`; test feeds high tier after booking mid tier and verifies gain uses the mid-tier snapshot |
| Frontier/end/ready, certification lag and no invented work | Met: waiting and Core-unavailable states, disabled Settle, unknown work text; ready zero-work fixture settles for zero |
| Permissionless settle and owner cancel | Met: account-change fixture disables care/cancel while allowing certified zero-work settlement; cancel leaves stamina unchanged |
| Geometric band display and 10-block queue wait | Met: bandOf reads and boundary tests through uint256 maximum; request disabled until two entries have waited |
| Enqueue / leave / request / fulfill / settle / expire | Implemented; full intercepted happy path covers enqueue→request→fulfill→settle; leave and expire handlers reviewed and fulfillment boundaries unit-tested |
| Five attempts per week; no manual opponent | Met: actual matchesThisWeek; only band/round/token-inspection inputs, no opponent input; attempt spent at lock in lifecycle fixture |
| Camping/two-player wait help | Met: help explains ten-block eligibility, stale/hungry eviction, 24-hour TTL and all-eligible roster lock |
| Invite link, local attribution and small service | Met: validated X handles, preserved gateway subpath, first-attribution persistence, D1 worker/schema and service tests |
| Honest offline rankings | Met: empty service URL immediately shows offline; no infinite loading, sample rankings or invented player counts |
| No SQK yield, insurance, airdrop or official mining claim | Met: source/copy review; guide explicitly distinguishes testnet game, race points, branding and NFT symbol |
| Static export + source + lockfile; relative URLs | Met: production build and `/pocket/` browser-serving checks; runtime asset paths local and complete |
| README, implemented DESIGN, six-domain review | Met: root documents and consolidated review below |
| Public HTTPS URL | After review: assigned hosting-plane handoff, not a worker-side publication |

## Provenance and live observations

The initial checkout was exactly `fa23fe18551c431ada88350bd9d4d0a7dba04912`. Both application ABI files were compared byte for byte with that GitHub commit and independently regenerated by `forge build --offline` / `node tools/export-abis.mjs --check` without edits to source/configuration. The compiler build passed; its existing Solidity/test-helper lint warnings were not frontend findings.

Canonical recursively key-sorted JSON Keccak hashes match the pinned handoff:

| ABI | Canonical hash, without 0x |
| --- | --- |
| HamsterRunNFT | `0c06698c3ece134d042a8b2a7894e23637c93538c0642fc7300a0fe38d1f3f95` |
| MatchQueue | `c95c9bff6531b025ea10d93b7f51e734ce09f2c73722cca95d6177e458989857` |

Both compiled runtimes were patched only at their declared immutable locations with the provided Core/NFT dependencies, hashed, and compared to the deployed code. The browser repeats the runtime comparison, ABI hash check and reciprocal/upstream binding checks before transactions. The handoff’s entire `network` JSON block was checked byte-identical to the pinned input. No poolKey was supplied for this contracts-only game.

A read-only live check through the handoff’s public Sepolia endpoint, `https://ethereum-sepolia-rpc.publicnode.com`, returned at block **12048601**, timestamp **1793628000**:

| Read | Observed value |
| --- | --- |
| chainId | 11155111 |
| both application runtimes | Match the compiled pinned v3 source |
| mintOpen | true |
| NFT matchQueue | `0xaa57478bb5bcf5060a4973066aa5523620932922` |
| totalSupply | 0 |
| settledThroughRound | 1973 |
| currentRound, NFT CoreReader wrapper | 2968 |

Thus owner wiring had changed from the brief-time closed/unbound observation. These are dated observations, not encoded initial UI values or a promise about later loads. Core was substantially behind the clock; the UI treats the wait as normal and never converts that lag into future work. Nothing was signed or broadcast in the live check.

## Commands and actual results

| Command / check | Result |
| --- | --- |
| `forge build --offline` | Passed, 62 Solidity files compiled with 0.8.26 for ABI/runtime provenance only |
| `node tools/export-abis.mjs --check` | Passed; both app ABIs and Core read interface match their pinned exports |
| `npm --prefix web run build` | Passed after final application changes; prepare + `tsc --noEmit` + Vite production export |
| `npm --prefix web run typecheck` | Passed, including the serverless types imported by tests |
| `npm --prefix web run test` | 7 tests passed: bands, gain rounding, body/hunger/care/readiness gates, fulfillment boundaries, invites, service dedup/order, service rejection paths |
| `npm --prefix web run verify:release` | Passed against live Sepolia; values above |
| `IMD_PLAYWRIGHT=/opt/imd-tools/playwright-mcp/node_modules/playwright/index.mjs PLAYWRIGHT_BROWSERS_PATH=/opt/imd-tools/ms-playwright node web/test/browser.mjs` | 9 Chromium groups passed, no application page errors; all writes intercepted, none broadcast |
| Same provided module/browser paths with `node .imd/reads/skills/design-critic/scripts/taste.mjs --out test/scratch/taste` | 15/16 passed; one deliberate brief-driven chrome exception below |
| Supplemental live Chromium inspection | Real export at 390px; local font loading, resolved color pairs and a visible keyboard outline observed |
| Structural/budget check | Network block exact; PNG 1200×630; no protected source/config changes; no added dependency/cache/archive/symlink/submodule paths in the submission list; added bytes below 8 MiB |

The nine browser groups cover closed/unbound/no-auto-connect/keyboard behavior; mobile connectors and first referral; full player lifecycle; Core read failure and cancel; wallet rejection/reverted receipts; code mismatch; account/chain changes plus stale-pet-read retry and permissionless zero work; unused mint after a transfer; all routes at 320/390/768/1440 with longest stamina and reduced motion.

The full lifecycle was **mocked against the exact v3 ABI**, not carried out by a real wallet: mint → feed tier 1 → book → observe lag with Feed enabled → feed tier 2 without changing the booking snapshot → certify → settle for 3,036 gain → band 3 → enqueue → ten-block wait → request → future entropy block → fulfill → settle match. All contract selectors, arguments, exact feed values and resulting gating were exercised through the built app’s EIP-1193 path. No elapsed real-time certification was awaited.

Screenshots/results were inspected locally under `test/scratch/taste/`, `test/scratch/interaction/` and `test/scratch/visual/`. These are temporary review evidence and are removed before submission, not hidden application dependencies. The durable outputs are the actual static export, source, tests and this report at `docs/SITE-VALIDATION.md`. The identical `artifacts/validation.md` copy is an auxiliary artifact; the documentation does not depend on ignored artifacts being committed. The built social image was also viewed.

## Better Interface review: six domains

| Domain | Coverage | Observations and limits |
| --- | --- | --- |
| Accessibility | Checked, with limits | Native buttons/forms/dialog/disclosures, labels and errors, skip link, focus containment/return, Escape, mobile rows, reduced motion and wrong-chain disabled state. Keyboard focus visibly inspected on Browser wallet: 3px solid ink outline, 4px offset. No native screen-reader, physical-device or complete forced-colors session. |
| Layout | Checked | Production export and all four routes inspected at 320/390/768/1440; open guide details and maximum uint256 text tested. Probe found no horizontal scroll, text overlap, floating-text obstruction or clipping. Native browser 200% zoom and RTL were not verified. A root-font-size enlargement spot check is not claimed as native zoom. |
| Writing | Checked | Consistent Feed/Start/Settle/Cancel/Enqueue language; price/gas and forfeiture review next to actions; explicit unknown, waiting, closed, unbound, unavailable and offline states; no prohibited reward claims. Reduced the repeated two-beat copy to one such line. |
| Typography | Checked | Loaded local Pixel/DM Sans confirmed. Six declared scale steps, three used sizes on the default mobile view, at most three weights. Exact long values wrap; maximum stamina uses a full-width metric rather than many narrow fragments. |
| Colors | Checked, with limits | Probe solid-text contrast passes. Supplemental browser computed pairs confirm ink/shell 12.13:1, ink/active 6.02:1, ink/bezel 11.18:1, ink/LCD 8.95:1 and green/bezel 6.11:1. The generic probe excluded four image-adjacent boxes; badge/hint backgrounds were separately confirmed opaque. Not a full accessibility certification. |
| UI details | Checked, with limits | Raised controls, selected food/nav, loading/disabled/error/success, native dialog and status notices. No endless animation or transition-all. Requested nested shell/LCD depth intentionally retained. Native wallet apps/passkeys and a slowed external-wallet animation session were not exercised. |

## Findings, fixes and dispositions

| ID | Severity / source | Before → change → recheck |
| --- | --- | --- |
| BI-01 | Medium, `web/src/styles.css:14` | Default strong text introduced weight 700 alongside 400/500/600 → explicitly use 600 → final probe reports exactly three weights. |
| BI-02 | Low, `web/src/Care.tsx` onboarding and meter copy | Four short two-beat fragments and an em dash in a combined missing-value label → plain action-adjacent prose and en-dash placeholders → slogans and glyph checks pass. |
| BI-03 | Medium, `web/src/Dialog.tsx:8` | A confirmation trigger can be disabled/replaced by the resulting game state → restore usable trigger, otherwise main, without scrolling → keyboard containment/Escape/return tests pass; pending state remains usable. |
| BI-04 | Medium, `web/src/Care.tsx:10` | Maximum stamina wrapped into many tiny fragments in a half-width HUD cell → full-width metric for more than 16 digits → all-route longest-value checks pass at all four widths. |
| BI-05 | Medium, `web/src/Care.tsx:64` | A player owning a transferred NFT could lose the visible path to an unused free mint → collection supply and Use free mint remain reachable with an active pet → explicit transfer/free-mint browser fixture passes. |
| BI-06 | Medium, `web/src/Care.tsx:106`, `web/src/Queue.tsx:21` | Preserved stale pet data could leave a control enabled during a failed/refetching read → gate pet actions on healthy, finished reads → failed pet refresh disables Settle and a successful retry restores it. |
| BI-07 | Low, `web/src/styles.css:16` | Guide/table inline links did not all have an explicit comfortable target → add 44px minimums to those link regions → narrow/open-guide overflow and route checks pass. |
| BI-08 | Brief-driven exception, `web/src/styles.css:4` shell/button/LCD rules | Probe flags two border-plus-shadow surfaces and one nested surface → retained because the brief requires a “light plastic Game Boy / Pocket bezel”, an “LCD inset”, and “Chunky A / B / D-pad style primary buttons” → inspected as the intended physical-console composition, not an unresolved usability failure. |

There is no remaining measured first-screen overlap, clipped text, missing local asset, small default-view target or solid-text contrast failure. The chrome exception is reported honestly rather than labeled a sixteenth passing probe check.

## Remaining limitations and handoffs

- The connected lifecycle used a named intercepted EIP-6963 provider. Real MetaMask/Rabby extension signing, Coinbase passkeys, installed phone apps and transaction broadcast were not tested. The browser MCP transport returned `Transport closed`; supplied Playwright/Chromium provided actual rendering and interaction coverage instead.
- WebKit was not available in the supplied browser installation. Safari and physical iOS/Android behavior are unverified. No native screen-reader, full native 200% zoom, RTL or exhaustive forced-color audit is claimed.
- Core availability/certification is external. The site cannot certify work, accelerate backlog, promise a completion time or run a paid keeper. Existing bookings preserve their food snapshot and cancellation remains the owner’s early exit.
- No invite-service endpoint was supplied or deployed. The included D1 service is tested locally with in-memory SQLite; its real provider deployment, rate limits, allowed origin and public URL remain optional operator work. Anonymous invite counts are not Sybil-resistant or X-verified.
- Owned-ID discovery is bounded to 200 incoming-log pages of 10,000 blocks, then verified with ownerOf. Errors expose a retry and manual inspection. Queue history is the latest 12 rounds plus an explicitly loaded archived ID. Those limits are described in README.
- Live reads verified the primary declared public endpoint. Independent sustained failover behavior of every public provider was not measured. RPC/code/ABI failures disable transactions rather than supplying default game state.
- A pending receipt has a bounded wait, persists its hash and directs the player to the explorer before resubmitting. Source review covers leave/expire paths, while their boundary rules are tested; no real chain-expiry transaction was sent.
- Hosting and the final HTTPS URL follow the normal network review/publishing step. `dist/` is the concrete delivery; no public URL is invented here.
