"""Render Yap's 0.1.7 source-architecture PDF with ReportLab; no network or secrets."""
from pathlib import Path
import math

from reportlab.lib.colors import HexColor, white
from reportlab.lib.styles import ParagraphStyle
from reportlab.pdfgen import canvas
from reportlab.platypus import Paragraph


ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "output/pdf/Zoom-Architecture.pdf"
OUTPUT.parent.mkdir(parents=True, exist_ok=True)
WIDTH, HEIGHT = 1020, 720
INK, MUTED, BLUE = map(HexColor, ("#173046", "#536779", "#246EAC"))
EDGE, PANEL, PALE_BLUE, AMBER = map(HexColor, ("#CDDAE3", "#F5F8FA", "#EAF3FA", "#8A5B1B"))
c = canvas.Canvas(str(OUTPUT), pagesize=(WIDTH, HEIGHT))
c.setTitle("Yap 0.1.7 architecture and Zoom authorization")
c.setAuthor("Michael Grinich")
c.setSubject("Source architecture for review candidate 0.1.7 build 8; not deployment or live acceptance evidence")


def paragraph(text, x, top, width, size=10.5, leading=14, color=INK, bold=False):
    style = ParagraphStyle("body", fontName="Helvetica-Bold" if bold else "Helvetica",
                           fontSize=size, leading=leading, textColor=color)
    p = Paragraph(text, style)
    _, height = p.wrap(width, HEIGHT)
    if top - height < 42:
        raise ValueError(f"Text would cross footer: {text[:70]}")
    p.drawOn(c, x, top - height)
    return top - height


def heading(title, subtitle, page):
    paragraph(title, 36, 686, 948, 24, 29, bold=True)
    paragraph(subtitle, 36, 648, 948, 10.5, 14, color=MUTED)
    c.setStrokeColor(EDGE)
    c.line(36, 45, 984, 45)
    c.setFont("Helvetica", 8.7)
    c.setFillColor(MUTED)
    c.drawString(36, 29, "Yap 0.1.7 / build 8 | Source design, September 14, 2026 | Michael Grinich")
    c.drawRightString(984, 29, f"{page} / 2")


def box(x, y, width, height, title, label, fill=PANEL):
    c.setFillColor(fill)
    c.setStrokeColor(EDGE)
    c.roundRect(x, y, width, height, 12, stroke=1, fill=1)
    c.setFillColor(BLUE)
    c.roundRect(x + 16, y + height - 42, 26, 25, 6, stroke=0, fill=1)
    c.setFillColor(white)
    c.setFont("Helvetica-Bold", 11)
    c.drawCentredString(x + 29, y + height - 34, label)
    paragraph(title, x + 53, y + height - 21, width - 69, 13.5, 17, bold=True)


def arrow(x1, y1, x2, y2, dashed=False, color=BLUE):
    c.setStrokeColor(color)
    c.setFillColor(color)
    c.setLineWidth(1.6)
    if dashed:
        c.setDash(4, 3)
    c.line(x1, y1, x2, y2)
    c.setDash()
    angle = math.atan2(y2 - y1, x2 - x1)
    path = c.beginPath()
    path.moveTo(x2, y2)
    path.lineTo(x2 - 7 * math.cos(angle - .45), y2 - 7 * math.sin(angle - .45))
    path.lineTo(x2 - 7 * math.cos(angle + .45), y2 - 7 * math.sin(angle + .45))
    path.close()
    c.drawPath(path, stroke=0, fill=1)


def step(number, title, body, x, top, width):
    c.setFillColor(BLUE)
    c.circle(x + 10, top - 9, 10, stroke=0, fill=1)
    c.setFillColor(white)
    c.setFont("Helvetica-Bold", 9.5)
    c.drawCentredString(x + 10, top - 12, str(number))
    bottom = paragraph(title, x + 29, top, width - 29, 10.6, 14, bold=True)
    return paragraph(body, x + 29, bottom - 5, width - 29, 10.2, 13.5)


def note(title, body, x, top, width, height, color=BLUE):
    y = top - height
    c.setFillColor(PANEL)
    c.setStrokeColor(EDGE)
    c.roundRect(x, y, width, height, 10, stroke=1, fill=1)
    bottom = paragraph(title, x + 16, top - 14, width - 32, 11, 14, color=color, bold=True)
    bottom = paragraph(body, x + 16, bottom - 7, width - 32, 10, 13)
    if bottom < y + 10:
        raise ValueError(f"Note overflow: {title}")


heading("Managed Zoom authorization", "Fixed HTTPS callback, encrypted native return, and direct meeting/media paths", 1)

for x, title, label in [(36, "User's Mac + browser", "A"),
                        (372, "Cloudflare authorization", "B"),
                        (708, "Zoom + delivery services", "C")]:
    box(x, 365, 276, 254, title, label)

paragraph("<b>Yap native application</b><br/>SwiftUI / AppKit / Zoom Meeting SDK<br/>Random nonce + S256 PKCE verifier",
          54, 558, 240, 10.8, 14)
paragraph("<b>System browser</b><br/>Zoom consent returns a code to B's HTTPS callback. Open Yap returns encrypted handoff, never raw tokens.",
          54, 499, 240, 10.5, 14)
paragraph("<b>Local storage</b><br/>Keychain: OAuth tokens + signing grant.<br/>Pending nonce/verifier: process memory.",
          54, 424, 240, 10.5, 14)

paragraph("<b>Fixed production client + HTTPS</b><br/>/v1/oauth/session<br/>/oauth/zoom/callback",
          390, 558, 240, 10.8, 14)
paragraph("<b>Exchange and native redemption</b><br/>/v1/oauth/token<br/>Secret-backed OAuth; token-bound grant.<br/>AES-GCM session / handoff: 180s each.",
          390, 499, 240, 10.5, 14)
paragraph("<b>SDK signer</b><br/>/v1/meeting-sdk/signature<br/>Grant + fresh ZAK check; server secrets.",
          390, 424, 240, 10.5, 14)

paragraph("<b>OAuth + own-user REST</b><br/>Zoom authorization and token endpoints<br/>ZAK, instant meetings, recording list",
          726, 558, 240, 10.8, 14)
paragraph("<b>Meeting SDK infrastructure</b><br/>Audio / video / shared content<br/>Participant metadata / chat / files<br/>Recording and meeting permissions",
          726, 499, 240, 10.5, 14)
paragraph("<b>Recording files + CDN</b><br/>Authorized MP4 / saved chat / VTT<br/>File availability follows the account.",
          726, 424, 240, 10.5, 14)

arrow(313, 538, 371, 538)
arrow(371, 473, 313, 473, dashed=True)
paragraph("HTTPS", 319, 554, 50, 8.5, 10, color=MUTED)
paragraph("return", 323, 465, 45, 8.5, 10, color=MUTED)
arrow(649, 538, 707, 538)
arrow(707, 473, 649, 473, dashed=True)
paragraph("HTTPS", 654, 554, 50, 8.5, 10, color=MUTED)
paragraph("OAuth", 656, 465, 45, 8.5, 10, color=MUTED)

c.setStrokeColor(BLUE)
c.setLineWidth(1.6)
c.line(174, 365, 174, 344)
c.line(174, 344, 846, 344)
arrow(846, 344, 846, 365)
paragraph("Direct A-to-C paths: browser consent, own-user REST, SDK media, chat/files and recording downloads",
          122, 334, 776, 10.4, 13, color=BLUE, bold=True)
paragraph("Meeting content, recording passcodes and Google Calendar data bypass the authorization service.",
          172, 315, 676, 10, 13, color=MUTED)

paragraph("Six exchanges, one native sign-in", 36, 281, 948, 14, 18, bold=True)
left_x, right_x, column = 36, 528, 456
step(1, "Mac creates the session", "POST nonce + verifier to B. B seals them with audience, fixed callback and expiry; returns a Zoom URL with PKCE challenge.", left_x, 250, column)
step(2, "Browser authorizes at Zoom", "C returns code + sealed state to B's exact HTTPS callback. B validates state and exchanges the code using its production secret.", left_x, 185, column)
step(3, "Browser returns an encrypted handoff", "B seals tokens, grant, nonce and verifier hash. Open Yap uses yap://oauth/zoom; plaintext code, verifier and tokens stay out of that URL.", left_x, 120, column)
step(4, "Initiating Mac redeems over HTTPS", "Mac consumes pending nonce once and POSTs handoff + original verifier to B. B validates proof and returns the remaining token lifetime.", right_x, 250, column)
step(5, "Mac saves and refreshes credentials", "After own-user ZAK validation, tokens + grant go to Keychain. Later refresh uses B and its confidential production OAuth credentials.", right_x, 185, column)
step(6, "Service authorizes the Meeting SDK", "Mac sends access token + bound grant. B verifies the grant and fresh ZAK access at Zoom, then signs the short-lived SDK JWT.", right_x, 120, column)
c.showPage()

heading("Trust boundaries and deployment configuration", "Same source design; separate production and development identities and secrets", 2)

paragraph("Configured environments", 36, 613, 948, 14, 18, bold=True)
box(36, 458, 456, 122, "Production review candidate", "P", PALE_BLUE)
box(528, 458, 456, 122, "Development environment", "D")
paragraph("<b>meeting-auth.mgrinich.workers.dev</b><br/>OAuth + SDK ID: UHoml3aIQpy86gZeijjfpQ<br/>HTTPS callback: /oauth/zoom/callback<br/>Native app uses this production origin and ID.",
          54, 523, 420, 10, 13)
paragraph("<b>meeting-auth-development.mgrinich.workers.dev</b><br/>OAuth + SDK ID: ZA20iVuUSmSKMGVmx7tDyA<br/>HTTPS callback: /oauth/zoom/callback<br/>Separate secrets and rate-limit namespaces.",
          546, 523, 420, 10, 13)

paragraph("Worker routes", 36, 439, 456, 12, 16, bold=True)
paragraph("<b>GET</b> /connect - native integration entry<br/><b>POST</b> /v1/oauth/session - sealed sign-in state<br/><b>GET</b> /oauth/zoom/callback - fixed Zoom return<br/><b>POST</b> /v1/oauth/token - handoff redemption / refresh<br/><b>POST</b> /v1/meeting-sdk/signature - validated SDK JWT<br/><b>GET</b> /health - health only, not OAuth acceptance",
          36, 414, 456, 10.2, 15)
paragraph("Secrets and API scope", 528, 439, 456, 12, 16, bold=True)
paragraph("<b>Server secrets:</b> production OAuth / SDK secret and an independent signing-grant secret. OAuth and SDK IDs must match before the same secret is used. Each environment needs its own secrets.<br/><br/><b>Zoom scopes:</b> user:read:zak; meeting:write:meeting; cloud_recording:read:list_user_recordings. Only the consenting user's data; no admin/master scope.",
          528, 414, 456, 10.2, 14)

note("Memory, encryption and replay boundary",
     "No persistent server user/token/session database. Plaintext codes, verifiers, OAuth tokens, ZAKs and grants are processed in request memory. Session and handoff are separately authenticated AES-GCM envelopes, each expiring within 180 seconds. Browser history may retain callback URLs and ciphertext; expiry does not erase it. Desktop nonce is consumed once. The stateless broker has no redeemed-handoff ledger: replay before expiry is possible with the original verifier. Token expiry is never extended by redemption.",
     36, 297, 948, 103, AMBER)

note("Local data and direct providers",
     "Keychain holds tokens and signing grants. Calendar cache, playback storage, saved chat/attachments, group photos and imported camera backgrounds have separate local retention. Google OAuth + read-only Calendar API remain direct Mac-to-Google. Media redirects drop Zoom authorization before a non-Zoom CDN target.",
     36, 179, 456, 102)
note("Bounded service processing",
     "Fixed upstream URLs; no credential redirects; 15s upstream timeout; bounded request/response bodies. Limits: 120 requests/minute per hashed source IP; 10 signatures/minute per token hash. Constant error events only; invocation logs and traces off. Provider infrastructure metadata is separate.",
     528, 179, 456, 102)

paragraph("Compatibility: released 0.1.6 retains legacy public-client loopback; personal mode keeps direct Zoom OAuth + local SDK signing. This diagram is source architecture, not deployment, live-test or Zoom-approval evidence.",
          36, 66, 948, 8.5, 10, color=MUTED)
c.save()
print(OUTPUT)
