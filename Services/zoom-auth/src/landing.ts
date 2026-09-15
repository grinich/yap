/** Native integration entry point. No credentials or user data are accepted here. */
export function connectionLandingPage(): Response {
  return new Response(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark"><title>Connect Zoom to Yap</title>
<style>
:root{font:17px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#232426;background:#f5f6f8;color-scheme:light dark}
*{box-sizing:border-box}body{margin:0;min-height:100svh;display:grid;place-items:center;padding:32px 20px}
main{width:min(100%,540px);padding:40px;border:1px solid #e2e4e8;border-radius:24px;background:#fff;box-shadow:0 14px 45px #18202b0b}
.brand{margin:0 0 28px;font-size:24px;font-weight:700;letter-spacing:-.6px}h1{font-size:32px;line-height:1.15;letter-spacing:-.9px;margin:0 0 16px}
p{color:#656a72;margin:0 0 20px}a{color:#0764d3;text-underline-offset:3px}.button{display:block;padding:12px 20px;border-radius:12px;background:#0875f5;color:#fff;text-align:center;text-decoration:none;font-weight:600;margin:28px 0 16px}
a:focus-visible{outline:3px solid #70b0ff;outline-offset:4px}.small{font-size:14px}.install{border-top:1px solid #e8e9ed;padding-top:24px;margin-top:28px}h2{font-size:17px;margin:0 0 8px}footer{display:flex;gap:18px;margin-top:28px;font-size:13px}footer a{color:#656a72}
@media(prefers-color-scheme:dark){:root{color:#f5f5f7;background:#151619}main{background:#202226;border-color:#34373d;box-shadow:none}p,footer a{color:#b2b6bf}.install{border-color:#34373d}a{color:#85b8ff}}
@media(max-width:420px){main{padding:28px 24px}h1{font-size:28px}}
</style></head><body><main>
<p class="brand">Yap</p><h1>Your Zoom account.<br>Your native Mac app.</h1>
<p>Connect Zoom to join and host meetings, share your screen, and watch your cloud recordings in Yap.</p>
<a class="button" href="yap://connect/zoom">Connect Zoom in Yap</a>
<p class="small">Yap opens Zoom’s sign-in page in your browser. Choose your Zoom account and review the permissions, then return to Yap. If you’re already connected, this opens your connection settings.</p>
<section class="install"><h2>Before you connect</h2><p class="small">Use Yap 0.1.7 or later. Install the Yap build provided with your invitation, move it to Applications, and open it once. Then choose Connect Zoom above. Requires Apple silicon and macOS 26 or later.</p>
<p class="small">There’s no separate Yap account or subscription. Cloud recordings require a Zoom plan and account permissions that include them. Google Calendar is optional.</p></section>
<footer><a href="https://grinich.github.io/yap/guide/">Help</a><a href="https://grinich.github.io/yap/privacy/">Privacy</a><a href="https://grinich.github.io/yap/terms/">Terms</a></footer>
</main></body></html>`, {headers: {
    "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY",
    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
  }});
}
