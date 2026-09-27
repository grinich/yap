import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import test from "node:test";
import {handleRequest} from "../src/index.ts";

const PRODUCTION = "https://auth.yap.enterprises";
const DEVELOPMENT = "https://auth-dev.yap.enterprises";
const OLD_PRODUCTION = "https://meeting-auth.mgrinich.workers.dev";
const OLD_DEVELOPMENT = "https://meeting-auth-development.mgrinich.workers.dev";
const CALLBACK = "/oauth/zoom/callback";
const NOW = 1_800_000_000;
const STATE = "n".repeat(43);
const PROOF = "h".repeat(43);
const CODE = "native-only-authorization-code";
const hash = (value: string) => createHash("sha256").update(value).digest("base64url");
function environment(development = false): Env {
  return {ZOOM_PUBLIC_CLIENT_ID: development ? "development-public-client" : "production-public-client",
    ZOOM_OAUTH_REDIRECT_URI: `${development ? DEVELOPMENT : PRODUCTION}${CALLBACK}`,
    ZOOM_OAUTH_LEGACY_REDIRECT_URIS: JSON.stringify([`${development ? OLD_DEVELOPMENT : OLD_PRODUCTION}${CALLBACK}`]),
    SIGNING_GRANT_SECRET: development ? "development-only-envelope-secret-at-least-43-characters" : "production-test-envelope-secret-at-least-43-characters",
    REQUEST_LIMITER: {limit: async () => ({success: true})}};
}
function sessionBody(env = environment()): Record<string, string> {
  return {client_id: env.ZOOM_PUBLIC_CLIENT_ID, code_challenge: hash("v".repeat(43)), code_challenge_method: "S256",
    handoff_challenge: hash(PROOF), state: STATE};
}
function post(origin: string, path: string, body: unknown, headers: Record<string, string> = {}): Request {
  return new Request(`${origin}${path}`, {method: "POST", headers: {"Content-Type": "application/json", ...headers}, body: JSON.stringify(body)});
}
async function local(request: Request, env = environment()): Promise<Response> {
  let calls = 0;
  const response = await handleRequest(request, env, {now: () => NOW, fetch: (async () => {
    calls++;
    return Response.json({access_token: "must-never-be-returned", refresh_token: "must-never-be-returned"});
  }) as typeof fetch});
  assert.equal(calls, 0, "canonical and migration requests must never call upstream");
  return response;
}
async function start(origin = PRODUCTION, env = environment()): Promise<URL> {
  const response = await local(post(origin, "/v1/oauth/session", sessionBody(env)), env);
  assert.equal(response.status, 200);
  const body = await response.json() as {authorize_url: string; expires_in: number};
  assert.deepEqual(Object.keys(body).sort(), ["authorize_url", "expires_in"]);
  assert.equal(body.expires_in, 180);
  return new URL(body.authorize_url);
}
function callback(origin: string, authorize: URL): URL {
  const url = new URL(`${origin}${CALLBACK}`);
  url.search = new URLSearchParams({state: authorize.searchParams.get("state")!, code: CODE}).toString();
  return url;
}
async function handoff(authorize: URL, origin = PRODUCTION, env = environment()): Promise<string> {
  const response = await local(new Request(callback(origin, authorize)), env);
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.ok(!html.includes(CODE));
  const match = html.match(/href="(yap:\/\/oauth\/zoom\?[^"\s]+)"/);
  assert.ok(match);
  const url = new URL(match[1].replaceAll("&amp;", "&"));
  assert.equal(url.searchParams.get("state"), STATE);
  return url.searchParams.get("handoff")!;
}
function redemption(sealed: string, env = environment()): Record<string, string> {
  return {client_id: env.ZOOM_PUBLIC_CLIENT_ID, handoff: sealed, state: STATE, handoff_verifier: PROOF};
}
async function expectError(response: Response, status: number, error: string): Promise<void> {
  assert.equal(response.status, status);
  assert.deepEqual(await response.json(), {error});
  assert.equal(response.headers.get("Location"), null);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
}
async function expectRestart(response: Response): Promise<void> {
  assert.equal(response.status, 400);
  const html = await response.text();
  assert.match(html, /Start sign-in again/);
  assert.match(html, /href="yap:\/\/open"/);
  assert.doesNotMatch(html, /handoff=|access_token|refresh_token|signing_grant/);
  assert.equal(response.headers.get("Location"), null);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
}

test("production code flow always uses the canonical branded callback and public client", async () => {
  const env = environment();
  const authorize = await start();
  assert.equal(authorize.searchParams.get("redirect_uri"), `${PRODUCTION}${CALLBACK}`);
  assert.equal(authorize.searchParams.get("client_id"), env.ZOOM_PUBLIC_CLIENT_ID);
  assert.ok(!authorize.href.includes("workers.dev"));
  const sealed = await handoff(authorize);
  const response = await local(post(PRODUCTION, "/v1/oauth/handoff", redemption(sealed)));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {code: CODE, redirect_uri: `${PRODUCTION}${CALLBACK}`, client_id: env.ZOOM_PUBLIC_CLIENT_ID});
});

test("development code flow uses its own canonical origin and public client", async () => {
  const env = environment(true);
  const authorize = await start(DEVELOPMENT, env);
  assert.equal(authorize.searchParams.get("redirect_uri"), `${DEVELOPMENT}${CALLBACK}`);
  assert.equal(authorize.searchParams.get("client_id"), env.ZOOM_PUBLIC_CLIENT_ID);
  const sealed = await handoff(authorize, DEVELOPMENT, env);
  const response = await local(post(DEVELOPMENT, "/v1/oauth/handoff", redemption(sealed, env)), env);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {code: CODE, redirect_uri: `${DEVELOPMENT}${CALLBACK}`, client_id: env.ZOOM_PUBLIC_CLIENT_ID});
});

test("known workers.dev aliases require updates for session and handoff without redirecting credentials", async () => {
  for (const development of [false, true]) {
    const env = environment(development);
    const canonical = development ? DEVELOPMENT : PRODUCTION;
    const legacy = development ? OLD_DEVELOPMENT : OLD_PRODUCTION;
    const authorize = await start(canonical, env);
    const sealed = await handoff(authorize, canonical, env);
    for (const path of ["/v1/oauth/session", "/v1/oauth/handoff"]) {
      const body = path.endsWith("session") ? sessionBody(env) : redemption(sealed, env);
      await expectError(await local(post(legacy, path, body), env), 410, "update_required");
    }
    await expectRestart(await local(new Request(callback(legacy, authorize)), env));
  }
});

test("unknown and cross-environment origins cannot be trusted through forwarded host headers", async () => {
  for (const origin of ["https://attacker.test", "https://auth.yap.enterprises.attacker.test", `${PRODUCTION}:8443`, DEVELOPMENT, OLD_DEVELOPMENT]) {
    for (const path of ["/v1/oauth/session", "/v1/oauth/handoff"]) {
      await expectError(await local(post(origin, path, sessionBody(), {Host: "auth.yap.enterprises", "X-Forwarded-Host": "auth.yap.enterprises",
        Forwarded: "host=auth.yap.enterprises;proto=https"})), 400, "invalid_service_origin");
    }
    await expectRestart(await local(new Request(`${origin}${CALLBACK}?state=invalid&code=code`)));
  }
});

test("sealed redirect binding rejects relocation even if another environment reused the same client and key", async () => {
  const authorize = await start();
  const sealed = await handoff(authorize);
  const relocated = {...environment(), ZOOM_OAUTH_REDIRECT_URI: `${DEVELOPMENT}${CALLBACK}`, ZOOM_OAUTH_LEGACY_REDIRECT_URIS: "[]"};
  await expectRestart(await local(new Request(callback(DEVELOPMENT, authorize)), relocated));
  await expectError(await local(post(DEVELOPMENT, "/v1/oauth/handoff", redemption(sealed, relocated)), relocated), 400, "invalid_oauth_session");
});

test("production envelopes cannot cross into the real development client and key", async () => {
  const authorize = await start();
  const sealed = await handoff(authorize);
  const env = environment(true);
  await expectRestart(await local(new Request(callback(DEVELOPMENT, authorize)), env));
  await expectError(await local(post(DEVELOPMENT, "/v1/oauth/handoff", redemption(sealed, env)), env), 400, "invalid_oauth_session");
  await expectError(await local(post(DEVELOPMENT, "/v1/oauth/session", sessionBody()), env), 400, "invalid_request");
});

test("invalid canonical callback configuration fails closed before creating an authorization session", async () => {
  for (const redirect of ["", "not-a-url", `http://auth.yap.enterprises${CALLBACK}`, `https://user:password@auth.yap.enterprises${CALLBACK}`,
    `${PRODUCTION}:8443${CALLBACK}`, `${PRODUCTION}/other/callback`, `${PRODUCTION}${CALLBACK}?extra=1`, `${PRODUCTION}${CALLBACK}#fragment`,
    `https://localhost${CALLBACK}`, `https://127.0.0.1${CALLBACK}`]) {
    const env = {...environment(), ZOOM_OAUTH_REDIRECT_URI: redirect};
    await expectError(await local(post(PRODUCTION, "/v1/oauth/session", sessionBody(env)), env), 503, "not_configured");
  }
});

test("invalid or ambiguous legacy origin configuration fails closed", async () => {
  for (const legacy of ["not-json", "null", "{}", JSON.stringify([`${PRODUCTION}${CALLBACK}`]),
    JSON.stringify([`${OLD_PRODUCTION}${CALLBACK}`, `${OLD_PRODUCTION}${CALLBACK}`]),
    JSON.stringify([`http://meeting-auth.mgrinich.workers.dev${CALLBACK}`]),
    JSON.stringify([null]), JSON.stringify(Array.from({length: 5}, (_, i) => `https://legacy-${i}.example.test${CALLBACK}`))]) {
    const env = {...environment(), ZOOM_OAUTH_LEGACY_REDIRECT_URIS: legacy};
    await expectError(await local(post(PRODUCTION, "/v1/oauth/session", sessionBody(env)), env), 503, "not_configured");
  }
});

test("retired token and signature compatibility routes stay retired on both canonical and legacy domains", async () => {
  for (const development of [false, true]) {
    const env = environment(development);
    for (const origin of development ? [DEVELOPMENT, OLD_DEVELOPMENT] : [PRODUCTION, OLD_PRODUCTION]) {
      for (const path of ["/v1/oauth/token", "/v1/meeting-sdk/signature"]) {
        await expectError(await local(post(origin, path, {client_id: env.ZOOM_PUBLIC_CLIENT_ID, grant_type: "refresh_token",
          refresh_token: "legacy-refresh-token", access_token: "legacy-access-token", signing_grant: "legacy-grant"}, {Authorization: "Bearer legacy-access-token"}), env), 410, "update_required");
      }
    }
  }
});

test("old in-flight callbacks offer a clean restart instead of reviving the old token flow", async () => {
  for (const origin of [PRODUCTION, OLD_PRODUCTION]) {
    for (const state of ["legacy-unsealed-state", "v1.old-iv.old-ciphertext"]) {
      const url = new URL(`${origin}${CALLBACK}`);
      url.search = new URLSearchParams({state, code: "old-authorization-code"}).toString();
      await expectRestart(await local(new Request(url)));
    }
  }
});
