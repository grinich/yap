# Yap code relay for Zoom

This Cloudflare Worker relays a **short-lived authorization code** from the branded HTTPS callback to the initiating Mac. The Mac performs public-client PKCE token exchange and refresh directly with Zoom. The Worker never exchanges codes, refreshes tokens, returns OAuth tokens, or signs SDK JWTs. Meeting media, chat attachments, recordings and Google Calendar data do not pass through it.

Zoom's [public PKCE guidance](https://developers.zoom.us/blog/public-pkce/) supports direct token exchange without a client secret or Authorization header and native SDK authentication through `ZoomSDKAuthContext.publicAppKey`. Yap uses the public client ID for this property; the pinned SDK 7.1.5 header exposes it as an alternative to `jwtToken`. Actual release acceptance still requires live own-user authorization, SDK authentication and meeting tests.

## Protocol

1. The Mac generates an OAuth PKCE verifier, a separate handoff verifier and a random state nonce. **The OAuth verifier never leaves the Mac except for its direct Zoom token request.** It posts only the two S256 challenges and state to `POST /v1/oauth/session`:

   ```json
   {"client_id":"PUBLIC_CLIENT_ID","code_challenge":"S256_CHALLENGE","code_challenge_method":"S256","handoff_challenge":"INDEPENDENT_S256_CHALLENGE","state":"RANDOM_NONCE"}
   ```

2. The Worker accepts only its configured public client and exact canonical callback origin. Both challenges and the nonce are 43-character base64url values; the challenges must differ. It returns `{authorize_url, expires_in:180}`. The Zoom authorization URL includes public client ID, fixed HTTPS redirect, S256 challenge and an authenticated `v2` state envelope.
3. The browser returns to `/oauth/zoom/callback`. The Worker validates the state envelope, audience, fixed redirect and original 180-second deadline. It **does not contact Zoom or infer that authentication succeeded**. It wraps the authorization code, client, redirect, nonce and handoff challenge in a separate authenticated envelope. The page's explicit **Open Yap** link contains `yap://oauth/zoom?state=…&handoff=…`; this custom URL contains no plaintext code or verifier. Cancellation returns only the nonce and generic cancellation indication.
4. The Mac validates the pending state and posts `{client_id,handoff,state,handoff_verifier}` to `POST /v1/oauth/handoff`. After proof, audience, expiry and redirect checks, the Worker returns exactly `{code,redirect_uri,client_id}`. It does not return a signing grant, access token, refresh token or SDK signature.
5. The Mac validates those fields, then exchanges the code **directly at `https://zoom.us/oauth/token`** using the public client ID and original OAuth verifier. Only Zoom can validate/consume this code and issue the tokens. The Mac validates required scopes and own-user access before saving credentials in Keychain. Refresh and API requests also go directly to Zoom.
6. Native SDK authentication uses the public client ID through `publicAppKey`; starting/joining as the signed-in user still uses the own-user ZAK and Zoom's SDK authorization checks.

The session and handoff share the **original** 180-second deadline; callback and redemption do not extend it. The envelopes use purpose-separated AES-GCM keys derived from the existing `SIGNING_GRANT_SECRET` (the legacy binding name is retained to minimize deployment migration). Neither OAuth verifier nor OAuth tokens are placed in an envelope. The browser callback itself necessarily carries Zoom's short-lived code; invocation logging and traces remain disabled.

This stateless relay has no consumed-handoff ledger. The same handoff can be redeemed again within its short deadline only with its original proof. Zoom enforces single-use code exchange and the native app consumes its pending nonce. Do not claim server-enforced one-time handoff redemption. An attacker-supplied callback code is not authorization evidence: it can only reach Zoom's PKCE validation and cannot unlock any signing or token API on this Worker.

## Routes and legacy retirement

| Route | Behavior |
| --- | --- |
| `GET /connect` | Integration landing page and explicit native sign-in entry |
| `POST /v1/oauth/session` | Creates a code-only public PKCE session; old `code_verifier` requests return `410 update_required` |
| `GET /oauth/zoom/callback` | Validates the fixed callback/session and renders an encrypted code handoff |
| `POST /v1/oauth/handoff` | Validates the independent proof and returns only code, redirect and public client ID |
| `/v1/oauth/token` | Retired: `410 {"error":"update_required"}` for every method and grant; no body processing or upstream call |
| `/v1/meeting-sdk/signature` | Retired: `410 {"error":"update_required"}`; no SDK JWT issuance |
| `GET /health` | Liveness only, not proof of OAuth/SDK readiness |

Retirement includes old public loopback exchanges, confidential exchanges, refresh requests and encrypted **token** handoffs. Old ciphertext purposes/versions cannot be redeemed by the new handoff route. Older signed apps require an update and a fresh explicit Zoom sign-in; their saved proxy-flow credentials are not sufficient evidence of native-PKCE provenance. Do not present a failed old-client refresh or an encrypted code handoff as a completed connection.

## Configuration and domains

| Binding | Production | Development |
| --- | --- | --- |
| `ZOOM_PUBLIC_CLIENT_ID` | `_Xz_EnBNS3OPtUmqZ1og3A` | `l_yJBHqMTnOAnq2TdzeceQ` |
| `ZOOM_OAUTH_REDIRECT_URI` | `https://auth.yap.enterprises/oauth/zoom/callback` | `https://auth-dev.yap.enterprises/oauth/zoom/callback` |
| `ZOOM_OAUTH_LEGACY_REDIRECT_URIS` | Old production workers.dev callback | Old development workers.dev callback |
| `SIGNING_GRANT_SECRET` | Existing independent random envelope secret, at least 43 characters | Separate development envelope secret |
| `REQUEST_LIMITER` | Production request-rate namespace | Separate development request-rate namespace |

There is no OAuth/SDK confidential client ID, SDK secret or signature limiter dependency. The server's existing envelope secret name is intentionally unchanged. This source does not delete old deployed secrets; removal from Cloudflare is an operator action after reviewing rollback requirements. Never copy production secrets into development or put them in source, logs, command arguments or local test output.

Every configured callback must be fixed HTTPS with a fully qualified hostname and `/oauth/zoom/callback`, with no credentials, custom port, query or fragment. The legacy list permits at most four distinct origins. New sessions and handoffs accept **only the canonical branded origin**. Known workers.dev origins return update-required for native routes; their old browser callbacks ask the user to restart. Other origins and cross-environment envelopes fail closed. Callback URLs are never built from request Host/forwarding headers or client input.

The public OAuth callback must match Zoom's saved environment-specific allowlist and the packaged native app exactly. The Worker custom domains remain `auth.yap.enterprises` and `auth-dev.yap.enterprises`; the public `yap.enterprises` website is separate. `workers_dev` remains enabled only to serve explicit migration failures and the existing landing/health pages. It does not retain token-proxy compatibility.

## Security and data boundary

Native routes reject browser Origin headers. Inputs and encrypted envelopes are size-bounded. Callback pages use no-store, no-referrer, framing restrictions and a restrictive Content Security Policy. There are no outbound Worker fetches, user/token database or persistent code store. Unexpected errors log only the constant `auth_service_failure` event, never exception text or request data. Application log policy does not imply that Cloudflare retains no infrastructure metadata.

Both environments keep invocation logs and tracing disabled and explicitly enable query-string redaction for Workers logs and traces. This is not a claim about platform-wide infrastructure retention. The request limiter keys are hashes of the source IP; that rate-limit state is separate from application credential storage. Encrypted handoffs may remain in browser history, but cannot be decrypted without the server key or redeemed without the independent proof before expiry. Expiry is not history deletion.

The native app retains the same requested user scopes: `user:read:zak`, `meeting:write:meeting`, and `cloud_recording:read:list_user_recordings`. No API traffic or recording bytes are proxied by this Worker. See the repository's functional test plan for live prerequisites; synthetic tests do not prove provider configuration, account consent, cross-account meetings or reviewer acceptance.

## Local validation

Use Node.js 24 and the committed lockfile. Tests use synthetic code/challenge values and request stubs; no Zoom or Cloudflare credential is needed.

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm run typecheck
npm test
WRANGLER_SEND_METRICS=false ./node_modules/.bin/wrangler deploy --env '' --dry-run --outdir .wrangler/dry-run
WRANGLER_SEND_METRICS=false ./node_modules/.bin/wrangler deploy --env development --dry-run --outdir .wrangler/dry-run-development
```

Dry runs bundle locally without publishing. `worker-configuration.d.ts` is generated by locked Wrangler. Use only the deliberately invalid example placeholder to check generated bindings:

```sh
(
  test ! -e .dev.vars || exit 1
  trap 'unlink .dev.vars' EXIT
  cp .dev.vars.example .dev.vars
  npm run types -- --check
)
```

After changing bindings, run the same operation without `-- --check` and review the generated diff. Never overwrite a pre-existing `.dev.vars`. `--strict-vars false` generates string types rather than embedding values. Do not upload `.dev.vars.example` via secret tooling.

The existing CI authentication job uses read-only repository permissions, synthetic placeholders, dependency lockfile and local tests/typechecks/bundle checks. It does not deploy. Wrangler's [dry-run docs](https://developers.cloudflare.com/workers/wrangler/commands/#deploy) and [local secret handling](https://developers.cloudflare.com/workers/local-development/environment-variables/) explain this boundary.

## Deployment and release acceptance

1. Confirm Zoom public-client PKCE is enabled separately for production/development and the exact branded HTTPS callback is allowed in each. Preserve the public IDs and existing environment-specific envelope secrets.
2. Deploy the code relay to development first, then production after local checks and live development acceptance. The named `--env development` targets the development Worker; an omitted environment targets production. Production mutations remain an explicit operator step.
3. Test consent, cancellation, return to the initiating app, direct Zoom exchange/refresh and SDK `publicAppKey` authentication. Check that token/signature endpoints and old session callers return update-required on both canonical and workers.dev origins, without revealing credentials.
4. Package the native app with the matching public ID and callback. Verify that old proxy-flow credentials prompt fresh connection, successful own-user ZAK is required where appropriate, and failures never claim a connected account. Complete real meeting/recording acceptance and signed release verification before handoff to reviewers.

No Worker source change alone updates already installed clients or establishes approval. A health response is not a complete authorization test. Keep live credentials and private meeting/account evidence outside public source.

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
