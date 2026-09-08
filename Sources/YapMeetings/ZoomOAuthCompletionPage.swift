import Foundation

/// Self-contained loopback response. Never interpolate OAuth request parameters.
struct ZoomOAuthCompletionPage {
    enum Outcome: CaseIterable { case received, denied, invalid }
    let body: String
    let contentSecurityPolicy: String

    init(outcome: Outcome, iconPNG: Data? = nil) {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let title: String
        let detail: String
        let status: String
        switch outcome {
        case .received:
            title = "Ready to yap."
            detail = "Your Zoom sign-in is received. Yap will come forward as soon as your connection is ready."
            status = "Sign-in received"
        case .denied:
            title = "Maybe next time."
            detail = "Zoom access wasn’t granted. Head back to Yap whenever you’re ready to try again."
            status = "Sign-in cancelled"
        case .invalid:
            title = "Let’s try that again."
            detail = "We couldn’t verify this sign-in. Return to Yap and start a new connection."
            status = "Connection not completed"
        }
        let icon = iconPNG.map {
            "<img class=\"app-icon\" src=\"data:image/png;base64,\($0.base64EncodedString())\" width=\"112\" height=\"112\" alt=\"Yap\">"
        } ?? "<div class=\"icon-fallback\" aria-label=\"Yap\">Y</div>"
        contentSecurityPolicy = "default-src 'none'; img-src data:; style-src 'nonce-\(nonce)'; script-src 'nonce-\(nonce)'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"
        body = """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <title>\(title) — Yap</title>
        <style nonce="\(nonce)">
        *{box-sizing:border-box}
        :root{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#24252a;background:#f8f7f4;color-scheme:light dark}
        body{margin:0;min-height:100svh;display:grid;place-items:center;padding:48px 24px;position:relative;isolation:isolate}
        body::before{content:"";position:fixed;inset:0;z-index:-1;background:radial-gradient(ellipse at 24% 24%,#ffdaa552,transparent 46%),radial-gradient(ellipse at 80% 30%,#b6a8f047,transparent 44%),radial-gradient(ellipse at 48% 90%,#a8ddcb38,transparent 48%);pointer-events:none}
        main{width:min(100%,480px);text-align:center;animation:arrive .55s ease-out both}
        .app-icon{display:block;margin:0 auto 24px;filter:drop-shadow(0 12px 18px #33313b1a)}
        .icon-fallback{display:grid;place-items:center;width:96px;height:96px;margin:0 auto 28px;border-radius:25px;background:#f7ca54;font-size:58px;font-weight:800;color:#27251d}
        .wordmark{margin:0 0 32px;font-size:20px;letter-spacing:-.7px;font-weight:750}
        .status{display:inline-flex;align-items:center;gap:8px;border:1px solid #4590702b;border-radius:100px;padding:8px 12px;background:#e9f4ed;color:#32674a;font-size:12px;font-weight:650;letter-spacing:.1px}
        .status svg{width:14px;height:14px}
        h1{margin:22px 0 16px;font-size:clamp(36px,7vw,54px);line-height:1.08;letter-spacing:-2.5px;font-weight:730;text-wrap:balance}
        .detail{max-width:350px;margin:0 auto;color:#6c6b73;font-size:17px;line-height:1.6;text-wrap:pretty}
        .open-app{display:inline-flex;align-items:center;justify-content:center;gap:28px;min-height:50px;margin:30px 0 0;padding:0 23px;border:1px solid #292a31;border-radius:15px;background:#292a31;color:#fff;text-decoration:none;font-weight:650;font-size:15px;box-shadow:0 4px 9px #25232a12;transition:background .15s,transform .15s,box-shadow .15s}
        .open-app svg{width:17px;height:17px}
        .open-app:hover{background:#43444c;box-shadow:0 6px 14px #25232a20;transform:translateY(-1px)}
        .open-app:active{transform:translateY(0)}
        .open-app:focus-visible{outline:3px solid #8270db;outline-offset:5px}
        .hint{font-size:12px;color:#797780;margin:17px 0 0}
        footer{margin-top:70px;color:#8b8992;font-size:12px;letter-spacing:.1px}
        @keyframes arrive{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:none}}
        @media(prefers-color-scheme:dark){
          :root{color:#f4f1f6;background:#17171c}
          body::before{opacity:.25}
          .detail{color:#b8b5c0}.hint,footer{color:#97949f}
          .status{color:#b5e5c6;background:#293c32;border-color:#9edaad25}
          .open-app{background:#eeedf3;color:#24242b;border-color:#eeedf3;box-shadow:0 4px 12px #0002}
          .open-app:hover{background:#fff}
        }
        @media(prefers-reduced-motion:reduce){main{animation:none}.open-app{transition:none}.open-app:hover{transform:none}}
        </style>
        <script nonce="\(nonce)">history.replaceState(null, "", location.pathname);</script>
        </head>
        <body><main>
        \(icon)
        <p class="wordmark">Yap</p>
        <div class="status"><svg viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d="M4 8h8M8 4l4 4-4 4" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>\(status)</div>
        <h1>\(title)</h1>
        <p class="detail">\(detail)</p>
        <a class="open-app" href="yap://open">Open Yap<svg viewBox="0 0 20 20" fill="none" aria-hidden="true"><path d="M4 10h12m-5-5 5 5-5 5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg></a>
        <p class="hint">You can close this tab.</p>
        <footer>For people who professionally yap for a living.</footer>
        </main></body></html>
        """
    }
}
