import assert from "node:assert/strict";
import test from "node:test";
import {connectionLandingPage} from "../src/landing.ts";

test("integration landing page starts native Zoom connection without accepting credentials", async () => {
  const response = connectionLandingPage();
  const html = await response.text();
  assert.equal(response.status, 200);
  assert.match(html, /href="yap:\/\/connect\/zoom"/);
  assert.match(html, /Yap 0\.1\.7 or later/);
  assert.match(html, /build provided with your invitation/);
  // The public 0.1.6 installer cannot handle this native connection link.
  assert.doesNotMatch(html, /releases\/latest/);
  assert.doesNotMatch(html, /<script|<form|<input|127\.0\.0\.1|localhost|client_secret/);
  assert.equal(response.headers.get("Referrer-Policy"), "no-referrer");
  assert.match(response.headers.get("Content-Security-Policy")!, /frame-ancestors 'none'/);
});
