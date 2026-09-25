import assert from "node:assert/strict";
import {test} from "node:test";
import {handleRequest} from "../src/index.ts";

const NOW = 1_800_000_000;
const CANONICAL = "https://auth.yap.enterprises";
const LEGACY = "https://meeting-auth.mgrinich.workers.dev";
const DEVELOPMENT = "https://auth-dev.yap.enterprises";
const DEVELOPMENT_LEGACY = "https://meeting-auth-development.mgrinich.workers.dev";
const CALLBACK = "/oauth/zoom/callback";
const STATE = "n".repeat(43);
const VERIFIER = "v".repeat(43);
const TOKENS = {access_token: "fixture-access", refresh_token: "fixture-refresh", token_type: "bearer",
  expires_in: 3600, scope: "user:read:zak meeting:write:meeting cloud_recording:read:list_user_recordings"};

function environment(): Env {
  return {ZOOM_PUBLIC_CLIENT_ID: "fixture-legacy-client", ZOOM_OAUTH_CLIENT_ID: "fixture-client",
    ZOOM_SDK_CLIENT_ID: "fixture-client", ZOOM_SDK_CLIENT_SECRET: "fixture-sdk-secret",
    ZOOM_OAUTH_REDIRECT_URI: CANONICAL + CALLBACK,
    ZOOM_OAUTH_LEGACY_REDIRECT_URIS: JSON.stringify([LEGACY + CALLBACK]),
    SIGNING_GRANT_SECRET: "fixture-independent-grant-secret-at-least-43-characters",
    REQUEST_LIMITER: {limit: async () => ({success: true})}, SIGNATURE_LIMITER: {limit: async () => ({success: true})}};
}
function dependencies(responder: (url: string, init: RequestInit) => Response) {
  return {now: () => NOW, fetch: (async (url: RequestInfo | URL, init?: RequestInit) => responder(String(url), init ?? {})) as typeof fetch};
}
const noNetwork = dependencies(() => { assert.fail("must not contact Zoom"); });
function post(origin: string, path: string, body: unknown, headers: Record<string, string> = {}) {
  return new Request(origin + path, {method: "POST", headers: {"Content-Type": "application/json", ...headers}, body: JSON.stringify(body)});
}
function sessionRequest(origin: string, env = environment()) {
  return post(origin, "/v1/oauth/session", {client_id: env.ZOOM_OAUTH_CLIENT_ID, code_verifier: VERIFIER, state: STATE});
}
async function start(origin: string, env = environment()): Promise<URL> {
  const response = await handleRequest(sessionRequest(origin, env), env, noNetwork);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Location"), null);
  const authorize = new URL((await response.json() as {authorize_url: string}).authorize_url);
  assert.equal(authorize.searchParams.get("redirect_uri"), origin + CALLBACK);
  return authorize;
}
function callback(authorize: URL, origin: string): Request {
  const url = new URL(origin + CALLBACK);
  url.search = new URLSearchParams({state: authorize.searchParams.get("state")!, code: "fixture-code"}).toString();
  return new Request(url);
}
async function complete(authorize: URL, origin: string, env = environment()): Promise<URL> {
  const response = await handleRequest(callback(authorize, origin), env, dependencies((url, init) => {
    assert.equal(url, "https://zoom.us/oauth/token");
    const fields = new URLSearchParams(String(init.body));
    assert.equal(fields.get("redirect_uri"), origin + CALLBACK);
    assert.equal(fields.get("client_id"), env.ZOOM_OAUTH_CLIENT_ID);
    assert.equal(fields.get("code_verifier"), VERIFIER);
    assert.equal(new Headers(init.headers).get("Authorization"), `Basic ${btoa(`${env.ZOOM_OAUTH_CLIENT_ID}:${env.ZOOM_SDK_CLIENT_SECRET}`)}`);
    return Response.json(TOKENS);
  }));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Location"), null);
  const html = await response.text();
  const href = /href="(yap:\/\/oauth\/zoom\?[^"]+)"/.exec(html)?.[1];
  assert.ok(href);
  assert.equal(html.includes(TOKENS.access_token), false);
  return new URL(href.replaceAll("&amp;", "&"));
}

for (const origin of [CANONICAL, LEGACY]) {
  test(`full native authorization still works directly on ${origin}`, async () => {
    const env = environment();
    const handoff = await complete(await start(origin, env), origin, env);
    const response = await handleRequest(post(origin, "/v1/oauth/token", {
      grant_type: "urn:yap:params:oauth:grant-type:handoff", client_id: env.ZOOM_OAUTH_CLIENT_ID,
      code_verifier: VERIFIER, state: handoff.searchParams.get("state"), handoff: handoff.searchParams.get("handoff")
    }), env, noNetwork);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("Location"), null);
    const tokens = await response.json() as {access_token: string, signing_authorization: string};
    assert.equal(tokens.access_token, TOKENS.access_token);
    // Existing grants remain valid when an updated app uses the new origin.
    const signature = await handleRequest(post(CANONICAL, "/v1/meeting-sdk/signature", {}, {
      Authorization: `Bearer ${tokens.access_token}`, "X-Signing-Authorization": tokens.signing_authorization
    }), env, dependencies((url) => {
      assert.equal(url, "https://api.zoom.us/v2/users/me/zak");
      return Response.json({token: "fixture-zak"});
    }));
    assert.equal(signature.status, 200);
    assert.equal(signature.headers.get("Location"), null);
  });
}

test("in-flight legacy sign-in survives deployment of the canonical domain", async () => {
  const before = {...environment(), ZOOM_OAUTH_REDIRECT_URI: LEGACY + CALLBACK, ZOOM_OAUTH_LEGACY_REDIRECT_URIS: "[]"};
  const authorize = await start(LEGACY, before);
  await complete(authorize, LEGACY, environment());
});

test("moving a valid OAuth state between trusted callback hosts never exchanges a code", async () => {
  for (const [from, to] of [[CANONICAL, LEGACY], [LEGACY, CANONICAL]]) {
    const authorize = await start(from);
    const response = await handleRequest(callback(authorize, to), environment(), noNetwork);
    assert.equal(response.status, 400);
    assert.equal(response.headers.get("Location"), null);
    assert.doesNotMatch(await response.text(), /handoff=/);
  }
});

test("unknown origins cannot use auth APIs or spoof host selection with forwarding headers", async () => {
  for (const origin of ["https://attacker.example", "https://auth.yap.enterprises.attacker.example",
    "https://auth.yap.enterprises:8443", DEVELOPMENT, DEVELOPMENT_LEGACY]) {
    for (const path of ["/v1/oauth/session", "/v1/oauth/token", "/v1/meeting-sdk/signature", CALLBACK]) {
      const request = path === CALLBACK ? new Request(origin + path) : post(origin, path, {}, {
        Host: "auth.yap.enterprises", "X-Forwarded-Host": "auth.yap.enterprises", Forwarded: "host=auth.yap.enterprises;proto=https"
      });
      const response = await handleRequest(request, environment(), noNetwork);
      assert.equal(response.status, 400);
      assert.deepEqual(await response.json(), {error: "invalid_service_origin"});
    }
  }
});

test("malformed, duplicate and unsafe legacy callback configurations fail closed", async () => {
  for (const configured of ["not-json", "{}", '[null]', JSON.stringify(Array(5).fill(LEGACY + CALLBACK)),
    JSON.stringify([CANONICAL + CALLBACK]), JSON.stringify([LEGACY + CALLBACK, LEGACY + CALLBACK]),
    ...["http://legacy.example/oauth/zoom/callback", "https://legacy.example:8443/oauth/zoom/callback",
      "https://user@legacy.example/oauth/zoom/callback", "https://legacy.example/wrong-path",
      "https://legacy.example/oauth/zoom/callback?next=elsewhere", "https://legacy.example/oauth/zoom/callback#fragment"]
      .map(value => JSON.stringify([value]))]) {
    const env = {...environment(), ZOOM_OAUTH_LEGACY_REDIRECT_URIS: configured};
    assert.equal((await handleRequest(sessionRequest(CANONICAL, env), env, noNetwork)).status, 503);
  }
});

test("development uses its own canonical and legacy hosts and cannot accept production state", async () => {
  const env = {...environment(), ZOOM_OAUTH_CLIENT_ID: "fixture-development-client", ZOOM_SDK_CLIENT_ID: "fixture-development-client",
    ZOOM_OAUTH_REDIRECT_URI: DEVELOPMENT + CALLBACK,
    ZOOM_OAUTH_LEGACY_REDIRECT_URIS: JSON.stringify([DEVELOPMENT_LEGACY + CALLBACK]),
    SIGNING_GRANT_SECRET: "different-development-grant-secret-at-least-43-characters"};
  for (const origin of [DEVELOPMENT, DEVELOPMENT_LEGACY]) await complete(await start(origin, env), origin, env);
  for (const origin of [CANONICAL, LEGACY]) {
    assert.equal((await handleRequest(sessionRequest(origin, env), env, noNetwork)).status, 400);
  }
  const productionState = await start(CANONICAL);
  assert.equal((await handleRequest(callback(productionState, DEVELOPMENT), env, noNetwork)).status, 400);
});

test("saved production refresh tokens work on both service origins without changing credentials", async () => {
  for (const origin of [CANONICAL, LEGACY]) {
    const env = environment();
    const response = await handleRequest(post(origin, "/v1/oauth/token", {
      grant_type: "refresh_token", client_id: env.ZOOM_OAUTH_CLIENT_ID, refresh_token: "existing-refresh"
    }), env, dependencies((url, init) => {
      assert.equal(url, "https://zoom.us/oauth/token");
      assert.equal(new URLSearchParams(String(init.body)).get("refresh_token"), "existing-refresh");
      assert.equal(new Headers(init.headers).get("Authorization"), `Basic ${btoa("fixture-client:fixture-sdk-secret")}`);
      return Response.json(TOKENS);
    }));
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("Location"), null);
  }
});
