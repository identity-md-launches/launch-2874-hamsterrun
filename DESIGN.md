# HamsterRun · HAM Pocket design

## Overview

HamsterRun v3 is a public Sepolia pet game. The interface is a bright green LCD inside an off-white handheld shell: one continuous game surface, hard-edge original hamster art, short pixel headings, readable care controls and persistent live status. The site is a playable interface rather than a marketing landing page. Connect is visible immediately at 390 pixels, and navigation opens care, matchmaking, invitations or the game guide.

This document describes the final website source. The pinned contract design and all exact game formulas are preserved separately in [`docs/CONTRACT-DESIGN-v3.md`](docs/CONTRACT-DESIGN-v3.md). Website styling never changes the on-chain rules. Design knowledge was adapted from Jakub Krehel’s Better Interface (MIT) and Paul Bakaus’s Impeccable documentation method (Apache-2.0); their license notices are in `web/DESIGN-GUIDANCE-LICENSE`.

## Colors

Canonical tokens live in `web/src/styles.css` using the brief’s hexadecimal palette. There is one light theme; system dark preference does not change it.

| Token | Value | Implemented job |
| --- | --- | --- |
| `--lcd` | `#CADC9F` | Overall page wash, LCD inset, selected navigation surface, unfilled meter segments |
| `--shell` | `#F4F7E8` | Main plastic shell, form fields, dialog surface |
| `--bezel` | `#E8F0D0` | Soft inner bezel, status strip, neutral buttons, care and invitation panels |
| `--mid` | `#8BAC0F` | Status LED and care-meter fill; pixel landscape mid-tone |
| `--active` | `#9BBC0F` | Main action button, completed setup step, selection highlight |
| `--green` | `#306230` | Secondary text, inset borders, meter outlines and pixel depth |
| `--ink` | `#0F380F` | Primary text, main outlines and focus ring |
| `--warning` | `#C4A35A` | Thin certification/status warning edge and offline LED |
| `--error` | `#A84545` | Inline validation errors and transaction-failure outline |

Statuses include text and an icon/shape, not color alone. The green action surface is paired with ink text. The warning tone is used sparingly as an edge, not as a broad page fill. There are no navy surfaces, neon effects, gradients, dark terminal chrome or gradient text.

Computed WCAG contrast for the declared opaque token pairs is 12.13:1 (ink/shell), 8.95:1 (ink/LCD), 6.02:1 (ink/active), 6.63:1 (green/shell), 6.11:1 (green/bezel), and 5.36:1 (error/shell). The production probe also measures rendered solid backgrounds; image-adjacent text exclusions are documented in validation. These calculations do not claim a full accessibility certification.

## Typography

Two local WOFF2 families are bundled under `web/public/fonts/`:

- `Pixel` is the CSS alias for **Press Start 2P**, regular 400. It is used for the wordmark, headings, small physical-console labels and A/B keycaps. It is not used for long instructions.
- **DM Sans** is the variable reading/control face with `sans-serif` fallback. The interface uses weights 400, 500 and 600. Strong text is explicitly 600, avoiding a fourth browser-default weight.

The declared scale is `--s1: 12px`, `--s2: 14px`, `--s3: 16px`, `--s4: 20px`, `--s5: 24px`, `--s6: 32px`. The site currently uses 12/14/16 for most mobile text and 20/24 for the larger desktop brand/title. The 32-pixel step is reserved in the scale and used by the social artwork, not required for ordinary page text. Inputs remain 16 pixels at all widths to avoid iOS input zoom.

Body line height is 1.5. Pixel headings use 1.6–1.8 where their blocky forms need space. Regular control text uses 1.4 or inherited 1.5. Headings balance lines; prose wraps naturally with `text-wrap: pretty`. Letter spacing stays natural. Live values use tabular numbers. Addresses and long integers wrap with `overflow-wrap: anywhere`; they are selectable and are not silently clipped. Stamina values longer than 16 digits use a full-width HUD meter so the full uint256 value remains legible.

## Layout

The desktop `.site` is at most 1,240 pixels wide, with 24-pixel outer padding and a 36-pixel top margin. The `.handheld` supplies 26/30-pixel inner spacing. Header, four-column navigation, live status, main view and physical-console footer share the same leading edges.

Care uses a `1.7fr / 1fr` habitat/control grid; queue and invite views use a `1.5fr / 1fr` content/aside grid. Gaps are generally 24 pixels, reaching 30 on the large care view. Meters use two columns and 12–24-pixel gaps. Most component padding is 12, 16, 18, 20 or 24 pixels, with a 4-pixel underlying step.

Implemented breakpoints:

| Width | Adaptation |
| --- | --- |
| At least 1,000px | Larger care gap and a minimum 280px habitat image height |
| Up to 900px | Compact header/title and 20px two-column gaps; decorative nav numbers disappear |
| Up to 680px | Full-bleed portrait shell, 16px side padding, one-column care/queue/invite, icon-over-label navigation, bottom-aligned native dialogs |
| Up to 360px | 12px shell side padding and smaller brand/control label treatment |

Header controls remain in the document flow. Navigation is not sticky and never covers content. The decorative D-pad and speaker finish the shell; both are hidden from assistive technology. Long tables have a contained horizontal overflow region, while the page itself must not scroll horizontally. The guide uses native disclosures rather than a wall of instructions. All tested pages and open guide disclosures fit at 320, 390, 768 and 1440 pixels, including the maximum uint256 stamina value.

## Elevation & Depth

Depth intentionally follows the brief’s physical handheld direction. The shell has a 2-pixel structural green border and hard lower shadows. The LCD frame nests an inset with a stronger green outline; artwork uses crisp edges and nearest-neighbor scaling. Primary buttons use a 2-pixel outline with a four-pixel ink lower shadow, and secondary buttons use a three-pixel green lower shadow. Pressed controls scale to 0.96 only when reduced motion is not requested.

This shell/LCD/button construction deliberately triggers the taste probe’s generic border-plus-shadow and nested-card measurement. It is the requested Game Boy bezel, not an additional dashboard-card system. Other content groups use space, flat color and simple rules. Navigation selection has no extra shadow. There are no glows, blurs or animated entrances. The native dialog backdrop is translucent ink (`#0F380F66`); the dialog itself remains opaque shell plastic.

## Shapes

The desktop shell uses radii `24px 24px 72px 24px`; the full-bleed mobile shell uses `0 0 36px 0`. LCD framing uses `8px 8px 30px 8px`, while the inset itself stays square. Panels have a restrained 6px radius, action buttons 5px, fields 3px, and tiny status badges 2px. A/B keycaps are circular. Hard pixel geometry is reserved for sprites, icons, meter blocks and the D-pad.

`web/public/hamster.svg`, `habitat.svg` and `favicon.svg` are original SVG pixel art with crisp edges. `web/public/og.png` is a real 1,200 × 630 PNG from the matching `web/brand/og.html` composition, using those local assets and fonts. Wallet-brand SVGs retain vendor colors for recognition; they are confined to the wallet chooser.

## Components

| Component / source | Use and states |
| --- | --- |
| `App`, `web/src/App.tsx` | Shared shell, status and navigation. Hash changes focus the main view. Read errors pause actions and offer Retry reads. No verified “live” state is implied before data arrives. |
| `.button`, `web/src/styles.css` | Raised primary, secondary, quiet, small and wide variants. Rest/hover/pressed/focus/disabled states share the palette. Controls are at least 44px high; the main button minimum is 48px. Disabled actions retain nearby explanations. |
| `Wallet`, `web/src/Wallet.tsx` | Single first-screen entry, EIP-6963 names/icons, generic row only when no named extension exists, mobile wallet-browser links, Coinbase/passkey option, rejection note, address/disconnect state and Sepolia switch/add fallback. Never auto-opens. |
| `Dialog`, `web/src/Dialog.tsx` | Native modal dialog for wallet selection and action review. Native focus containment/inert background, Escape, backdrop click and explicit close. Focus restores to the trigger when usable, otherwise to main. |
| `Meter`, `web/src/Care.tsx` | RPG block indicators with exact text values. Stamina progress is within its band, not a gameplay cap. Body is 0–100, feed is up to 72 hours, weekly use is 0–5. Missing pets have empty indicators and unknown values. |
| `Care`, `web/src/Care.tsx` | Habitat/HUD, owned-ID selector, free mint, food tier choices and training status. Food selection is an `aria-pressed` group with live prices. Active training shows booked rounds, frontier, captured food and certified work only when known. |
| `Queue`, `web/src/Queue.tsx` | Band selector, waiting roster, entry/wait counts, player pass and actual rounds. Request/fulfill/settle/expire controls follow live contract state and block deadlines. There is no opponent picker. |
| `Invite`, `web/src/Invite.tsx` | Labeled X-handle form, inline validation, select/copyable share link, X share intent, separate race points and shared invite ranking state. Empty configuration explicitly displays offline. |
| `Guide`, `web/src/Guide.tsx` | Native disclosure rows for care, certified training, queue mechanics, owner setup, invitations and public contract/source/ABI links. |
| Transaction notice, `web/src/transactions.ts` / `App.tsx` | Stable pending/error/success feedback, receipt link and dismiss control. Simulation and wallet rejection never count as success. Pending hashes can recover after reload. |
| `Icon` / `Dpad`, `web/src/Art.tsx` | One monochrome pixel SVG language using `currentColor`; decorative icons have `aria-hidden`. D-pad is artwork, not a fake button. |

All fields have labels and validation is tied by `aria-describedby`. Transaction errors use alerts; routine progress uses status regions. Focus-visible outlines are 3px ink, offset 4px; forced-colors mode uses system Highlight. Motion is limited to 120ms background/press feedback inside `prefers-reduced-motion: no-preference`. There is no endless animation or autoplaying media.

## Do’s and Don’ts

- Start a new view inside the existing main/shell and reuse `.intro`, `.page-grid`, native disclosures and `.button` variants. Keep the product and connection entry visible before explanations.
- Use the pinned green tokens and local pixel art. Keep readable descriptions in DM Sans and pixel type for short labels/headings.
- Put exact live numbers beside meters. Treat loading, read failure, unconfigured services, certification lag and certified zero work as different states.
- Keep care available during Training, including during Core lag. Do not substitute a timer, estimated wheel work or a fabricated gain for `trainingStatus`.
- Preserve the one wallet entry and explicit transaction review. Do not add an owner transaction path, mainnet, relay credentials, reward guarantees or old-suite contracts.
- Extend the existing scale and spacing deliberately. Do not introduce navy chrome, a dark theme, Material-style card stacks, decorative tracking or another icon/font family.

The six-domain review, source findings, corrections, actual browser/probe results and unperformed checks are recorded in [`docs/SITE-VALIDATION.md`](docs/SITE-VALIDATION.md).
