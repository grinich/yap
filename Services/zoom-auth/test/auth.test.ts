import assert from "node:assert/strict";
import {test} from "node:test";
import {handleRequest} from "../src/index.ts";

const NOW = 1_800_000_000;
const SCOPES = "user:read:zak meeting:write:meeting cloud_recording:read:list_user_recordings";
function environment(): Env {
  return {
    ZOOM_PUBLIC_CLIENT_ID: "test-public-client", ZOOM_SDK_CLIENT_ID: "test-sdk-client",
    ZOOM_SDK_CLIENT_SECRET: "fake-test-sdk-secret", SIGNING_GRANT_SECRET: "fake-test-grant-secret-with-at-least-43-characters",
    REQUEST_LIMITER: {limit: async () => ({success: true})},
    SIGNATURE_LIMITER: {limit: async () => ({success: true})},
    ASSETS: {fetch: async () => new Response("Not found", {status: 404}), connect: () => { throw new Error("No sockets in asset tests"); }}
  };
}
const codeBody = () => ({grant_type: "authorization_code", client_id: "test-public-client",
  code: "fake-authorization-code", code_verifier: "v".repeat(43), redirect_uri: "http://127.0.0.1:53421/callback"});
const providerTokens = () => ({access_token: "fake-access", refresh_token: "fake-refresh", token_type: "bearer",
  expires_in: 3600, scope: SCOPES});
function post(path: string, body: unknown = {}, headers: Record<string, string> = {}): Request {
  return new Request(`https://auth.example.test${path}`, {method: "POST", headers: {"Content-Type": "application/json", ...headers}, body: JSON.stringify(body)});
}
function dependency(responder: (url: string, init: RequestInit) => Response | Promise<Response>, now = NOW) {
  return {now: () => now, fetch: (async (url: RequestInfo | URL, init?: RequestInit) => responder(String(url), init ?? {})) as typeof fetch};
}
const noNetwork = dependency(() => { assert.fail("must not contact Zoom"); });
async function obtainGrant(env = environment()): Promise<string> {
  const response = await handleRequest(post("/v1/oauth/token", codeBody()), env,
    dependency(() => Response.json(providerTokens())));
  assert.equal(response.status, 200);
  return ((await response.json()) as {signing_authorization: string}).signing_authorization;
}
function signatureRequest(grant: string, token = "fake-access") {
  return post("/v1/meeting-sdk/signature", {}, {Authorization: `Bearer ${token}`, "X-Signing-Authorization": grant});
}

test("PKCE exchange pins the public client, preserves verifier/redirect, and returns a bound grant", async () => {
  const response = await handleRequest(post("/v1/oauth/token", codeBody()), environment(), dependency((url, init) => {
    assert.equal(url, "https://zoom.us/oauth/token");
    assert.equal(init.method, "POST"); assert.equal(init.redirect, "error");
    const body = new URLSearchParams(String(init.body));
    assert.deepEqual(Object.fromEntries(body), codeBody());
    assert.equal(new Headers(init.headers).get("Authorization"), null);
    return Response.json(providerTokens());
  }));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  const body = await response.json() as Record<string, unknown>;
  assert.equal(body.access_token, "fake-access");
  assert.equal(typeof body.signing_authorization, "string");
  assert.equal(JSON.stringify(body).includes(environment().ZOOM_SDK_CLIENT_SECRET), false);
});

test("refresh exchange forwards only allowed fields and issues a fresh grant", async () => {
  const response = await handleRequest(post("/v1/oauth/token", {grant_type: "refresh_token", refresh_token: "old-refresh"}),
    environment(), dependency((url, init) => {
      assert.equal(url, "https://zoom.us/oauth/token");
      assert.deepEqual(Object.fromEntries(new URLSearchParams(String(init.body))), {
        client_id: "test-public-client", grant_type: "refresh_token", refresh_token: "old-refresh"
      });
      return Response.json({...providerTokens(), access_token: "rotated-access", refresh_token: "rotated-refresh"});
    }));
  assert.equal(response.status, 200);
  assert.equal((await response.json() as {refresh_token: string}).refresh_token, "rotated-refresh");
});

test("form-encoded native exchange is supported; duplicates are rejected", async () => {
  const form = new URLSearchParams(codeBody());
  const request = () => new Request("https://auth.example.test/v1/oauth/token", {method: "POST",
    headers: {"Content-Type": "application/x-www-form-urlencoded"}, body: form.toString()});
  assert.equal((await handleRequest(request(), environment(), dependency(() => Response.json(providerTokens())))).status, 200);
  form.append("client_id", "another-client");
  assert.equal((await handleRequest(request(), environment(), noNetwork)).status, 400);
});

for (const change of [
  {client_id: "other-app"}, {grant_type: "account_credentials"}, {client_secret: "injected"},
  {redirect_uri: "https://attacker.example/callback"}, {redirect_uri: "http://127.0.0.1.attacker.test:1234/callback"},
  {redirect_uri: "http://127.0.0.1:53421/callback?next=secret"}, {redirect_uri: "http://127.0.0.1:80/callback"},
  {redirect_uri: "http://127.0.0.1:65536/callback"}, {code_verifier: "short"}, {code: ""}
]) {
  test(`rejects malformed or cross-client exchange: ${Object.keys(change)[0]} ${Object.values(change)[0]}`, async () => {
    assert.equal((await handleRequest(post("/v1/oauth/token", {...codeBody(), ...change}), environment(), noNetwork)).status, 400);
  });
}

test("signer requires a grant issued for exactly this access token and app", async () => {
  const env = environment(); const grant = await obtainGrant(env);
  assert.equal((await handleRequest(signatureRequest(grant, "another-token"), env, noNetwork)).status, 401);
  assert.equal((await handleRequest(signatureRequest(grant), {...env, ZOOM_PUBLIC_CLIENT_ID: "another-app"}, noNetwork)).status, 401);
  assert.equal((await handleRequest(signatureRequest(grant), {...env, SIGNING_GRANT_SECRET: "another-key-that-is-at-least-43-characters-long"}, noNetwork)).status, 401);
});

test("signer verifies live authorization and signs a one-hour native SDK JWT", async () => {
  const env = environment(); const grant = await obtainGrant(env);
  const response = await handleRequest(signatureRequest(grant), env, dependency((url, init) => {
    assert.equal(url, "https://api.zoom.us/v2/users/me/zak");
    assert.equal(new Headers(init.headers).get("Authorization"), "Bearer fake-access");
    assert.equal(init.redirect, "error");
    return Response.json({token: "fake-zak"});
  }));
  assert.equal(response.status, 200);
  const result = await response.json() as {signature: string, expiresAt: number};
  const [header, payload, signature] = result.signature.split(".");
  assert.deepEqual(JSON.parse(Buffer.from(header, "base64url").toString()), {alg: "HS256", typ: "JWT"});
  assert.deepEqual(JSON.parse(Buffer.from(payload, "base64url").toString()), {
    appKey: env.ZOOM_SDK_CLIENT_ID, iat: NOW - 30, exp: NOW + 3570, tokenExp: NOW + 3570
  });
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(env.ZOOM_SDK_CLIENT_SECRET),
    {name: "HMAC", hash: "SHA-256"}, false, ["verify"]);
  assert.equal(await crypto.subtle.verify("HMAC", key, Buffer.from(signature, "base64url"), new TextEncoder().encode(`${header}.${payload}`)), true);
  assert.equal(result.expiresAt, NOW + 3570);
  assert.equal(JSON.stringify(result).includes("fake-zak"), false);
});

test("expired and tampered grants cannot mint SDK JWTs", async () => {
  const env = environment(); const grant = await obtainGrant(env);
  assert.equal((await handleRequest(signatureRequest(grant), env, {...noNetwork, now: () => NOW + 3600})).status, 401);
  const parts = grant.split(".");
  parts[1] = Buffer.from(JSON.stringify({exp: NOW + 7200})).toString("base64url");
  assert.equal((await handleRequest(signatureRequest(parts.join(".")), env, noNetwork)).status, 401);
  assert.equal((await handleRequest(signatureRequest("unsigned"), env, noNetwork)).status, 401);
});

test("revoked authorization cannot mint SDK JWTs and provider error text is not leaked", async () => {
  const env = environment(); const grant = await obtainGrant(env);
  const response = await handleRequest(signatureRequest(grant), env, dependency(() => new Response("private token detail", {status: 401})));
  assert.equal(response.status, 401);
  assert.equal(await response.text(), '{"error":"authorization_required"}');
});

test("missing scope and malformed provider responses fail closed", async () => {
  for (const update of [{scope: "user:read:zak"}, {expires_in: -1}, {access_token: ""}, {token_type: "basic"}]) {
    const response = await handleRequest(post("/v1/oauth/token", codeBody()), environment(),
      dependency(() => Response.json({...providerTokens(), ...update})));
    assert.equal(response.status, "scope" in update ? 403 : 502);
  }
});

test("rate limiting applies before provider requests and before SDK signing", async () => {
  const env = environment();
  const denied = {limit: async () => ({success: false})};
  const response = await handleRequest(post("/v1/oauth/token", codeBody()), {...env, REQUEST_LIMITER: denied}, noNetwork);
  assert.equal(response.status, 429); assert.equal(response.headers.get("Retry-After"), "60");
  const grant = await obtainGrant(env);
  assert.equal((await handleRequest(signatureRequest(grant), {...env, SIGNATURE_LIMITER: denied}, noNetwork)).status, 429);
});

test("oversized bodies, query credentials, and browser requests are rejected", async () => {
  assert.equal((await handleRequest(post("/v1/oauth/token", {code: "x".repeat(20_000)}), environment(), noNetwork)).status, 413);
  assert.equal((await handleRequest(post("/v1/oauth/token?code=secret", codeBody()), environment(), noNetwork)).status, 400);
  assert.equal((await handleRequest(post("/v1/oauth/token", codeBody(), {Origin: "https://attacker.test"}), environment(), noNetwork)).status, 403);
});

test("unconfigured deployment and unexpected endpoints cannot sign", async () => {
  assert.equal((await handleRequest(post("/v1/oauth/token", codeBody()), {...environment(), ZOOM_PUBLIC_CLIENT_ID: ""}, noNetwork)).status, 503);
  assert.equal((await handleRequest(post("/arbitrary-proxy", codeBody()), environment(), noNetwork)).status, 404);
  assert.equal((await handleRequest(new Request("https://auth.example.test/v1/meeting-sdk/signature"), environment(), noNetwork)).status, 405);
  assert.equal((await handleRequest(post("/v1/meeting-sdk/signature"), environment(), noNetwork)).status, 401);
});

test("upstream network errors and oversized responses expose no credentials", async () => {
  const response = await handleRequest(post("/v1/oauth/token", codeBody()), environment(),
    dependency(() => { throw new Error("fake-refresh-token should never appear"); }));
  assert.equal(response.status, 502);
  assert.equal(await response.text(), '{"error":"zoom_unavailable"}');
  const oversized = await handleRequest(post("/v1/oauth/token", codeBody()), environment(),
    dependency(() => new Response("x".repeat(70_000))));
  assert.equal(oversized.status, 502);
});

test("public documents use the asset binding while API routes remain protected", async () => {
  const env = environment();
  env.ASSETS.fetch = async () => new Response("Public documentation");
  assert.equal(await (await handleRequest(new Request("https://auth.example.test/privacy/"), env, noNetwork)).text(), "Public documentation");
  assert.equal((await handleRequest(post("/v1/meeting-sdk/signature"), env, noNetwork)).status, 401);
});
