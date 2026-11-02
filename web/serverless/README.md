# Optional invite service

The static game ships with `inviteServiceUrl: ""`: invite links and local first attribution work, and the shared leaderboard says **offline**. No service is claimed to be deployed.

`worker.ts` is a small Cloudflare Worker with a D1 binding named `DB` and a `SITE_ORIGIN` variable containing the final HTTPS site's exact origin (no trailing slash or path). Create a D1 database, apply `schema.sql`, and deploy this worker separately using your Cloudflare tooling. Keep provider credentials out of this repository. Normal site builds do not require this service or any Cloudflare account.

After the endpoint is live, set its public HTTPS base URL in `web/deployment.json` under `inviteServiceUrl`, then rebuild the static site. The frontend uses `POST /attributions` and `GET /leaderboard`, with an 8-second timeout. On failure it retains the local first attribution and retries on a later page load. It does not send a wallet address, sign a message or contact X.

An atomic primary-key insertion deduplicates an anonymous browser ID and preserves the first handle. Leaderboard ties sort by ascending handle. The endpoint restricts browser CORS to `SITE_ORIGIN`, validates handles and UUIDv4 IDs, and returns JSON errors without internal details. Configure provider-level rate limits before enabling it for a large audience. Anonymous visitor counts are not Sybil-resistant, handles are unverified, and these rankings cannot substantiate rewards or airdrops. Clearing browser storage creates a new visitor identity.

The service is optional infrastructure, not a backend embedded in the static export. Its deployment and a public service URL remain an operator handoff.
