// Render the current book/play brand from the existing SVG. No AI rendering.
// Usage: node scripts/generate_brand_icons.cjs <path-to-sharp>
const fs = require('node:fs');
const path = require('node:path');
const sharp = require(process.argv[2] || 'sharp');
const root = path.resolve(__dirname, '..');
const svg = fs.readFileSync(path.join(root, 'website/icon.svg'), 'utf8');
if (!svg.includes('rx="112"')) throw new Error('Review the updated SVG background.');
const square = svg.replace('rx="112"', 'rx="0"');

async function png(relative, size, opaque) {
  const output = path.join(root, relative);
  fs.mkdirSync(path.dirname(output), { recursive: true });
  let renderer = sharp(Buffer.from(opaque ? square : svg), { density: 192 })
    .resize(size, size);
  if (opaque) renderer = renderer.flatten({ background: '#624580' }).removeAlpha();
  const data = await renderer.png().toBuffer();
  fs.writeFileSync(output, data);
  return data;
}

async function main() {
  await png('assets/icon/book-play-1024.png', 1024, true);
  for (const platform of ['ios', 'macos']) {
    const directory = `${platform}/Runner/Assets.xcassets/AppIcon.appiconset`;
    const manifestPath = path.join(root, directory, 'Contents.json');
    const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    const generated = new Set();
    for (const entry of manifest.images) {
      if (!entry.filename) continue;
      entry.filename = 'book_play_' + entry.filename.replace(/^(whitehair_|book_play_)/, '');
      const size = Math.round(parseFloat(entry.size) * parseFloat(entry.scale));
      if (!generated.has(entry.filename)) {
        await png(`${directory}/${entry.filename}`, size, platform === 'ios');
        generated.add(entry.filename);
      }
    }
    fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
  }
  for (const [density, size] of Object.entries({ mdpi: 48, hdpi: 72, xhdpi: 96, xxhdpi: 144, xxxhdpi: 192 })) {
    await png(`android/app/src/main/res/mipmap-${density}/ic_launcher_book_play.png`, size, true);
  }
  const sizes = [16, 24, 32, 48, 64, 128, 256];
  const images = [];
  for (const size of sizes) {
    images.push(await sharp(Buffer.from(svg), { density: 192 }).resize(size, size).png().toBuffer());
  }
  const header = Buffer.alloc(6 + sizes.length * 16);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(sizes.length, 4);
  let offset = header.length;
  for (let i = 0; i < sizes.length; i++) {
    const entry = 6 + i * 16;
    header[entry] = header[entry + 1] = sizes[i] === 256 ? 0 : sizes[i];
    header.writeUInt16LE(1, entry + 4);
    header.writeUInt16LE(32, entry + 6);
    header.writeUInt32LE(images[i].length, entry + 8);
    header.writeUInt32LE(offset, entry + 12);
    offset += images[i].length;
  }
  fs.writeFileSync(path.join(root, 'windows/runner/resources/app_icon_book_play.ico'), Buffer.concat([header, ...images]));
  console.log('Generated book/play icons: Windows, iOS, Android and macOS.');
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
