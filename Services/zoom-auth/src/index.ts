import {connectionLandingPage} from "./landing.ts";

const MAX_REQUEST_BYTES = 16_384;
const MAX_ENVELOPE_BYTES = 12_000;
const SIGNATURE_PATH = "/v1/meeting-sdk/signature";
const TOKEN_PATH = "/v1/oauth/token";
const SESSION_PATH = "/v1/oauth/session";
const CALLBACK_PATH = "/oauth/zoom/callback";
const HANDOFF_PATH = "/v1/oauth/handoff";
const SESSION_SECONDS = 180;
const encoder = new TextEncoder();

type Dependencies = {
  // Legacy test seam: regression tests supply a rejecting spy. The code-only
  // relay performs no outbound requests, including on retired routes.
  fetch?: typeof fetch;
  now: () => number;
};
const liveDependencies: Dependencies = {now: () => Math.floor(Date.now() / 1000)};

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
  try { return new TextDecoder("utf-8", {fatal: true, ignoreBOM: false}).decode(bytes); }
  catch { throw new RequestFailure(400, "invalid_request"); }
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
  if (!/^[A-Za-z0-9_-]+$/.test(text)) throw new RequestFailure(400, "invalid_oauth_session");
  try { return Uint8Array.from(atob(text.replaceAll("-", "+").replaceAll("_", "/")), c => c.charCodeAt(0)); }
  catch { throw new RequestFailure(400, "invalid_oauth_session"); }
}
async function digest(text: string): Promise<string> {
  return base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(text))));
}
async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", encoder.encode(secret), {name: "HMAC", hash: "SHA-256"}, false, ["sign", "verify"]);
}
function configuredRedirect(value: unknown): URL {
  if (typeof value !== "string" || value.length > 2048) throw new RequestFailure(503, "not_configured");
  let redirect: URL;
  try { redirect = new URL(value); }
  catch { throw new RequestFailure(503, "not_configured"); }
  if (redirect.protocol !== "https:" || !redirect.hostname.includes(".") ||
      redirect.username || redirect.password || redirect.port || redirect.search || redirect.hash ||
      redirect.pathname !== CALLBACK_PATH || redirect.hostname === "127.0.0.1") {
    throw new RequestFailure(503, "not_configured");
  }
  return redirect;
}

function redirectForRequest(url: URL, env: Env): URL {
  const canonical = configuredRedirect(env.ZOOM_OAUTH_REDIRECT_URI);
  let legacy: unknown;
  try { legacy = JSON.parse(env.ZOOM_OAUTH_LEGACY_REDIRECT_URIS); }
  catch { throw new RequestFailure(503, "not_configured"); }
  if (!Array.isArray(legacy) || legacy.length > 4) throw new RequestFailure(503, "not_configured");
  const redirects = [canonical, ...legacy.map(configuredRedirect)];
  if (new Set(redirects.map(redirect => redirect.origin)).size !== redirects.length) {
    throw new RequestFailure(503, "not_configured");
  }
  // New authorizations always use the branded origin. Older clients cannot
  // continue their retired token-proxy flow through a workers.dev alias.
  if (url.origin === canonical.origin) return canonical;
  if (redirects.some(redirect => redirect.origin === url.origin)) throw new RequestFailure(410, "update_required");
  throw new RequestFailure(400, "invalid_service_origin");
}

function verifier(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9._~-]{43,128}$/.test(value);
}

function nonce(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9_-]{43}$/.test(value);
}

// The native OAuth verifier never reaches this service. These authenticated
// envelopes carry only a short-lived authorization code and public challenges;
// they are not proof of successful Zoom authorization. Only Zoom can redeem
// the code, using the separate PKCE verifier retained by the native app.
async function envelopeKey(secret: string, purpose: string): Promise<CryptoKey> {
  const material = await crypto.subtle.digest("SHA-256", encoder.encode(`yap-oauth-v2:${purpose}:${secret}`));
  return crypto.subtle.importKey("raw", material, "AES-GCM", false, ["encrypt", "decrypt"]);
}

async function seal(payload: Record<string, unknown>, env: Env, purpose: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = await crypto.subtle.encrypt({name: "AES-GCM", iv, additionalData: encoder.encode(purpose)},
    await envelopeKey(env.SIGNING_GRANT_SECRET, purpose), encoder.encode(JSON.stringify(payload)));
  return `v2.${base64url(iv)}.${base64url(new Uint8Array(encrypted))}`;
}

async function unseal(value: unknown, env: Env, purpose: string, now: number): Promise<Record<string, unknown>> {
  const fail = () => new RequestFailure(400, "invalid_oauth_session");
  if (!credential(value, MAX_ENVELOPE_BYTES)) throw fail();
  const parts = value.split(".");
  if (parts.length !== 3 || parts[0] !== "v2") throw fail();
  try {
    const iv = decodeBase64url(parts[1]);
    if (iv.length !== 12) throw fail();
    const plaintext = await crypto.subtle.decrypt({name: "AES-GCM", iv, additionalData: encoder.encode(purpose)},
      await envelopeKey(env.SIGNING_GRANT_SECRET, purpose), decodeBase64url(parts[2]));
    const payload = object(JSON.parse(new TextDecoder().decode(plaintext)));
    if (payload.aud !== env.ZOOM_PUBLIC_CLIENT_ID || !nonce(payload.nonce) ||
        !Number.isInteger(payload.iat) || !Number.isInteger(payload.exp) ||
        Number(payload.iat) > now + 30 || Number(payload.exp) <= now ||
        Number(payload.exp) <= Number(payload.iat) || Number(payload.exp) - Number(payload.iat) > SESSION_SECONDS) throw fail();
    return payload;
  } catch { throw fail(); }
}

async function createSession(request: Request, redirect: URL, env: Env, deps: Dependencies): Promise<Response> {
  const input = await parameters(request);
  if (Object.hasOwn(input, "code_verifier")) throw new RequestFailure(410, "update_required");
  if (input.client_id !== env.ZOOM_PUBLIC_CLIENT_ID || !nonce(input.code_challenge) ||
      input.code_challenge_method !== "S256" || !nonce(input.handoff_challenge) ||
      input.code_challenge === input.handoff_challenge || !nonce(input.state) ||
      Object.keys(input).some(key => !["client_id", "code_challenge", "code_challenge_method", "handoff_challenge", "state"].includes(key))) {
    throw new RequestFailure(400, "invalid_request");
  }
  const now = deps.now();
  const state = await seal({aud: env.ZOOM_PUBLIC_CLIENT_ID, nonce: input.state,
    code_challenge: input.code_challenge, handoff_challenge: input.handoff_challenge,
    redirect: redirect.href, iat: now, exp: now + SESSION_SECONDS}, env, "authorization-session");
  const url = new URL("https://zoom.us/oauth/authorize");
  url.search = new URLSearchParams({client_id: env.ZOOM_PUBLIC_CLIENT_ID, response_type: "code",
    redirect_uri: redirect.href, state, code_challenge: input.code_challenge, code_challenge_method: "S256"}).toString();
  return json({authorize_url: url.href, expires_in: SESSION_SECONDS});
}

function completionPage(returnURL?: URL, denied = false, status = 200): Response {
  const title = denied ? "Zoom sign-in wasn’t completed" : returnURL ? "Return to Yap" : "Start sign-in again";
  const detail = denied ? "Open Yap to try again when you’re ready." : returnURL
    ? "Finish connecting your Zoom account in Yap." : "This sign-in link is invalid or has expired. Open Yap and choose Sign in to Zoom again.";
  const escaped = returnURL?.href.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
  return new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><title>${title} · Yap</title><style>body{font:17px system-ui,sans-serif;color:#222;background:#fafafa;display:grid;place-items:center;min-height:90vh;margin:24px}main{max-width:440px;text-align:center}h1{font-size:32px}p{line-height:1.5;color:#555}a{display:inline-block;margin-top:12px;padding:12px 22px;background:#222;color:#fff;border-radius:12px;text-decoration:none}</style><main><h1>${title}</h1><p>${detail}</p><a href="${escaped ?? "yap://open"}">Open Yap</a><p>You can close this window after returning to Yap.</p></main></html>`, {status, headers: {
    "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", "Pragma": "no-cache",
    "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY",
    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
  }});
}

async function completeAuthorization(request: Request, redirect: URL, env: Env, deps: Dependencies): Promise<Response> {
  const url = new URL(request.url);
  if (url.origin !== redirect.origin || url.pathname !== redirect.pathname) return completionPage(undefined, false, 400);
  const query = url.searchParams;
  if (request.url.length > 8192 || query.getAll("state").length !== 1 || query.getAll("code").length > 1 ||
      query.getAll("error").length > 1 || (query.has("code") && query.has("error"))) return completionPage(undefined, false, 400);
  let session: Record<string, unknown>;
  try { session = await unseal(query.get("state"), env, "authorization-session", deps.now()); }
  catch { return completionPage(undefined, false, 400); }
  if (session.redirect !== redirect.href || !nonce(session.code_challenge) || !nonce(session.handoff_challenge)) {
    return completionPage(undefined, false, 400);
  }
  const returnURL = new URL("yap://oauth/zoom");
  returnURL.searchParams.set("state", String(session.nonce));
  if (query.has("error")) {
    returnURL.searchParams.set("error", "access_denied");
    return completionPage(returnURL, true);
  }
  const code = query.get("code");
  if (typeof code !== "string" || !/^[!-~]{1,4096}$/.test(code)) return completionPage(undefined, false, 400);
  // No token endpoint call occurs here. A forged callback can only yield a code
  // that Zoom will reject; this envelope never authorizes SDK signing or APIs.
  const handoff = await seal({aud: env.ZOOM_PUBLIC_CLIENT_ID, nonce: session.nonce,
    handoff_challenge: session.handoff_challenge, code, redirect: redirect.href,
    iat: session.iat, exp: session.exp}, env, "native-code-handoff");
  returnURL.searchParams.set("handoff", handoff);
  return completionPage(returnURL);
}

async function redeemHandoff(request: Request, redirect: URL, env: Env, deps: Dependencies): Promise<Response> {
  const input = await parameters(request);
  if (input.client_id !== env.ZOOM_PUBLIC_CLIENT_ID || !verifier(input.handoff_verifier) || !nonce(input.state) ||
      Object.keys(input).some(key => !["client_id", "handoff", "handoff_verifier", "state"].includes(key))) {
    throw new RequestFailure(400, "invalid_request");
  }
  const payload = await unseal(input.handoff, env, "native-code-handoff", deps.now());
  if (!nonce(payload.handoff_challenge) || payload.nonce !== input.state || payload.redirect !== redirect.href ||
      typeof payload.code !== "string" || !/^[!-~]{1,4096}$/.test(payload.code)) {
    throw new RequestFailure(400, "invalid_oauth_session");
  }
  // Use Web Crypto verification for the independent handoff proof. The actual
  // PKCE verifier goes only from the native app to Zoom, never to this Worker.
  const key = await hmacKey(env.SIGNING_GRANT_SECRET);
  const expected = await crypto.subtle.sign("HMAC", key, encoder.encode(payload.handoff_challenge));
  const valid = await crypto.subtle.verify("HMAC", key, expected, encoder.encode(await digest(input.handoff_verifier)));
  if (!valid) throw new RequestFailure(400, "invalid_oauth_session");
  return json({code: payload.code, redirect_uri: redirect.href, client_id: env.ZOOM_PUBLIC_CLIENT_ID});
}

export async function handleRequest(request: Request, env: Env, deps = liveDependencies): Promise<Response> {
  try {
    const url = new URL(request.url);
    if (url.protocol !== "https:" && url.hostname !== "localhost" && url.hostname !== "127.0.0.1") {
      throw new RequestFailure(400, "https_required");
    }
    // Retire every proxy grant and SDK signer before reading credentials or
    // bodies. Old clients must update and explicitly authorize the public app.
    if ([TOKEN_PATH, SIGNATURE_PATH].includes(url.pathname)) throw new RequestFailure(410, "update_required");
    if (url.search && url.pathname !== CALLBACK_PATH) throw new RequestFailure(400, "invalid_request");
    if (url.pathname === "/health" && request.method === "GET") return json({status: "ok"});
    if (url.pathname === "/connect" && request.method === "GET") return connectionLandingPage();
    if (![HANDOFF_PATH, SESSION_PATH, CALLBACK_PATH].includes(url.pathname)) throw new RequestFailure(404, "not_found");
    if (request.method !== (url.pathname === CALLBACK_PATH ? "GET" : "POST")) throw new RequestFailure(405, "method_not_allowed");
    if (url.pathname !== CALLBACK_PATH && request.headers.has("Origin")) throw new RequestFailure(403, "native_client_required");
    if (!credential(env.ZOOM_PUBLIC_CLIENT_ID, 1024) || !credential(env.SIGNING_GRANT_SECRET, 1024) ||
        env.SIGNING_GRANT_SECRET.length < 43) throw new RequestFailure(503, "not_configured");
    let redirect: URL;
    try { redirect = redirectForRequest(url, env); }
    catch (error) {
      if (url.pathname === CALLBACK_PATH && error instanceof RequestFailure && error.status < 500) {
        return completionPage(undefined, false, 400);
      }
      throw error;
    }
    const source = request.headers.get("CF-Connecting-IP") ?? "local";
    const key = await digest(source);
    if (!(await env.REQUEST_LIMITER.limit({key})).success) throw new RequestFailure(429, "rate_limited");
    if (url.pathname === SESSION_PATH) return await createSession(request, redirect, env, deps);
    if (url.pathname === CALLBACK_PATH) return await completeAuthorization(request, redirect, env, deps);
    return await redeemHandoff(request, redirect, env, deps);
  } catch (error) {
    if (error instanceof RequestFailure) return json({error: error.code}, error.status);
    // Never log exception text or request data: callbacks contain OAuth codes.
    console.error(JSON.stringify({event: "auth_service_failure"}));
    return json({error: "service_unavailable"}, 503);
  }
}

export default {
  fetch(request: Request, env: Env): Promise<Response> { return handleRequest(request, env); }
} satisfies ExportedHandler<Env>;
