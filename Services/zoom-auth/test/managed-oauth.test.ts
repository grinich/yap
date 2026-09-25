import assert from "node:assert/strict";
import {test} from "node:test";
import {handleRequest} from "../src/index.ts";

const NOW = 1_800_000_000;
const STATE = "n".repeat(43);
const VERIFIER = "v".repeat(43);
const HANDOFF_GRANT = "urn:yap:params:oauth:grant-type:handoff";
function environment(): Env {
  return {ZOOM_PUBLIC_CLIENT_ID: "legacy-public", ZOOM_OAUTH_CLIENT_ID: "production-client", ZOOM_SDK_CLIENT_ID: "production-client",
    ZOOM_OAUTH_REDIRECT_URI: "https://auth.example.test/oauth/zoom/callback", ZOOM_SDK_CLIENT_SECRET: "fixture-secret",
    ZOOM_OAUTH_LEGACY_REDIRECT_URIS: "[]",
    SIGNING_GRANT_SECRET: "independent-fixture-key-with-at-least-43-characters",
    REQUEST_LIMITER: {limit: async () => ({success: true})}, SIGNATURE_LIMITER: {limit: async () => ({success: true})}};
}
function post(path: string, body: unknown, headers: Record<string, string> = {}) {
  return new Request(`https://auth.example.test${path}`, {method: "POST", headers: {"Content-Type": "application/json", ...headers}, body: JSON.stringify(body)});
}
function deps(responder: (url: string, init: RequestInit) => Response | Promise<Response>, now = NOW) {
  return {now: () => now, fetch: (async (url: RequestInfo | URL, init?: RequestInit) => responder(String(url), init ?? {})) as typeof fetch};
}
const noNetwork = deps(() => { assert.fail("must not contact Zoom"); });
const tokens = () => ({access_token: "private-access-fixture", refresh_token: "private-refresh-fixture", token_type: "bearer",
  expires_in: 3600, scope: "user:read:zak meeting:write:meeting cloud_recording:read:list_user_recordings"});
const sessionBody = () => ({client_id: "production-client", code_verifier: VERIFIER, state: STATE});
async function start(env = environment()): Promise<URL> {
  const response = await handleRequest(post("/v1/oauth/session", sessionBody()), env, noNetwork);
  assert.equal(response.status, 200);
  const value = await response.json() as {authorize_url: string, expires_in: number};
  assert.equal(value.expires_in, 180);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  return new URL(value.authorize_url);
}
function callback(authorize: URL, changes: Record<string, string> = {}): Request {
  const url = new URL(authorize.searchParams.get("redirect_uri")!);
  url.search = new URLSearchParams({state: authorize.searchParams.get("state")!, code: "private-code-fixture", ...changes}).toString();
  return new Request(url);
}
function productionProvider(url: string, init: RequestInit) {
  assert.equal(url, "https://zoom.us/oauth/token");
  assert.equal(init.redirect, "manual");
  assert.equal(init.method, "POST");
  assert.equal(new Headers(init.headers).get("Authorization"), `Basic ${btoa("production-client:fixture-secret")}`);
  assert.deepEqual(Object.fromEntries(new URLSearchParams(String(init.body))), {grant_type: "authorization_code", client_id: "production-client",
    code: "private-code-fixture", redirect_uri: "https://auth.example.test/oauth/zoom/callback", code_verifier: VERIFIER});
  return Response.json(tokens());
}
async function handoff(env = environment()): Promise<URL> {
  const authorize = await start(env);
  const response = await handleRequest(callback(authorize), env, deps(productionProvider));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  assert.equal(response.headers.get("Referrer-Policy"), "no-referrer");
  assert.match(response.headers.get("Content-Security-Policy") ?? "", /default-src 'none'/);
  const html = await response.text();
  for (const secret of [VERIFIER, "private-code-fixture", "private-access-fixture", "private-refresh-fixture", "fixture-secret"]) {
    assert.equal(html.includes(secret), false);
  }
  const target = /href="(yap:\/\/oauth\/zoom\?[^"]+)"/.exec(html)?.[1];
  assert.ok(target);
  return new URL(target.replaceAll("&amp;", "&"));
}
function redeem(url: URL, changes: Record<string, string> = {}) {
  return post("/v1/oauth/token", {grant_type: HANDOFF_GRANT, client_id: "production-client", code_verifier: VERIFIER,
    state: url.searchParams.get("state"), handoff: url.searchParams.get("handoff"), ...changes});
}

test("managed authorization pins production client and HTTPS redirect while sealing verifier and nonce", async () => {
  const authorize = await start();
  assert.equal(authorize.origin + authorize.pathname, "https://zoom.us/oauth/authorize");
  assert.equal(authorize.searchParams.get("client_id"), "production-client");
  assert.equal(authorize.searchParams.get("redirect_uri"), environment().ZOOM_OAUTH_REDIRECT_URI);
  assert.equal(authorize.searchParams.get("code_challenge_method"), "S256");
  const challenge = Buffer.from(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(VERIFIER))).toString("base64url");
  assert.equal(authorize.searchParams.get("code_challenge"), challenge);
  assert.match(authorize.searchParams.get("state")!, /^v1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
  for (const value of [VERIFIER, STATE, environment().ZOOM_SDK_CLIENT_SECRET]) assert.equal(authorize.href.includes(value), false);
});

test("HTTPS callback exchanges code server-side and handoff requires the initiating verifier and nonce", async () => {
  const target = await handoff();
  assert.equal(target.origin, "null");
  assert.equal(target.protocol, "yap:"); assert.equal(target.hostname, "oauth"); assert.equal(target.pathname, "/zoom");
  assert.equal(target.searchParams.get("state"), STATE);
  assert.equal((await handleRequest(redeem(target, {code_verifier: "x".repeat(43)}), environment(), noNetwork)).status, 400);
  assert.equal((await handleRequest(redeem(target, {state: "x".repeat(43)}), environment(), noNetwork)).status, 400);
  assert.equal((await handleRequest(redeem(target, {client_id: "legacy-public"}), environment(), noNetwork)).status, 400);
  const response = await handleRequest(redeem(target), environment(), {...noNetwork, now: () => NOW + 30});
  assert.equal(response.status, 200);
  const body = await response.json() as Record<string, unknown>;
  assert.equal(body.access_token, tokens().access_token); assert.equal(body.refresh_token, tokens().refresh_token);
  assert.equal(body.expires_in, 3570); assert.equal(typeof body.signing_authorization, "string");
  assert.equal(JSON.stringify(body).includes("fixture-secret"), false);
});

test("expired, tampered, wrong-purpose and wrong-origin states never exchange a code", async () => {
  const authorize = await start();
  const expired = await handleRequest(callback(authorize), environment(), {...noNetwork, now: () => NOW + 180});
  assert.equal(expired.status, 400);
  const state = authorize.searchParams.get("state")!;
  for (const value of ["unsigned", state.replace("v1.", "v2."), state.slice(0, -8) + "tampered"]) {
    assert.equal((await handleRequest(callback(authorize, {state: value}), environment(), noNetwork)).status, 400);
  }
  const wrongOrigin = new URL(callback(authorize).url); wrongOrigin.hostname = "attacker.example";
  assert.equal((await handleRequest(new Request(wrongOrigin), environment(), noNetwork)).status, 400);
  const duplicate = new URL(callback(authorize).url); duplicate.searchParams.append("state", state);
  assert.equal((await handleRequest(new Request(duplicate), environment(), noNetwork)).status, 400);
  const target = await handoff();
  assert.equal((await handleRequest(callback(authorize, {state: target.searchParams.get("handoff")!}), environment(), noNetwork)).status, 400);
  assert.equal((await handleRequest(redeem(target, {handoff: state}), environment(), noNetwork)).status, 400);
  assert.equal((await handleRequest(redeem(target), environment(), {...noNetwork, now: () => NOW + 180})).status, 400);
});

test("only Zoom callback redeems production code; confidential refresh stays server-authenticated", async () => {
  const direct = post("/v1/oauth/token", {client_id: "production-client", grant_type: "authorization_code",
    code: "private-code-fixture", code_verifier: VERIFIER, redirect_uri: environment().ZOOM_OAUTH_REDIRECT_URI});
  assert.equal((await handleRequest(direct, environment(), noNetwork)).status, 400);
  const request = post("/v1/oauth/token", {client_id: "production-client", grant_type: "refresh_token", refresh_token: "refresh-fixture"});
  const response = await handleRequest(request, environment(), deps((url, init) => {
    assert.equal(url, "https://zoom.us/oauth/token");
    assert.equal(new Headers(init.headers).get("Authorization"), `Basic ${btoa("production-client:fixture-secret")}`);
    assert.equal(new URLSearchParams(String(init.body)).get("refresh_token"), "refresh-fixture");
    return Response.json(tokens());
  }));
  assert.equal(response.status, 200);
});

test("secret reuse fails closed when OAuth and SDK credential identities differ", async () => {
  const env = {...environment(), ZOOM_SDK_CLIENT_ID: "different-sdk-app"};
  assert.equal((await handleRequest(post("/v1/oauth/session", sessionBody()), env, noNetwork)).status, 503);
  assert.equal((await handleRequest(post("/v1/oauth/token", {client_id: "production-client", grant_type: "refresh_token", refresh_token: "refresh"}), env, noNetwork)).status, 503);
});

test("session inputs, cancellation and provider failures disclose no secrets or open redirects", async () => {
  for (const changes of [{code_verifier: "short"}, {state: "short"}, {client_id: "legacy-public"}, {redirect_uri: "https://attacker.test"}]) {
    assert.equal((await handleRequest(post("/v1/oauth/session", {...sessionBody(), ...changes}), environment(), noNetwork)).status, 400);
  }
  assert.equal((await handleRequest(post("/v1/oauth/session", sessionBody(), {Origin: "https://attacker.test"}), environment(), noNetwork)).status, 403);
  const authorize = await start();
  const deniedURL = new URL(callback(authorize).url); deniedURL.searchParams.delete("code");
  deniedURL.searchParams.set("error", "access_denied"); deniedURL.searchParams.set("error_description", "<script>private-code-fixture</script>");
  const denied = await handleRequest(new Request(deniedURL), environment(), noNetwork);
  const deniedHTML = await denied.text();
  assert.equal(denied.status, 200); assert.ok(deniedHTML.includes("error=access_denied")); assert.equal(deniedHTML.includes("private-code-fixture"), false);
  const failure = await handleRequest(callback(authorize), environment(), deps(() => new Response("private-code-fixture", {status: 400})));
  const html = await failure.text();
  assert.ok(html.includes("error=authorization_failed")); assert.equal(html.includes("private-code-fixture"), false);
  assert.equal(failure.headers.get("Location"), null);
});

test("a sealed handoff can only be replayed with its original proof until its short expiry", async () => {
  const target = await handoff();
  // No server-side consumption database: only the original proof can retrieve
  // the same response during this window. The desktop consumes its nonce once.
  for (let i = 0; i < 2; i++) assert.equal((await handleRequest(redeem(target), environment(), noNetwork)).status, 200);
  assert.equal((await handleRequest(redeem(target), environment(), {...noNetwork, now: () => NOW + 180})).status, 400);
});
