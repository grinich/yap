"""Render the review architecture PDF. Requires ReportLab; no network or secrets."""
from pathlib import Path
import math
from reportlab.pdfgen import canvas
from reportlab.lib.colors import HexColor, white
from reportlab.platypus import Paragraph
from reportlab.lib.styles import ParagraphStyle

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / 'output/pdf/Zoom-Architecture.pdf'
OUTPUT.parent.mkdir(parents=True, exist_ok=True)
c = canvas.Canvas(str(OUTPUT), pagesize=(1020, 720))
c.setTitle('Yap architecture and Zoom data flows')
c.setAuthor('Michael Grinich')
INK, MUTED, BLUE = map(HexColor, ('#173046', '#546678', '#246EAC'))
EDGE, PANEL = map(HexColor, ('#CDDAE3', '#F5F8FA'))

def paragraph(text, x, y, width, size=10.5, leading=14, color=INK, bold=False):
    style = ParagraphStyle('body', fontName='Helvetica-Bold' if bold else 'Helvetica',
                           fontSize=size, leading=leading, textColor=color)
    p = Paragraph(text, style)
    _, height = p.wrap(width, 500)
    p.drawOn(c, x, y-height)
    return y-height

def box(x, title, label):
    y, w, h = 346, 276, 274
    c.setFillColor(PANEL); c.setStrokeColor(EDGE)
    c.roundRect(x, y, w, h, 12, stroke=1, fill=1)
    c.setFillColor(BLUE); c.roundRect(x+16, y+h-43, 27, 25, 6, stroke=0, fill=1)
    c.setFont('Helvetica-Bold', 12); c.setFillColor(white)
    c.drawCentredString(x+29.5, y+h-35, label)
    paragraph(title, x+54, y+h-21, w-70, 14, 17, bold=True)

def arrow(x1, y1, x2, y2, dashed=False):
    c.setStrokeColor(BLUE); c.setFillColor(BLUE); c.setLineWidth(1.7)
    if dashed: c.setDash(4, 3)
    c.line(x1, y1, x2, y2); c.setDash()
    a = math.atan2(y2-y1, x2-x1)
    p = c.beginPath(); p.moveTo(x2, y2)
    p.lineTo(x2-7*math.cos(a-.45), y2-7*math.sin(a-.45))
    p.lineTo(x2-7*math.cos(a+.45), y2-7*math.sin(a+.45)); p.close()
    c.drawPath(p, stroke=0, fill=1)

paragraph('Yap architecture and data flows', 36, 685, 948, 25, 29, bold=True)
paragraph('Managed production mode | Michael Grinich | Source checkpoint: September 7, 2026',
          36, 647, 948, 11, 15, color=MUTED)
for x, title, letter in [(36, "User's Mac", 'A'), (372, 'Authorization service', 'B'), (708, 'Zoom services', 'C')]:
    box(x, title, letter)
paragraph('<b>Yap native macOS application</b><br/>SwiftUI / AppKit / AVPlayer<br/>Zoom Meeting SDK', 54, 553, 240, 12, 17)
paragraph('<b>System browser</b><br/>Zoom consent; S256 PKCE + state.<br/>Code returns to 127.0.0.1 callback.', 54, 483, 240)
paragraph('<b>Local storage</b><br/>Keychain: OAuth tokens and signing grant.<br/>Calendar cache, temporary playback data,<br/>and user-selected recording exports.', 54, 415, 240)
paragraph('<b>Cloudflare Workers / HTTPS</b><br/>meetings.grinich.app', 390, 553, 240, 12, 17)
paragraph('<b>POST /v1/oauth/token</b><br/>Pins public client ID; proxies PKCE or<br/>refresh; issues token-bound HMAC grant.', 390, 499, 240)
paragraph('<b>POST /v1/meeting-sdk/signature</b><br/>Verifies grant + live ZAK; returns SDK JWT.<br/>SDK and grant secrets stay server-side.', 390, 437, 240)
paragraph('No meeting content or credential database.<br/>Transient token processing only.', 390, 375, 240, 9.5, 13, color=MUTED)
paragraph('<b>OAuth + REST API</b><br/>Authorization / token endpoints<br/>GET /v2/users/me/zak', 726, 553, 240, 12, 17)
paragraph('<b>Meeting SDK infrastructure</b><br/>Meeting authorization, microphone,<br/>camera, screen share and meeting chat.', 726, 480, 240)
paragraph('<b>Cloud recordings + delivery</b><br/>User-authorized list and download URLs;<br/>MP4 video, saved chat and VTT transcript.<br/>Zoom may redirect content to a CDN.', 726, 410, 240)
arrow(313, 527, 371, 527); paragraph('HTTPS', 320, 543, 50, 8.5, 10, color=MUTED)
arrow(371, 485, 313, 485, dashed=True)
arrow(647, 527, 707, 527); paragraph('HTTPS', 656, 543, 50, 8.5, 10, color=MUTED)
arrow(707, 485, 647, 485, dashed=True)
c.setStrokeColor(BLUE); c.setLineWidth(1.7)
c.line(174, 346, 174, 316); c.line(174, 316, 846, 316); arrow(846, 316, 846, 346)
paragraph('Direct Mac-to-Zoom path: browser authorization, REST requests and recording downloads; SDK meeting media',
          188, 306, 658, 10, 13, color=BLUE)
paragraph('Content and recording passcodes do not pass through the authorization service.', 220, 288, 590, 10, 13, color=MUTED)
paragraph('Authentication exchange', 36, 246, 596, 14, 18, bold=True)
rows = [
    'The browser obtains user consent at Zoom and returns a code to Yap.',
    "Yap sends code + PKCE verifier (or refresh token) to B. B calls Zoom's fixed token endpoint and returns OAuth tokens + a bound signing grant.",
    'Yap sends access token + grant to B. B verifies the grant, checks live ZAK authorization at Zoom, then returns an expiring SDK JWT.',
    'Yap uses Zoom directly for meetings and recordings. HTTPS media redirects drop OAuth authorization before a non-Zoom CDN target.'
]
y = 216
for i, text in enumerate(rows, 1):
    c.setFillColor(BLUE); c.circle(45, y-6, 9, stroke=0, fill=1)
    c.setFillColor(white); c.setFont('Helvetica-Bold', 9); c.drawCentredString(45, y-9, str(i))
    y = paragraph(text, 63, y+1, 569, 10, 13)-12
c.setFillColor(PANEL); c.setStrokeColor(EDGE); c.roundRect(672, 115, 312, 132, 10, fill=1, stroke=1)
paragraph('Service controls', 688, 231, 280, 12, 16, bold=True)
paragraph('120 requests/minute per hashed source IP;<br/>10 signatures/minute per hashed token.<br/>Bounded bodies; fixed upstreams; no redirects.<br/>Constant error events only; invocation logs<br/>and traces off. Platform metadata is separate.', 688, 204, 280, 10, 14)
paragraph('<b>Optional Google Calendar</b>: Yap uses Google OAuth and read-only Calendar API directly; calendar content bypasses B.', 672, 98, 310, 10, 13)
c.setStrokeColor(EDGE); c.line(36, 47, 984, 47)
paragraph('Personal configuration uses direct Zoom OAuth and locally supplied SDK credentials instead of B. No AI processing service is present.', 36, 36, 948, 9, 12, color=MUTED)
c.save()
print(OUTPUT)
