# Yap authentication service for Zoom

This Cloudflare Worker implements the **revised managed authorization flow for an upcoming review build**: production-client OAuth at a fixed HTTPS callback, an encrypted return to the native app, token refresh, and short-lived Meeting SDK signatures. The confidential production OAuth/SDK secret remains on the server. The service receives authorization codes, PKCE verifiers and OAuth tokens; meeting media, chat attachments, recording files and Google Calendar data do not pass through it.

**Released Yap 0.1.6 (build 7) uses the earlier public-client loopback flow.** The Worker retains that exchange/refresh route for compatibility. Changing this source or deploying the Worker does not retrofit the new native flow into the signed 0.1.6 installer. The revised flow needs a new packaged build, matching saved Zoom configuration, deployment and live authorization acceptance before a replacement is ready. Local checks below do not prove those steps have happened.

## Revised managed flow

1. The Mac creates an independent random state nonce and PKCE verifier and posts them with the production client ID to `POST /v1/oauth/session`. The service validates the fixed client/callback configuration and returns a Zoom authorization URL with an S256 challenge.
2. The OAuth state is an AES-GCM envelope containing the nonce, verifier, production audience, fixed redirect and an expiry of at most 180 seconds. It uses a key derived for the `authorization-session` purpose. The service keeps no session database; the encrypted envelope travels through the browser.
3. Zoom returns the authorization code to `GET /oauth/zoom/callback` on the exact configured HTTPS origin. The service authenticates/decrypts state, validates the redirect and expiry, and exchanges the code with Zoom using the production client secret and verifier. Production authorization codes are exchanged only here; `/v1/oauth/token` does not accept a native-supplied production authorization code.
4. After validating the token response and required scopes, the service creates its access-token-bound signing grant. It encrypts the token response, nonce, verifier hash and original token expiry into a distinct `native-token-handoff` envelope, also valid for at most 180 seconds. The completion page offers **Open Yap** at `yap://oauth/zoom?state=…&handoff=…`. The URL contains ciphertext, not a plaintext code, verifier or token.
5. The Mac validates and consumes the pending state once, then posts `grant_type=urn:yap:params:oauth:grant-type:handoff`, client ID, encrypted handoff, state and its original verifier to `/v1/oauth/token`. The service checks the proof and returns the tokens with their remaining lifetime; redemption does not extend token expiry. The app validates own-user ZAK access and saves credentials in Keychain.
6. Refresh uses the same HTTPS token endpoint, production client ID and refresh token. The server authenticates to Zoom with the production secret. SDK signing separately requires the access token plus `X-Signing-Authorization`; the service verifies the token-bound grant and a fresh own-user ZAK response before signing.

The session and handoff use purpose-separated authenticated encryption derived from `SIGNING_GRANT_SECRET`. The service processes plaintext only in request memory and has no persistent user/token store. Encrypted envelopes may remain in browser history; their expiry is not history deletion. The desktop consumes its pending nonce once, and Zoom controls authorization-code reuse. The stateless service has no consumed-handoff ledger: a handoff can be redeemed again before expiry only with the original verifier. Do not claim server-enforced one-time handoff redemption.

Callback pages return `no-store`, `no-referrer`, framing restrictions and a restrictive content security policy. Native API routes reject browser Origin headers. Token-bearing upstream requests go to fixed Zoom URLs and reject redirects. Request/provider body sizes and upstream time are bounded. Invocation logs and traces are disabled; unexpected application errors log only a fixed event. Cloudflare infrastructure metadata and rate-limit state remain separate from application credential retention. See [Privacy](../../PRIVACY.md).

| Route | Purpose |
| --- | --- |
| `GET /connect` | Integration landing page with installation and explicit native sign-in entry |
| `POST /v1/oauth/session` | Create an encrypted production OAuth session |
| `GET /oauth/zoom/callback` | Receive Zoom's code on the fixed HTTPS callback and render the native handoff |
| `POST /v1/oauth/token` | Redeem a production handoff or refresh production tokens; retain explicitly selected legacy public-client exchange/refresh |
| `POST /v1/meeting-sdk/signature` | Verify the token-bound signing grant and current Zoom access, then issue the native SDK JWT |
| `GET /health` | Service health only; not an authorization or deployment-configuration test |

## Configuration and compatibility

The current source configuration uses:

| Binding | Meaning / configured public value |
| --- | --- |
| `ZOOM_OAUTH_CLIENT_ID` | Production OAuth client: `UHoml3aIQpy86gZeijjfpQ` |
| `ZOOM_SDK_CLIENT_ID` | Production SDK client: `UHoml3aIQpy86gZeijjfpQ` |
| `ZOOM_OAUTH_REDIRECT_URI` | `https://meeting-auth.mgrinich.workers.dev/oauth/zoom/callback`; must exactly match the registered Zoom callback and signed app's service origin |
| `ZOOM_PUBLIC_CLIENT_ID` | Legacy public-client compatibility only: `_Xz_EnBNS3OPtUmqZ1og3A` |
| `ZOOM_SDK_CLIENT_SECRET` | Server secret used for SDK signing and confidential OAuth only when the production OAuth and SDK client IDs match |
| `SIGNING_GRANT_SECRET` | Independent random server secret of at least 43 characters for signed grants and purpose-separated envelope keys |

Production configuration fails closed unless the OAuth and SDK IDs match and the callback is a fixed HTTPS URL with a fully qualified hostname and `/oauth/zoom/callback` path. No user info, arbitrary port, query or fragment is accepted. Verify the provider's saved production credentials and callback against the packaged candidate; identifiers in source alone are not proof of provider configuration or approval.

The legacy `authorization_code` request is accepted only for `ZOOM_PUBLIC_CLIENT_ID`, with its PKCE verifier and an `http://127.0.0.1:<ephemeral-port>/callback` redirect. Legacy refresh and signing grants remain tied to that legacy client ID. This preserves the old managed installer; it does not make loopback the production confidential-client callback. Personal developer mode is different again: its Mac communicates directly with Zoom and signs locally, without this service.

Both managed flows require the same user-level scopes: `user:read:zak`, `meeting:write:meeting`, and `cloud_recording:read:list_user_recordings`. No admin/master scopes are requested. See the [functional test plan](../../Documentation/Zoom-Test-Plan.md) for account roles, prepared data, expected outcomes and remaining acceptance work.

## Development environment

The named Wrangler environment `development` uses a separate Worker, `meeting-auth-development`, and the Zoom app's development credential pair. Its fixed callback is `https://meeting-auth-development.mgrinich.workers.dev/oauth/zoom/callback`. Register that exact HTTPS URL in Zoom's **Development** OAuth configuration; the production callback remains on `meeting-auth.mgrinich.workers.dev`.

Development OAuth and SDK identifiers are both `ZA20iVuUSmSKMGVmx7tDyA`; its legacy public-client identifier is `l_yJBHqMTnOAnq2TdzeceQ`. The environment repeats all non-inherited bindings, uses separate rate-limit namespaces, and keeps the same restrictions on invocation logging and traces. Provision its own `ZOOM_SDK_CLIENT_SECRET` from the matching development credentials and a different random `SIGNING_GRANT_SECRET`. Production secrets must not be copied into this environment.

For development operations, pass `--env development` explicitly. The root configuration targets production; omit the environment only for an intentional production operation. A non-deploying development bundle check is:

```sh
WRANGLER_SEND_METRICS=false ./node_modules/.bin/wrangler deploy --env development --dry-run --outdir .wrangler/dry-run-development
```

A development app must use the development client IDs and `https://meeting-auth-development.mgrinich.workers.dev/v1/meeting-sdk/signature` in its Zoom configuration. This selects the separate session, callback, token and signing endpoints. The released app and production review candidate keep the production IDs and service origin; Google Calendar configuration is unchanged. Configuring this environment does not provision its secrets or deploy it, and a successful dry run does not establish that its live Zoom authorization works.

## Local checks

Use Node.js 24 and the committed `package-lock.json`. Its public npm registry URLs, exact versions, and integrity hashes make dependency installation independent of a developer's registry proxy. Optional platform packages provide the native tooling; dependency lifecycle scripts are disabled.

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm run typecheck
npm test
WRANGLER_SEND_METRICS=false ./node_modules/.bin/wrangler deploy --dry-run --outdir .wrangler/dry-run
```

Tests inject synthetic provider responses and do not require Zoom or Cloudflare credentials. The dry run compiles and validates a bundle without uploading it. These checks do not establish that production credentials, Zoom approval, or a deployed endpoint are configured.

`worker-configuration.d.ts` is generated by the locked Wrangler version. It includes runtime types and binding names from `wrangler.jsonc`, including the two required secrets. Check the committed output using the invalid example placeholders, without real secrets:

```sh
(
  test ! -e .dev.vars || exit 1
  trap 'unlink .dev.vars' EXIT
  cp .dev.vars.example .dev.vars
  npm run types -- --check
)
```

After an intentional binding or Wrangler change, run the same command without `-- --check` and review the generated file. `--strict-vars false` generates string types rather than secret values. If `.dev.vars` already exists, the example command stops to preserve it; use an isolated checkout for this check.

## CI and deployment boundary

The authentication-service job in `.github/workflows/ci.yml` runs on ordinary pushes and pull requests with read-only repository permissions, no persisted GitHub credentials, and no Cloudflare or Zoom secrets. It uses `.dev.vars.example` only while checking generated declarations and deletes the temporary copy before any bundle check. The job never deploys and does not publish the bundle.

`.dev.vars.example` contains deliberately invalid development placeholders. Do not upload it with `wrangler secret bulk` or `--secrets-file`, and do not copy its values into production. `.dev.vars` is ignored by Git. Production setup is separate: verify the production OAuth/SDK IDs and fixed HTTPS callback, provision the matching production secret and independent signing-grant secret through Cloudflare's secret storage, and confirm the legacy ID needed by already released apps. Validate the full deployed browser/native flow with the new packaged app before calling it ready. Keep secret values out of command arguments, logs, source files and public CI.

Wrangler's [dry-run command](https://developers.cloudflare.com/workers/wrangler/commands/#deploy) and [local secret handling](https://developers.cloudflare.com/workers/local-development/environment-variables/) document the distinction between local validation and deployment.

## Local review and help preview

Generate the local-only `public/` documentation preview from the repository root. This generated site is separate from the Worker's dynamic `/connect` and OAuth completion pages; the Worker has no static asset binding for `public/`:

```sh
python3 Scripts/build-review-site.py
python3 Scripts/build-review-site.py --check
python3 -m unittest discover -s Scripts/tests -p test_review_site.py -v
```

The generator uses Python's standard library and an escaped Markdown subset, with no network access or new dependencies. Privacy, terms, and notices render directly from their root documents; the homepage and support page reuse README content. Edit `site/guide.md` for the user guide and `site/site.css` for styling. Branding comes from the README heading. This generated preview is local-only (`http://127.0.0.1:8000`). The repository documents are its sources; preparing an integration landing page does not publish or migrate the generated legal/documentation site.

The only copied images are Yap's app icon and the three sample screenshots described in `Documentation/Images/README.md`: the native meeting gallery with fictional participants, the recording player, and the agenda. The gallery leads the homepage and preview metadata; recordings and agenda are secondary. Files under `public/` are an explicit allowlist. Generation validates local links and anchors; `--check` also rejects stale pages or unexpected files. CI checks generated output before bundling. The site has no scripts, forms, analytics, external fonts, or remote image requests. Its `_headers` policy applies to static asset responses; API headers remain the Worker's responsibility.

The local preview routes are `/`, `/guide/`, `/support/`, `/privacy/`, `/terms/`, and `/notices/`, with a separate 404 page. Terms render from their GitHub source, including its effective date. Generating the preview does not publish a site or change the Terms. Regenerate and run `--check` after updating the README or capture assets.
