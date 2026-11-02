# HamsterRun v3 · HAM Pocket

A bright Game Boy green public game site for the deployed **v3 Sepolia** contracts. The playable interface is in `web/`; the complete static export is in [`dist/`](dist/index.html). The existing Solidity, Foundry configuration, dependencies and application ABIs are unchanged.

The site supports wallet discovery, free minting, owned hamster IDs, care, certified-wheel training, geometric-band matchmaking and invite links. It reads live mint and queue status on every load. It never reports success from a wallet prompt alone: actions are simulated, sent through the visitor’s wallet, and confirmed by a transaction receipt.

## Install, build and preview

Use Node **22.13+** and npm. From the repository root:

```sh
npm --prefix web ci
npm --prefix web run typecheck
npm --prefix web run test
npm --prefix web run build
npm --prefix web run preview
```

Open the preview URL printed by Vite. The build exports `dist/index.html`, relative JS/CSS/font/image assets, two v3 ABIs and `dist/imd-deployment.json`. Once npm packages are installed, the build needs no network, credentials, Foundry artifacts, `.imd/reads/` files or serverless service. Live play does need Sepolia RPC access and a wallet.

Vite uses `base: './'`. Hash navigation (`#care`, `#queue`, `#invite`, `#guide`) and invite query strings work under a static gateway subpath; no route rewrites are needed. Serve the whole `dist/` directory over HTTP(S), preserving its directory structure. The IdentityMD hosting plane publishes the committed export after review; this task does not publish, change contracts or produce a public URL itself.

## Verified v3 integration

| Contract | Sepolia address |
| --- | --- |
| HamsterRunNFT | `0x2bb4f70787f00c70b18355495edbddeb25bb5dea` |
| MatchQueue | `0xaa57478bb5bcf5060a4973066aa5523620932922` |
| SqueekCore, read-only upstream | `0x74665dAecA35A2303e767E76a2FF1FB6F93e119f` |

Chain ID: **11155111**. Source commit: `fa23fe18551c431ada88350bd9d4d0a7dba04912` in [the v3 launch repository](https://github.com/identity-md-launches/launch-2874-hamsterrun/tree/fa23fe18551c431ada88350bd9d4d0a7dba04912).

[`web/deployment.json`](web/deployment.json) is the committed, verified website handoff. Its network block was copied byte for byte from the pinned network input. It includes the public RPCs, deployment blocks, ABI hashes, immutable-adjusted runtime hashes, chain switch parameters and an empty optional invite-service URL. It is the source for the generated runtime handoff; the older pending `deployments/sepolia.json` is not read by the website.

[`web/scripts/prepare.mjs`](web/scripts/prepare.mjs) checks the canonical Keccak ABI hashes and copies the exact root `abi/` exports to the public build. At runtime the site loads its addresses, chain and ABIs from those files, checks both deployed application runtimes, verifies the queue’s NFT and the NFT’s Core bindings, and requires upstream code before enabling any transaction. No v1/v2 address or ABI is loaded by the site.

Recheck the deployed code and live state with:

```sh
npm --prefix web run verify:release
```

This command is read-only and uses the handoff’s public Sepolia endpoints. The recorded live observations, ABI provenance and check results are in [`docs/SITE-VALIDATION.md`](docs/SITE-VALIDATION.md). Flags are observations, never build-time defaults: the page rereads them and refreshes while open.

## Play

- **Connect:** the header is the single connection entry. EIP-6963 lists extensions by name, including MetaMask and Rabby. A wrong-chain wallet gets Switch to Sepolia, with the pinned add-chain fallback. The mobile sheet offers wallet-browser links and Coinbase Smart Wallet. No relay or project ID is required. Connection is never requested on first paint; a previously authorized connection can restore on reload.
- **Mint:** one free mint per wallet for life, maximum supply 9,999, 10 starting stamina. Supply and owned IDs are live. Received NFTs do not consume an unused wallet mint. A closed mint is visibly disabled. Gas still applies.
- **Care:** body, weight, fed-until time, stamina and the five-attempt weekly quota are read from v3. Food prices and multipliers are live, with a review dialog before sending exactly the selected price. Hunger blocks new training and queue entry, never burns a hamster, and does not prevent certified settlement.
- **Train:** book six consecutive Core rounds `[R, R+5]`. Read `trainingStatus`, show the frontier and booked end, and settle only once ready. Unknown work is never displayed as a known zero. Gain is `floor(2 * W * capturedBps / 10000)`. Feeding stays available while Training, including during certification lag; it changes the next booking’s food, not the active snapshot. Cancel requires a forfeiture confirmation.
- **Queue:** read `bandOf`, wait ten blocks per entrant, then request a round with at least two eligible runners. The contract locks the roster; no opponent ID can be selected. Fulfill strictly after the entropy block and no later than `entropyBlock + 256`, then settle each persisted match. Expired pending rounds can be unlocked with Expire round. Attempts are spent at round lock; a fulfilled bye refunds one. Five attempts reset on Thursday at 00:00 UTC.
- **Invite:** create `?ref=handle` links without an X login. The first valid referral persists in browser storage. Handles are unverified. Shared rankings say **offline** when no invite service is configured; no players or counts are invented.

The UI help gives the owner setup order explicitly: verify and call `HamsterRunNFT.setMatchQueue(v3Queue)` once, then `setMintOpen(true)`. These are not public-site transactions. Binding and mint state may already be configured; read the live banner rather than resending setup. Default food settings need no setup.

HAM is the website’s Pocket branding; the existing NFT’s on-chain symbol is **HMR**. There is no ERC-20 deployment, SQK issuance or yield, official SqueekMining relationship, insurance, or guaranteed airdrop. Race points and invite counts have no promised redemption.

## Source map

| Path | Responsibility |
| --- | --- |
| `web/src/runtime.ts`, `data.ts` | Runtime handoff, verified code/bindings, block-consistent contract reads, owned-ID scanning |
| `web/src/Wallet.tsx`, `Dialog.tsx` | Wallet discovery, mobile links, chain switching, native accessible dialogs |
| `web/src/Care.tsx`, `Queue.tsx` | Mint, RPG care HUD, feeding/training, queue/round/match actions |
| `web/src/transactions.ts` | Simulation, wallet requests, receipt-based success, rejection/revert handling and pending-hash recovery |
| `web/src/Invite.tsx`, `invites.ts` | Handle validation, share links, local attribution, bounded optional-service requests |
| `web/serverless/` | Optional D1-backed invite service and setup notes; not claimed to be deployed |
| `web/src/styles.css`, `Art.tsx`, `web/public/` | Final palette, local fonts, original pixel art, favicon, social card and wallet marks |
| `DESIGN.md` | Implemented website design system and responsive behavior |
| `docs/CONTRACT-DESIGN-v3.md` | Verbatim preserved v3 contract formulas from the pinned source |

The root Solidity project remains available for its existing development workflow. Its independent historical validation is in `docs/VALIDATION.md`; this website’s validation is separate. The application ABIs were independently regenerated from the pinned compiler output and checked, without changing those root exports.

## Interaction validation

The production build and typecheck pass. Seven Node tests cover exact band/body/hunger/fulfillment boundaries, certified gain rounding, invite validation and the optional service’s atomic first-attribution behavior. Nine Chromium test groups exercise the built export at a gateway subpath, including the full intercepted player lifecycle, failures, account/chain changes and responsive states. No test broadcasts a transaction.

To rerun the browser checks with an existing Playwright installation:

```sh
IMD_PLAYWRIGHT=/path/to/playwright/index.mjs \
PLAYWRIGHT_BROWSERS_PATH=/path/to/installed-browsers \
node web/test/browser.mjs
```

The script serves the export only for its own lifetime, intercepts wallet/RPC writes, checks 320/390/768/1440 layouts, and writes temporary screenshots and results under `test/scratch/interaction/`. These temporary files are not delivery assets. Real wallet signing, passkey onboarding and native mobile-app handoffs were not exercised. WebKit was unavailable; no Safari pass is claimed.

The pinned taste probe passes **15 of 16** checks. The remaining `chrome` measurement is a deliberate brief-driven exception: the requested plastic shell, LCD inset and raised A/B-style buttons use nested bezels and border-plus-pixel-shadow depth. The first mobile screen contains the product and Connect; no measured overflow, overlap, clipping, contrast or target-size failure remains. See the six-domain review and limitations in [`docs/SITE-VALIDATION.md`](docs/SITE-VALIDATION.md).

## Optional invite-service handoff and limits

The export is usable without the invite service. [`web/serverless/README.md`](web/serverless/README.md) explains deploying the small service separately, applying its D1 schema, setting its allowed site origin, and updating `inviteServiceUrl` before rebuilding. The browser submits anonymous IDs and handles only; it sends no wallet address to that service. This service is not Sybil-resistant and does not verify X ownership.

Owned IDs are confirmed from incoming v3 Transfer logs, scanned in bounded 10,000-block pages (up to 200 pages), then checked with `ownerOf`. An incomplete scan is shown honestly and the manual Inspect hamster ID form remains available. The queue displays the latest 12 rounds plus an optional older round ID; use the queue explorer to find an older round’s event ID if needed. Pending transaction hashes restore on reload; a confirmation timeout tells the player to check the explorer before resending. Core upgrades, delays, RPC outages and blockhash deadlines remain external constraints.

## Bundle and asset budget

The added ignore rules have an explicit path budget: **only `/web/node_modules/` and `/web/.vite/`** are excluded as frontend dependencies/cache. The pre-existing Foundry/scratch exclusions are preserved. `dist/`, the source, `web/package.json`, `web/package-lock.json`, runtime ABIs/configuration, local fonts and images remain deliverable. No npm registry mirror, archive, generated dependency tree or submodule is included. The complete added-file bundle is below the 8 MiB cap; the static export is about 1 MB.

Fonts retain their SIL OFL notices under `web/public/fonts/`. Wallet marks retain the RainbowKit MIT license under `web/public/wallets/`. Better Interface design guidance (Jakub Krehel, MIT) and the adapted Impeccable documentation method (Paul Bakaus, Apache-2.0) retain their notices in `web/DESIGN-GUIDANCE-LICENSE`.
