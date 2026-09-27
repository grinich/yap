import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import test from "node:test";
import {handleRequest} from "../src/index.ts";

const ORIGIN = "https://auth.example.test";
const NOW = 1_800_000_000;
const hash = (value: string) => createHash("sha256").update(value).digest("base64url");
function environment(): Env {
  return {
    ZOOM_PUBLIC_CLIENT_ID: "test-public-client",
    ZOOM_OAUTH_REDIRECT_URI: `${ORIGIN}/oauth/zoom/callback`,
    ZOOM_OAUTH_LEGACY_REDIRECT_URIS: "[]",
    SIGNING_GRANT_SECRET: "test-only-envelope-secret-which-is-at-least-43-characters",
    REQUEST_LIMITER: {limit: async () => ({success: true})}
  };
}
function sessionBody(): Record<string, unknown> {
  return {client_id: environment().ZOOM_PUBLIC_CLIENT_ID, code_challenge: hash("v".repeat(43)),
    code_challenge_method: "S256", handoff_challenge: hash("h".repeat(43)), state: "n".repeat(43)};
}
function post(path: string, body: unknown, headers: Record<string, string> = {}): Request {
  return new Request(`${ORIGIN}${path}`, {method: "POST", headers: {"Content-Type": "application/json", ...headers}, body: JSON.stringify(body)});
}
async function local(request: Request, env = environment()): Promise<Response> {
  let calls = 0;
  const response = await handleRequest(request, env, {now: () => NOW, fetch: (async () => {
    calls++;
    return Response.json({access_token: "must-never-be-returned", refresh_token: "must-never-be-returned"});
  }) as typeof fetch});
  // Check after the handler returns, so its exception handling cannot hide an outbound call.
  assert.equal(calls, 0, "the code-only service must never call an upstream service");
  return response;
}
async function expectError(response: Response, status: number, error?: string): Promise<void> {
  assert.equal(response.status, status);
  const body = await response.json() as {error: string};
  assert.deepEqual(Object.keys(body), ["error"]);
  if (error) assert.equal(body.error, error);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  assert.equal(response.headers.get("Location"), null);
}

test("retired token and SDK signature routes reject every legacy grant without reading credentials", async () => {
  for (const path of ["/v1/oauth/token", "/v1/meeting-sdk/signature"]) {
    for (const body of [undefined, "{invalid", "", JSON.stringify({grant_type: "authorization_code", code: "old-code", code_verifier: "old-verifier"}),
      JSON.stringify({grant_type: "refresh_token", refresh_token: "old-refresh-token"}),
      JSON.stringify({handoff: "old-handoff", signing_grant: "old-grant", access_token: "old-access-token"}), "x".repeat(20_000)]) {
      const request = new Request(`${ORIGIN}${path}?access_token=old-query-token`, {method: "POST", body,
        headers: {"Content-Type": "application/json", Authorization: "Bearer old-token", Origin: "https://example.test"}});
      await expectError(await local(request), 410, "update_required");
    }
    for (const method of ["GET", "HEAD", "OPTIONS"]) {
      await expectError(await local(new Request(`${ORIGIN}${path}`, {method})), 410, "update_required");
    }
    // Retirement is independent of missing configuration and unavailable rate-limit bindings.
    await expectError(await local(post(path, {}), {} as Env), 410, "update_required");
  }
});

test("old session requests containing an OAuth verifier require an app update", async () => {
  for (const body of [{client_id: "old-confidential-client", code_verifier: "v".repeat(43)},
    {...sessionBody(), code_verifier: "v".repeat(43)}, {...sessionBody(), code_verifier: null}]) {
    await expectError(await local(post("/v1/oauth/session", body)), 410, "update_required");
  }
});

test("session creation returns only a short-lived authorization URL with private response headers", async () => {
  const response = await local(post("/v1/oauth/session", sessionBody()));
  assert.equal(response.status, 200);
  const body = await response.json() as {authorize_url: string; expires_in: number};
  assert.deepEqual(Object.keys(body).sort(), ["authorize_url", "expires_in"]);
  assert.equal(body.expires_in, 180);
  assert.equal(new URL(body.authorize_url).hostname, "zoom.us");
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  assert.equal(response.headers.get("Pragma"), "no-cache");
  assert.equal(response.headers.get("Referrer-Policy"), "no-referrer");
  assert.equal(response.headers.get("X-Content-Type-Options"), "nosniff");
});

test("form sessions accept the public contract and reject duplicate fields", async () => {
  const body = new URLSearchParams(sessionBody() as Record<string, string>);
  const request = (value: URLSearchParams) => new Request(`${ORIGIN}/v1/oauth/session`, {method: "POST", body: value});
  assert.equal((await local(request(body))).status, 200);
  for (const [key, value] of body) {
    const duplicate = new URLSearchParams(body);
    duplicate.append(key, value);
    await expectError(await local(request(duplicate)), 400, "invalid_request");
  }
});

test("session JSON must be an object and the media type must be supported", async () => {
  for (const body of ["", "{bad", "null", "[]", '"string"', "42", "true"]) {
    const response = await local(new Request(`${ORIGIN}/v1/oauth/session`, {method: "POST", body, headers: {"Content-Type": "application/json"}}));
    await expectError(response, 400, "invalid_request");
  }
  for (const type of ["text/plain", "application/octet-stream"]) {
    await expectError(await local(new Request(`${ORIGIN}/v1/oauth/session`, {method: "POST", body: "{}", headers: {"Content-Type": type}})), 415, "unsupported_media_type");
  }
});

test("session validation rejects missing, unexpected, malformed, and wrong-client parameters", async () => {
  const invalid: Record<string, unknown>[] = [];
  for (const key of Object.keys(sessionBody())) {
    const body = sessionBody(); delete body[key]; invalid.push(body);
  }
  for (const change of [{client_id: "another-public-client"}, {client_id: ""}, {client_secret: "secret"},
    {redirect_uri: "https://attacker.test/callback"}, {access_token: "token"}, {code_challenge_method: "plain"},
    {code_challenge_method: "s256"}, ...["code_challenge", "handoff_challenge", "state"].flatMap(key =>
      ["x".repeat(42), "x".repeat(44), "=".repeat(43), " ".repeat(43), null, 43].map(value => ({[key]: value})))]) {
    invalid.push({...sessionBody(), ...change});
  }
  for (const body of invalid) await expectError(await local(post("/v1/oauth/session", body)), 400, "invalid_request");
});

test("OAuth and handoff proofs must differ while the public state remains an independent nonce field", async () => {
  const body = sessionBody();
  await expectError(await local(post("/v1/oauth/session", {...body, handoff_challenge: body.code_challenge})), 400, "invalid_request");
  // State is public correlation data, not a third secret or a proof of possession.
  assert.equal((await local(post("/v1/oauth/session", {...body, state: body.code_challenge}))).status, 200);
});

test("native endpoints reject browser origins, query credentials, insecure transport, and wrong methods", async () => {
  for (const path of ["/v1/oauth/session", "/v1/oauth/handoff"]) {
    for (const origin of ["https://attacker.test", "null"]) {
      await expectError(await local(post(path, sessionBody(), {Origin: origin})), 403, "native_client_required");
    }
    await expectError(await local(post(`${path}?access_token=token`, sessionBody())), 400, "invalid_request");
    await expectError(await local(new Request(`${ORIGIN}${path}`)), 405, "method_not_allowed");
    await expectError(await local(new Request(`http://auth.example.test${path}`, {method: "POST"})), 400, "https_required");
  }
  await expectError(await local(post("/oauth/zoom/callback", {})), 405, "method_not_allowed");
});

test("body limits apply to actual bytes and invalid or excessive declared lengths", async () => {
  for (const path of ["/v1/oauth/session", "/v1/oauth/handoff"]) {
    await expectError(await local(new Request(`${ORIGIN}${path}`, {method: "POST", headers: {"Content-Type": "application/json"}, body: "x".repeat(16_385)})), 413, "payload_too_large");
    for (const length of ["16385", "-1", "not-a-number"]) {
      await expectError(await local(post(path, sessionBody(), {"Content-Length": length})), 413, "payload_too_large");
    }
  }
});

test("all active authorization routes rate limit by hashed client address", async () => {
  const keys: string[] = [];
  const env = environment();
  env.REQUEST_LIMITER = {limit: async ({key}) => {keys.push(key); return {success: false};}};
  for (const path of ["/v1/oauth/session", "/v1/oauth/handoff", "/oauth/zoom/callback"]) {
    const request = path.includes("callback") ? new Request(`${ORIGIN}${path}`, {headers: {"CF-Connecting-IP": "203.0.113.7"}})
      : post(path, sessionBody(), {"CF-Connecting-IP": "203.0.113.7"});
    const response = await local(request, env);
    assert.equal(response.headers.get("Retry-After"), "60");
    await expectError(response, 429, "rate_limited");
  }
  assert.deepEqual(keys, Array(3).fill(hash("203.0.113.7")));
});

test("missing or malformed server configuration fails closed", async () => {
  for (const change of [{ZOOM_PUBLIC_CLIENT_ID: ""}, {ZOOM_PUBLIC_CLIENT_ID: "bad client"},
    {SIGNING_GRANT_SECRET: "short"}, {SIGNING_GRANT_SECRET: " ".repeat(43)}]) {
    await expectError(await local(post("/v1/oauth/session", sessionBody()), {...environment(), ...change}), 503, "not_configured");
  }
});

test("health and connect remain public while unknown paths never become a credential proxy", async () => {
  const response = await local(new Request(`${ORIGIN}/health`));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {status: "ok"});
  assert.equal((await local(new Request(`${ORIGIN}/connect`))).status, 200);
  for (const path of ["/v1/users/me", "/oauth/token", "/v1/oauth/refresh", "/.env"]) {
    for (const method of ["GET", "POST", "HEAD"]) {
      await expectError(await local(new Request(`${ORIGIN}${path}`, {method})), 404, "not_found");
    }
  }
});
