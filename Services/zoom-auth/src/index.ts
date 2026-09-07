const TOKEN_URL = "https://zoom.us/oauth/token";
const ZAK_URL = "https://api.zoom.us/v2/users/me/zak";
const MAX_REQUEST_BYTES = 16_384;
const MAX_RESPONSE_BYTES = 65_536;
const SIGNATURE_PATH = "/v1/meeting-sdk/signature";
const TOKEN_PATH = "/v1/oauth/token";
const encoder = new TextEncoder();
const requiredScopes = ["user:read:zak", "meeting:write:meeting", "cloud_recording:read:list_user_recordings"];

type Dependencies = {
  fetch: typeof fetch;
  now: () => number;
};
const liveDependencies: Dependencies = {fetch: (...args) => fetch(...args), now: () => Math.floor(Date.now() / 1000)};

class RequestFailure extends Error {
  readonly status: number;
  readonly code: string;
  constructor(status: number, code: string) { super(code); this.status = status; this.code = code; }
}

function json(value: unknown, status = 200): Response {
  return Response.json(value, {status, headers: {
    "Cache-Control": "no-store", "Pragma": "no-cache", "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer", ...(status === 429 ? {"Retry-After": "60"} : {})
  }});
}

function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new RequestFailure(400, "invalid_request");
  return value as Record<string, unknown>;
}

function credential(value: unknown, maximum = 16_384): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= maximum && !/\s/.test(value);
}

async function boundedText(body: Request | Response, maximum: number): Promise<string> {
  const declared = body.headers.get("Content-Length");
  if (declared && (!/^\d+$/.test(declared) || Number(declared) > maximum)) {
    await body.body?.cancel();
    throw new RequestFailure(413, "payload_too_large");
  }
  if (!body.body) return "";
  const reader = body.body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      length += next.value.byteLength;
      if (length > maximum) {
        await reader.cancel();
        throw new RequestFailure(413, "payload_too_large");
      }
      chunks.push(next.value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return new TextDecoder("utf-8", {fatal: true, ignoreBOM: false}).decode(bytes);
}

async function parameters(request: Request): Promise<Record<string, unknown>> {
  const type = request.headers.get("Content-Type")?.split(";")[0].trim().toLowerCase();
  const text = await boundedText(request, MAX_REQUEST_BYTES);
  if (type === "application/json") {
    try { return object(JSON.parse(text)); }
    catch { throw new RequestFailure(400, "invalid_request"); }
  }
  if (type === "application/x-www-form-urlencoded") {
    const result: Record<string, string> = Object.create(null);
    for (const [key, value] of new URLSearchParams(text)) {
      if (Object.hasOwn(result, key)) throw new RequestFailure(400, "invalid_request");
      result[key] = value;
    }
    return result;
  }
  throw new RequestFailure(415, "unsupported_media_type");
}

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}
function decodeBase64url(text: string): Uint8Array<ArrayBuffer> {
  if (!/^[A-Za-z0-9_-]+$/.test(text)) throw new RequestFailure(401, "invalid_signing_authorization");
  try { return Uint8Array.from(atob(text.replaceAll("-", "+").replaceAll("_", "/")), c => c.charCodeAt(0)); }
  catch { throw new RequestFailure(401, "invalid_signing_authorization"); }
}
async function digest(text: string): Promise<string> {
  return base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(text))));
}
async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", encoder.encode(secret), {name: "HMAC", hash: "SHA-256"}, false, ["sign", "verify"]);
}
async function signed(payload: Record<string, unknown>, secret: string, type: string): Promise<string> {
  const header = base64url(encoder.encode(JSON.stringify({alg: "HS256", typ: type})));
  const claims = base64url(encoder.encode(JSON.stringify(payload)));
  const message = `${header}.${claims}`;
  const signature = await crypto.subtle.sign("HMAC", await hmacKey(secret), encoder.encode(message));
  return `${message}.${base64url(new Uint8Array(signature))}`;
}

async function verifyAuthorization(grant: string, token: string, env: Env, now: number): Promise<string> {
  const fail = () => new RequestFailure(401, "invalid_signing_authorization");
  if (grant.length > 4096) throw fail();
  const parts = grant.split(".");
  if (parts.length !== 3) throw fail();
  const [header, payload, signature] = parts;
  const valid = await crypto.subtle.verify("HMAC", await hmacKey(env.SIGNING_GRANT_SECRET),
    decodeBase64url(signature), encoder.encode(`${header}.${payload}`));
  if (!valid) throw fail();
  try {
    const h = object(JSON.parse(new TextDecoder().decode(decodeBase64url(header))));
    const p = object(JSON.parse(new TextDecoder().decode(decodeBase64url(payload))));
    const tokenHash = await digest(token);
    if (h.alg !== "HS256" || h.typ !== "meeting-signing-grant" || p.aud !== env.ZOOM_PUBLIC_CLIENT_ID ||
        p.token_sha256 !== tokenHash || !Number.isInteger(p.exp) || !Number.isInteger(p.iat) ||
        Number(p.exp) <= now || Number(p.iat) > now + 30 || Number(p.exp) - Number(p.iat) > 3600 ||
        Number(p.exp) <= Number(p.iat)) throw fail();
    return tokenHash;
  } catch { throw fail(); }
}

async function zoomRequest(url: string, init: RequestInit, deps: Dependencies): Promise<Record<string, unknown>> {
  let response: Response;
  // workerd rejects redirect: "error" before sending the request. Manual mode
  // keeps credentials at the pinned endpoint; the non-OK guard also rejects 3xx.
  try { response = await deps.fetch(url, {...init, redirect: "manual", signal: AbortSignal.timeout(15_000)}); }
  catch { throw new RequestFailure(502, "zoom_unavailable"); }
  if (!response.ok) {
    await response.body?.cancel();
    if (response.status === 429) throw new RequestFailure(429, "rate_limited");
    if (response.status === 401 || response.status === 400) throw new RequestFailure(401, "authorization_required");
    if (response.status === 403) throw new RequestFailure(403, "authorization_denied");
    throw new RequestFailure(502, "zoom_unavailable");
  }
  try { return object(JSON.parse(await boundedText(response, MAX_RESPONSE_BYTES))); }
  catch { throw new RequestFailure(502, "invalid_zoom_response"); }
}

async function exchange(request: Request, env: Env, deps: Dependencies): Promise<Response> {
  const input = await parameters(request);
  if (input.client_id !== undefined && input.client_id !== env.ZOOM_PUBLIC_CLIENT_ID) {
    throw new RequestFailure(400, "invalid_client");
  }
  const fields = new URLSearchParams({client_id: env.ZOOM_PUBLIC_CLIENT_ID});
  let allowed: string[];
  if (input.grant_type === "authorization_code") {
    allowed = ["grant_type", "client_id", "code", "code_verifier", "redirect_uri"];
    if (!credential(input.code) || typeof input.code_verifier !== "string" ||
        !/^[A-Za-z0-9._~-]{43,128}$/.test(input.code_verifier) || typeof input.redirect_uri !== "string" ||
        !/^http:\/\/127\.0\.0\.1:[0-9]{1,5}\/callback$/.test(input.redirect_uri)) {
      throw new RequestFailure(400, "invalid_request");
    }
    let port: number;
    try { port = Number(new URL(input.redirect_uri).port); }
    catch { throw new RequestFailure(400, "invalid_redirect_uri"); }
    if (port < 1024 || port > 65535) throw new RequestFailure(400, "invalid_redirect_uri");
    fields.set("code", input.code);
    fields.set("code_verifier", input.code_verifier);
    fields.set("redirect_uri", input.redirect_uri);
  } else if (input.grant_type === "refresh_token") {
    allowed = ["grant_type", "client_id", "refresh_token"];
    if (!credential(input.refresh_token)) throw new RequestFailure(400, "invalid_request");
    fields.set("refresh_token", input.refresh_token);
  } else { throw new RequestFailure(400, "unsupported_grant_type"); }
  if (Object.keys(input).some(key => !allowed.includes(key))) throw new RequestFailure(400, "invalid_request");
  fields.set("grant_type", input.grant_type);
  const token = await zoomRequest(TOKEN_URL, {method: "POST", headers: {
    "Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"
  }, body: fields.toString()}, deps);
  if (!credential(token.access_token) || !credential(token.refresh_token) ||
      typeof token.token_type !== "string" || token.token_type.toLowerCase() !== "bearer" ||
      !Number.isInteger(token.expires_in) || Number(token.expires_in) < 60 || Number(token.expires_in) > 86_400 ||
      typeof token.scope !== "string" || token.scope.length > 8192) throw new RequestFailure(502, "invalid_zoom_response");
  const scopes = new Set(token.scope.split(/\s+/));
  if (!requiredScopes.every(scope => scopes.has(scope))) throw new RequestFailure(403, "missing_scope");
  const now = deps.now();
  const lifetime = Math.min(Number(token.expires_in), 3600);
  const grant = await signed({aud: env.ZOOM_PUBLIC_CLIENT_ID, token_sha256: await digest(token.access_token),
    iat: now, exp: now + lifetime}, env.SIGNING_GRANT_SECRET, "meeting-signing-grant");
  return json({access_token: token.access_token, refresh_token: token.refresh_token, token_type: "bearer",
    expires_in: lifetime, scope: token.scope, signing_authorization: grant});
}

async function signature(request: Request, env: Env, deps: Dependencies): Promise<Response> {
  const bearer = request.headers.get("Authorization");
  const grant = request.headers.get("X-Signing-Authorization");
  if (!bearer?.startsWith("Bearer ") || !credential(bearer.slice(7)) || !credential(grant, 4096)) {
    throw new RequestFailure(401, "authorization_required");
  }
  const token = bearer.slice(7);
  const tokenHash = await verifyAuthorization(grant, token, env, deps.now());
  if (!(await env.SIGNATURE_LIMITER.limit({key: tokenHash})).success) throw new RequestFailure(429, "rate_limited");
  const body = await parameters(request);
  if (Object.keys(body).length !== 0) throw new RequestFailure(400, "invalid_request");
  // A fresh provider check prevents issuance after the user revokes authorization.
  const zak = await zoomRequest(ZAK_URL, {headers: {Authorization: `Bearer ${token}`, Accept: "application/json"}}, deps);
  if (!credential(zak.token)) throw new RequestFailure(502, "invalid_zoom_response");
  const issued = deps.now() - 30;
  const expiresAt = issued + 3600;
  return json({signature: await signed({appKey: env.ZOOM_SDK_CLIENT_ID, iat: issued, exp: expiresAt, tokenExp: expiresAt},
    env.ZOOM_SDK_CLIENT_SECRET, "JWT"), expiresAt});
}

export async function handleRequest(request: Request, env: Env, deps = liveDependencies): Promise<Response> {
  try {
    const url = new URL(request.url);
    if (url.protocol !== "https:" && url.hostname !== "localhost" && url.hostname !== "127.0.0.1") {
      throw new RequestFailure(400, "https_required");
    }
    // Credentials belong in POST bodies/headers. Never accept query parameters.
    if (url.search) throw new RequestFailure(400, "invalid_request");
    if (url.pathname === "/health" && request.method === "GET") return json({status: "ok"});
    if (url.pathname !== TOKEN_PATH && url.pathname !== SIGNATURE_PATH) {
      throw new RequestFailure(404, "not_found");
    }
    if (request.method !== "POST") throw new RequestFailure(405, "method_not_allowed");
    if (request.headers.has("Origin")) throw new RequestFailure(403, "native_client_required");
    if (!credential(env.ZOOM_PUBLIC_CLIENT_ID, 1024) || !credential(env.ZOOM_SDK_CLIENT_ID, 1024) ||
        !credential(env.ZOOM_SDK_CLIENT_SECRET, 1024) || !credential(env.SIGNING_GRANT_SECRET, 1024) ||
        env.SIGNING_GRANT_SECRET.length < 43) throw new RequestFailure(503, "not_configured");
    const source = request.headers.get("CF-Connecting-IP") ?? "local";
    const key = await digest(source);
    if (!(await env.REQUEST_LIMITER.limit({key})).success) throw new RequestFailure(429, "rate_limited");
    return url.pathname === TOKEN_PATH ? await exchange(request, env, deps) : await signature(request, env, deps);
  } catch (error) {
    if (error instanceof RequestFailure) return json({error: error.code}, error.status);
    // Do not log exception text: upstream/network errors may contain credentials.
    console.error(JSON.stringify({event: "auth_service_failure"}));
    return json({error: "service_unavailable"}, 503);
  }
}

export default {
  fetch(request: Request, env: Env): Promise<Response> { return handleRequest(request, env); }
};
