# Zoom architecture diagram

`generate.py` produces `output/pdf/Zoom-Architecture.pdf`, a two-page landscape diagram for the **0.1.7 / build 8 source design**. It describes the revised managed HTTPS OAuth flow, encrypted browser/native handoff, direct Zoom media paths, local Keychain storage, and separate production/development configuration. It contains public client IDs only and never reads secrets or calls the network.

The document distinguishes released 0.1.6 compatibility from the new candidate. It does not assert deployment, completed live acceptance, or Zoom approval. The broker is stateless: encrypted sessions/handoffs expire within 180 seconds, but a handoff plus its original verifier can be redeemed again before expiry. The desktop's one-time pending nonce does not establish a server-side redemption ledger.

Generate with Python and ReportLab from the repository root:

```sh
python3 Documentation/Architecture/generate.py
mkdir -p tmp/pdfs
pdftoppm -r 120 -png output/pdf/Zoom-Architecture.pdf tmp/pdfs/Zoom-Architecture
```

Inspect both rendered pages before providing the PDF. Sources of truth are [the service implementation](../../Services/zoom-auth/src/index.ts), [public environment configuration](../../Services/zoom-auth/wrangler.jsonc), [native managed OAuth](../../Sources/YapMeetings/ZoomManagedOAuth.swift), and [Privacy](../../PRIVACY.md). Update the diagram when those trust boundaries change. The historical architecture remains in Git history; do not present its old loopback design as the new candidate's flow.
