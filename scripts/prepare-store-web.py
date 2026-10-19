#!/usr/bin/env python3
"""Create reviewable, self-contained public policy/support files. Does not publish."""
import argparse
from datetime import date
import html
import re
from pathlib import Path
from brand_values import load_brand

root = Path(__file__).resolve().parent.parent
brand_name, palette = load_brand()
parser = argparse.ArgumentParser()
parser.add_argument('--publisher')
parser.add_argument('--email')
parser.add_argument('--draft', action='store_true', help='Show missing publisher/contact explicitly; do not publish these previews')
parser.add_argument('--output', type=Path, default=root / 'build/store-web')
args = parser.parse_args()
if not args.draft and (not args.publisher or not args.publisher.strip() or not args.email):
    parser.error('Supply --publisher and --email for public pages, or use --draft for previews.')
if args.email and not re.fullmatch(r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", args.email):
    parser.error('Supply a plain support email.')
if not args.draft and args.email.rsplit('@', 1)[-1].lower() in {'example.com', 'example.org', 'example.net'}:
    parser.error('Replace the example email with a real public support contact.')
publisher = html.escape((args.publisher or 'Publisher name pending').strip())
email = html.escape(args.email or '')
contact = f'<a href="mailto:{email}">{email}</a>' if email else '<strong>Public support email pending</strong>'
notice = '<aside>Draft preview — add the publisher name and a monitored support email before publishing.</aside>' if args.draft else ''
policy = (root / 'Resources/PrivacyPolicy.txt').read_text()
paragraphs = ''.join('<p>' + html.escape(text).replace('\n', '<br>') + '</p>' for text in policy.split('\n\n'))
style = f'body{{max-width:760px;margin:64px auto;padding:0 24px;color:{palette["ink"]};background:{palette["paper"]};font:17px/1.65 system-ui}}h1{{font-size:42px;line-height:1.1}}a{{color:{palette["primary"]}}}nav,footer{{font-size:14px}}p{{margin:24px 0}}aside{{margin:24px 0;padding:16px;border:1px solid {palette["border"]};border-radius:12px;font-size:14px}}'
def page(title, body):
    return f'<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{title} — {brand_name}</title><style>{style}</style></head><body><nav><a href="support.html">Support</a> · <a href="privacy.html">Privacy</a></nav>{notice}<main><h1>{title}</h1>{body}</main><footer>© 2026 {publisher} · {contact}</footer></body></html>'
args.output.mkdir(parents=True, exist_ok=True)
updated = date.today().strftime('%B %d, %Y').replace(' 0', ' ')
(args.output / 'privacy.html').write_text(page('Canopy privacy policy', f'<p>Publisher: {publisher}. Updated {updated}. Contact: {contact}.</p>'+paragraphs))
support = f'''<p>Canopy keeps screenshots and local meeting notes on a quiet shelf above your work. Requires macOS 26 or later.</p>
<h2>Open the shelf</h2><p>Click the Canopy menu-bar icon or press Control–Option–Space. Hover briefly over the menu bar for the small panel. Drag the title area beside Canopy to move the main workspace; its position is remembered. The small shelf stays at the top. Click outside the workspace to hide it.</p>
<h2>Screenshots</h2><p>Hover over the menu bar and click Capture on Canopy’s small shelf, or press Control–Option–S anywhere. Drag a region; Escape cancels. Your capture appears on the top shelf without a Desktop file or macOS corner preview. Click a capture to open Apple Preview, drag a copy into another app, or discard the app copy with ×. Preview may ask to save an edited copy.</p><p>To also detect ordinary Shift–Command–3/4 screenshots, choose their save folder in Canopy’s Shelf menu or Settings. If needed, press Shift–Command–5 and use Options → Save to → Other Location to select that same folder in macOS. The macOS Options menu also controls Show Floating Thumbnail. These are your choices: the Store app does not change either setting. Folder detection leaves originals in place and may wait until macOS finishes saving the image.</p>
<h2>Meeting notes</h2><p>Choose Meetings → Start listening with Meeting audio selected. Approve System Audio Recording Only access when macOS asks. The first session may prepare language support. Audio playing on your Mac is transcribed locally; microphone capture is optional. Stop listening ends the session. Silence unrelated apps and use participants' permission.</p>
<h2>Your notes</h2><p>Choose Notes inside a meeting or create a quick note. Write in one document. Type / for headings, to-dos, bullet lists or quotes; or use the Text menu in the small toolbar. Bold and italic work with Command–B and Command–I. Select text and press Command–K to add a link; Command-click opens a link in your browser. Checkboxes are part of the document. Command–Z undoes an edit. The editor is bundled locally and works offline. Existing notes open as literal text. Markdown export includes formatting, to-dos and the transcript.</p>
<h2>Privacy</h2><p>Screenshots, notes and transcripts stay on your Mac. AI tools are deferred in this version. See the <a href="privacy.html">privacy policy</a> for storage and deletion details.</p>
<h2>Get help</h2><p>Contact: {contact}. Include your Canopy version, macOS version and a description. Please exclude private transcripts and API keys.</p>'''
(args.output / 'support.html').write_text(page('Canopy support', support))
print('Created privacy.html and support.html in', args.output)
