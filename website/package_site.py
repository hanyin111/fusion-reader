"""Package public site assets only; no application or private data is uploaded."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED

ROOT = Path(__file__).resolve().parent
DEST = ROOT.parent / 'build/private/fusion-reader-site.zip'
DEST.parent.mkdir(parents=True, exist_ok=True)
with ZipFile(DEST, 'w', compression=ZIP_DEFLATED) as archive:
    for name in ('index.html', 'icon.svg', '_headers', 'robots.txt', 'sitemap.xml'):
        archive.write(ROOT / name, name)
print(f'Packaged {DEST.name}: {DEST.stat().st_size:,} bytes; 5 public files.')
