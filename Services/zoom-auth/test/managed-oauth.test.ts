import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import test from "node:test";
import {handleRequest} from "../src/index.ts";

const ORIGIN = "https://auth.example.test";
const NOW = 1_800_000_000;
// RFC 7636 Appendix B: an independent S256 vector, not a password-storage hash.
// https://www.rfc-editor.org/rfc/rfc7636#appendix-B
const OAUTH_VERIFIER = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
const OAUTH_CHALLENGE = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";
const HANDOFF_VERIFIER = "h".repeat(43);
const STATE = "n".repeat(43);
const CODE = "authorization-code-for-native-only";
const hash = (value: string) => createHash("sha256").update(value).digest("base64url");
function environment(): Env {
  return {ZOOM_PUBLIC_CLIENT_ID: "test-public-client", ZOOM_OAUTH_REDIRECT_URI: `${ORIGIN}/oauth/zoom/callback`,
    ZOOM_OAUTH_LEGACY_REDIRECT_URIS: "[]", SIGNING_GRANT_SECRET: "test-only-envelope-secret-which-is-at-least-43-characters",
    REQUEST_LIMITER: {limit: async () => ({success: true})}};
}
function post(path: string, body: unknown): Request {
  return new Request(`${ORIGIN}${path}`, {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(body)});
}
async function local(request: Request, env = environment(), now = NOW): Promise<Response> {
  let calls = 0;
  const response = await handleRequest(request, env, {now: () => now, fetch: (async () => {
    calls++;
    return Response.json({access_token: "must-never-be-returned", refresh_token: "must-never-be-returned"});
  }) as typeof fetch});
  assert.equal(calls, 0, "the code-only service must never call an upstream service");
  return response;
}
async function start(changes: Record<string, unknown> = {}): Promise<URL> {
  const response = await local(post("/v1/oauth/session", {client_id: environment().ZOOM_PUBLIC_CLIENT_ID,
    code_challenge: OAUTH_CHALLENGE, code_challenge_method: "S256", handoff_challenge: hash(HANDOFF_VERIFIER), state: STATE, ...changes}));
  assert.equal(response.status, 200);
  const body = await response.json() as {authorize_url: string; expires_in: number};
  assert.equal(body.expires_in, 180);
  return new URL(body.authorize_url);
}
function callback(authorize: URL, changes: Record<string, string> = {}): URL {
  const url = new URL(environment().ZOOM_OAUTH_REDIRECT_URI);
  url.search = new URLSearchParams({state: authorize.searchParams.get("state")!, code: CODE, ...changes}).toString();
  return url;
}
function returnURL(html: string): URL {
  const match = html.match(/href="(yap:\/\/oauth\/zoom\?[^"\s]+)"/);
  assert.ok(match, "callback page must have the fixed native return URL");
  return new URL(match[1].replaceAll("&amp;", "&"));
}
async function handoff(authorize: URL, now = NOW, code = CODE): Promise<string> {
  const response = await local(new Request(callback(authorize, {code})), environment(), now);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  assert.equal(response.headers.get("Pragma"), "no-cache");
  assert.equal(response.headers.get("Referrer-Policy"), "no-referrer");
  assert.equal(response.headers.get("X-Frame-Options"), "DENY");
  assert.match(response.headers.get("Content-Security-Policy")!, /default-src 'none'/);
  assert.match(response.headers.get("Content-Security-Policy")!, /frame-ancestors 'none'/);
  assert.equal(response.headers.get("Location"), null);
  const html = await response.text();
  assert.ok(!html.includes(code), "authorization code must be sealed inside the native link");
  assert.ok(!html.includes(OAUTH_VERIFIER));
  assert.ok(!html.includes(HANDOFF_VERIFIER));
  assert.doesNotMatch(html, /access_token|refresh_token|signing_grant|<script|<iframe|<form/);
  const url = returnURL(html);
  assert.equal(url.protocol, "yap:");
  assert.equal(url.hostname, "oauth");
  assert.equal(url.pathname, "/zoom");
  assert.deepEqual([...url.searchParams.keys()].sort(), ["handoff", "state"]);
  assert.equal(url.searchParams.get("state"), STATE);
  const sealed = url.searchParams.get("handoff")!;
  assert.match(sealed, /^v2\.[A-Za-z0-9_-]{16}\.[A-Za-z0-9_-]+$/);
  return sealed;
}
function redemption(sealed: string): Record<string, unknown> {
  return {client_id: environment().ZOOM_PUBLIC_CLIENT_ID, handoff: sealed, state: STATE, handoff_verifier: HANDOFF_VERIFIER};
}
async function rejectedCallback(url: URL, env = environment(), now = NOW): Promise<void> {
  const response = await local(new Request(url), env, now);
  assert.equal(response.status, 400);
  const html = await response.text();
  assert.match(html, /Start sign-in again/);
  assert.match(html, /href="yap:\/\/open"/);
  assert.doesNotMatch(html, /handoff=|access_token|refresh_token|signing_grant/);
  assert.equal(response.headers.get("Location"), null);
}
async function rejectedHandoff(body: Record<string, unknown>, env = environment(), now = NOW): Promise<void> {
  const response = await local(post("/v1/oauth/handoff", body), env, now);
  assert.equal(response.status, 400);
  const result = await response.json() as Record<string, unknown>;
  assert.deepEqual(Object.keys(result), ["error"]);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
}
function corrupted(value: string, part: 1 | 2): string {
  const pieces = value.split(".");
  const bytes = Buffer.from(pieces[part], "base64url");
  bytes[0] ^= 1;
  pieces[part] = bytes.toString("base64url");
  return pieces.join(".");
}

test("the authorization URL pins the public app, S256 proof and callback without either verifier", async () => {
  const authorize = await start();
  assert.equal(authorize.origin, "https://zoom.us");
  assert.equal(authorize.pathname, "/oauth/authorize");
  assert.deepEqual([...authorize.searchParams.keys()].sort(), ["client_id", "code_challenge", "code_challenge_method", "redirect_uri", "response_type", "state"]);
  assert.equal(authorize.searchParams.get("client_id"), environment().ZOOM_PUBLIC_CLIENT_ID);
  assert.equal(authorize.searchParams.get("code_challenge"), OAUTH_CHALLENGE);
  assert.equal(authorize.searchParams.get("code_challenge_method"), "S256");
  assert.equal(authorize.searchParams.get("redirect_uri"), environment().ZOOM_OAUTH_REDIRECT_URI);
  assert.equal(authorize.searchParams.get("response_type"), "code");
  assert.match(authorize.searchParams.get("state")!, /^v2\.[A-Za-z0-9_-]{16}\.[A-Za-z0-9_-]+$/);
  for (const secret of [OAUTH_VERIFIER, HANDOFF_VERIFIER, STATE, hash(HANDOFF_VERIFIER)]) assert.ok(!authorize.href.includes(secret));
  assert.notEqual((await start()).searchParams.get("state"), authorize.searchParams.get("state"), "session encryption must use a fresh IV");
});

test("callback and native handoff relay only code, exact redirect and public client ID", async () => {
  const sealed = await handoff(await start());
  const response = await local(post("/v1/oauth/handoff", redemption(sealed)), environment(), NOW + 30);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {code: CODE, redirect_uri: environment().ZOOM_OAUTH_REDIRECT_URI, client_id: environment().ZOOM_PUBLIC_CLIENT_ID});
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  assert.equal(response.headers.get("Referrer-Policy"), "no-referrer");
});

test("handoff redemption requires its separate proof, matching state, matching client and exact fields", async () => {
  const body = redemption(await handoff(await start()));
  for (const handoff_verifier of [OAUTH_VERIFIER, "x".repeat(43), "", "h".repeat(42), "h".repeat(129), " ".repeat(43), null]) {
    await rejectedHandoff({...body, handoff_verifier});
  }
  for (const change of [{state: "x".repeat(43)}, {state: "short"}, {client_id: "another-public-client"},
    {code_verifier: OAUTH_VERIFIER}, {access_token: "token"}, {refresh_token: "token"}, {redirect_uri: "https://attacker.test/callback"}]) {
    await rejectedHandoff({...body, ...change});
  }
  for (const key of Object.keys(body)) {
    const missing = {...body}; delete missing[key]; await rejectedHandoff(missing);
  }
});

test("session and handoff expire at 180 seconds without extending lifetime at callback", async () => {
  const authorize = await start();
  const sealed = await handoff(authorize, NOW + 179);
  assert.equal((await local(post("/v1/oauth/handoff", redemption(sealed)), environment(), NOW + 179)).status, 200);
  await rejectedCallback(callback(authorize), environment(), NOW + 180);
  await rejectedHandoff(redemption(sealed), environment(), NOW + 180);
  await rejectedCallback(callback(authorize), environment(), NOW - 31);
  await rejectedHandoff(redemption(sealed), environment(), NOW - 31);
  // The explicit clock-skew allowance is inclusive, but never changes expiry.
  assert.equal((await local(new Request(callback(authorize)), environment(), NOW - 30)).status, 200);
});

test("tampered, unsigned, obsolete and malformed envelopes cannot create or redeem a handoff", async () => {
  const authorize = await start();
  const state = authorize.searchParams.get("state")!;
  const sealed = await handoff(authorize);
  const malformed = ["", "unsigned-state", "v1.a.b", "v2.a.b", "v2.@@@.@@@", "v2.a.b.c", "x".repeat(12_001)];
  for (const value of [corrupted(state, 1), corrupted(state, 2), ...malformed]) {
    await rejectedCallback(callback(authorize, {state: value}));
  }
  for (const value of [corrupted(sealed, 1), corrupted(sealed, 2), ...malformed]) {
    await rejectedHandoff({...redemption(sealed), handoff: value});
  }
});

test("authorization sessions and native handoffs are cryptographically separated by purpose", async () => {
  const authorize = await start();
  const sealed = await handoff(authorize);
  await rejectedCallback(callback(authorize, {state: sealed}));
  await rejectedHandoff({...redemption(sealed), handoff: authorize.searchParams.get("state")!});
});

test("envelopes reject another public client or signing secret even with valid request parameters", async () => {
  const authorize = await start();
  const sealed = await handoff(authorize);
  for (const env of [{...environment(), ZOOM_PUBLIC_CLIENT_ID: "other-public-client"},
    {...environment(), SIGNING_GRANT_SECRET: "different-test-only-envelope-secret-at-least-43-characters"}]) {
    await rejectedCallback(callback(authorize), env);
    await rejectedHandoff({...redemption(sealed), client_id: env.ZOOM_PUBLIC_CLIENT_ID}, env);
  }
});

test("cancellation preserves only the state nonce and a fixed safe error", async () => {
  const authorize = await start();
  const url = callback(authorize);
  url.searchParams.delete("code");
  url.searchParams.set("error", 'provider-error-<script>alert(1)</script>');
  url.searchParams.set("error_description", "private provider detail");
  url.searchParams.set("error_uri", "https://attacker.test/");
  const response = await local(new Request(url));
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /Zoom sign-in wasn’t completed/);
  assert.doesNotMatch(html, /provider-error|private provider detail|attacker\.test|<script|handoff=/);
  const native = returnURL(html);
  assert.deepEqual([...native.searchParams], [["state", STATE], ["error", "access_denied"]]);
  assert.equal(response.headers.get("Location"), null);
  await rejectedCallback(url, environment(), NOW + 180);
});

test("callbacks reject duplicate parameters, ambiguous outcomes, absent codes and invalid code boundaries", async () => {
  const authorize = await start();
  for (const key of ["state", "code", "error"]) {
    const url = callback(authorize);
    if (key === "error") {url.searchParams.delete("code"); url.searchParams.set("error", "access_denied");}
    url.searchParams.append(key, url.searchParams.get(key)!);
    await rejectedCallback(url);
  }
  const both = callback(authorize, {error: "access_denied"});
  await rejectedCallback(both);
  const absent = callback(authorize); absent.searchParams.delete("code"); await rejectedCallback(absent);
  const noState = callback(authorize); noState.searchParams.delete("state"); await rejectedCallback(noState);
  for (const code of ["", "with space", "x".repeat(4097), "café", "x\n", "x\u0000"]) {
    await rejectedCallback(callback(authorize, {code}));
  }
  const tooLong = callback(authorize); tooLong.searchParams.set("extra", "x".repeat(8192));
  await rejectedCallback(tooLong);
});

test("maximum allowed code and handoff verifier lengths survive the full flow", async () => {
  const code = "c".repeat(4096);
  const proof = "h".repeat(128);
  const sealed = await handoff(await start({handoff_challenge: hash(proof)}), NOW, code);
  const response = await local(post("/v1/oauth/handoff", {...redemption(sealed), handoff_verifier: proof}));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {code, redirect_uri: environment().ZOOM_OAUTH_REDIRECT_URI, client_id: environment().ZOOM_PUBLIC_CLIENT_ID});
});

test("form handoffs reject duplicate client, envelope, state and proof parameters", async () => {
  const body = new URLSearchParams(redemption(await handoff(await start())) as Record<string, string>);
  const request = (value: URLSearchParams) => new Request(`${ORIGIN}/v1/oauth/handoff`, {method: "POST", body: value});
  const response = await local(request(body));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {code: CODE, redirect_uri: environment().ZOOM_OAUTH_REDIRECT_URI, client_id: environment().ZOOM_PUBLIC_CLIENT_ID});
  for (const [key, value] of body) {
    const duplicate = new URLSearchParams(body); duplicate.append(key, value);
    assert.equal((await local(request(duplicate))).status, 400);
  }
});

test("repeating a handoff cannot mint tokens or extend the original code lifetime", async () => {
  const sealed = await handoff(await start());
  // This stateless relay can repeat only the same short-lived code. The native app
  // consumes its nonce and Zoom enforces one-time code redemption using PKCE.
  for (const now of [NOW, NOW + 179]) {
    const response = await local(post("/v1/oauth/handoff", redemption(sealed)), environment(), now);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), {code: CODE, redirect_uri: environment().ZOOM_OAUTH_REDIRECT_URI, client_id: environment().ZOOM_PUBLIC_CLIENT_ID});
  }
  await rejectedHandoff(redemption(sealed), environment(), NOW + 180);
  for (const path of ["/v1/oauth/token", "/v1/meeting-sdk/signature"]) {
    const response = await local(post(path, {handoff: sealed, access_token: "unverified-token", signing_grant: sealed}));
    assert.equal(response.status, 410);
    assert.deepEqual(await response.json(), {error: "update_required"});
  }
});

test("an arbitrary callback code remains only a code and grants no Worker authority", async () => {
  const arbitraryCode = "unverified-callback-code";
  const sealed = await handoff(await start(), NOW, arbitraryCode);
  const response = await local(post("/v1/oauth/handoff", redemption(sealed)));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {code: arbitraryCode, redirect_uri: environment().ZOOM_OAUTH_REDIRECT_URI, client_id: environment().ZOOM_PUBLIC_CLIENT_ID});
});
