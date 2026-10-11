"""Refresh embedded native screenshots without changing the page's layout."""
import base64
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent
page = ROOT / 'index.html'
html = page.read_text(encoding='utf-8')


def image_url(name):
    if not re.fullmatch(r'[a-z-]+', name):
        raise ValueError('Unexpected capture name')
    return 'data:image/png;base64,' + base64.b64encode(
        (ROOT / 'screenshots' / f'{name}.png').read_bytes()).decode('ascii')


html, count = re.subn(
    r'(<img class="client-shot" data-capture="([a-z-]+)" src=")[^"]+("[^>]*>)',
    lambda match: match[1] + image_url(match[2]) + match[3], html)
if count != 8:
    raise ValueError(f'Expected 8 displayed captures, found {count}')
variants = ['shelf-tablet', 'shelf-desktop', 'novel-phone', 'novel-phone-dark',
            'novel-phone-large', 'novel-phone-dark-large']
html, scripts = re.subn(
    r'const clientCaptures = [^\n]+;',
    lambda _: 'const clientCaptures = ' + json.dumps(
        {name: image_url(name) for name in variants}, separators=(',', ':')) + ';', html)
if scripts != 1:
    raise ValueError('Screenshot switcher was not found')
page.write_text(html, encoding='utf-8')
print(f'Refreshed {count} displayed captures and {len(variants)} interactive variants.')
