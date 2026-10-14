import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';

const require = createRequire(import.meta.url);
const sharp = require('sharp');
const root = path.dirname(fileURLToPath(import.meta.url));
const source = path.join(root, 'source');
const output = path.join(root, 'output');
const copy = JSON.parse(await fs.readFile(path.join(source, 'copy.json'), 'utf8'));
const width = 1206;
const height = 2622;
const esc = value => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
const asDataURI = async file => 'data:image/png;base64,' + (await fs.readFile(path.join(source, file))).toString('base64');
const icon = await asDataURI('official-app-icon.png');
const manifests = [];

await fs.mkdir(output, { recursive: true });
for (const panel of copy.panels) {
  const dark = panel.theme === 'dark';
  const colors = dark
    ? { bg: '#103C32', ink: '#FFFFFF', accent: '#A6E3C5', muted: '#D5E6DD', rule: '#496C60' }
    : { bg: '#FFFFFF', ink: '#173F34', accent: '#1D755E', muted: '#536D62', rule: '#D8E5DD' };
  const hero = await asDataURI(panel.hero);
  const label = (id, text, x, y, size, color, weight = 400, extra = '') =>
    `<text id="${id}" x="${x}" y="${y}" font-size="${size}" fill="${color}" font-weight="${weight}" ${extra}>${esc(text)}</text>`;
  const svg = `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img" aria-labelledby="title description">
  <title id="title">Bokki Plan — ${esc(panel.headline.join(' '))}</title>
  <desc id="description">${esc(panel.alt)} Illustrative feature artwork. Fictional day, not app UI. Planned release in 2026.</desc>
  <defs>
    <clipPath id="icon-corners"><rect x="84" y="92" width="112" height="112" rx="27"/></clipPath>
    <clipPath id="art-corners"><rect x="48" y="880" width="1110" height="1110" rx="48"/></clipPath>
  </defs>
  <rect id="background" width="1206" height="2622" fill="${colors.bg}"/>
  <g id="editable-typography" font-family="Arial, Helvetica, sans-serif">
    <image id="official-icon" x="84" y="92" width="112" height="112" xlink:href="${icon}" clip-path="url(#icon-corners)"/>
    ${label('brand', copy.brand, 224, 151, 44, colors.ink, 700, 'letter-spacing="-1.2"')}
    ${label('byline', copy.byline, 226, 188, 20, colors.muted, 700, 'letter-spacing="2.8"')}
    ${label('eyebrow', panel.eyebrow, 88, 333, 27, colors.accent, 700, 'letter-spacing="3.2"')}
    ${label('headline-line-1', panel.headline[0], 80, 499, 134, colors.ink, 700, 'letter-spacing="-6"')}
    ${label('headline-line-2', panel.headline[1], 80, 641, 134, colors.ink, 700, 'letter-spacing="-6"')}
    ${label('body-line-1', panel.body[0], 88, 743, 43, colors.muted)}
    ${label('body-line-2', panel.body[1], 88, 802, 43, colors.muted)}
    <image id="original-hero-illustration" x="48" y="880" width="1110" height="1110" xlink:href="${hero}" preserveAspectRatio="xMidYMid meet" clip-path="url(#art-corners)"/>
    <path id="section-rule" d="M84 2080H1122" stroke="${colors.rule}" stroke-width="2"/>
    ${label('support-title', panel.supportTitle, 84, 2170, 46, dark ? colors.accent : colors.ink, 700, 'letter-spacing="-1"')}
    ${label('support-body', panel.supportBody, 84, 2229, 37, colors.muted)}
    ${label('release', copy.release, 84, 2410, 25, colors.accent, 700, 'letter-spacing="2"')}
    ${label('platform', copy.platform, 1122, 2410, 25, colors.muted, 700, 'letter-spacing="2" text-anchor="end"')}
    ${label('artwork-label', copy.artworkLabel, 84, 2500, 25, colors.muted, 700)}
    ${label('disclaimer', copy.disclaimer, 84, 2544, 24, colors.muted)}
  </g>
</svg>`;
  const base = `bokki-plan-${panel.id}`;
  const svgPath = path.join(source, `${base}.svg`);
  await fs.writeFile(svgPath, svg);
  const pngPath = path.join(output, `${base}-1206x2622.png`);
  await sharp(Buffer.from(svg)).flatten({ background: colors.bg }).removeAlpha().withIccProfile('srgb').png({ compressionLevel: 9 }).toFile(pngPath);
  for (const format of ['jpg', 'webp']) {
    const pipeline = sharp(pngPath).resize(603, 1311, { kernel: 'lanczos3' }).removeAlpha();
    const webPath = path.join(output, `${base}-603x1311.${format}`);
    if (format === 'jpg') await pipeline.jpeg({ quality: 91, chromaSubsampling: '4:4:4' }).toFile(webPath);
    else await pipeline.webp({ quality: 88, effort: 6 }).toFile(webPath);
  }
  for (const name of [`${base}-1206x2622.png`, `${base}-603x1311.jpg`, `${base}-603x1311.webp`]) {
    const file = path.join(output, name);
    const meta = await sharp(file).metadata();
    const bytes = await fs.readFile(file);
    const expectedWidth = name.endsWith('.png') ? 1206 : 603;
    const expectedHeight = name.endsWith('.png') ? 2622 : 1311;
    if (meta.width !== expectedWidth || meta.height !== expectedHeight || meta.hasAlpha || meta.channels !== 3) throw new Error(`Unexpected image format: ${name}`);
    manifests.push({ file: path.relative(root, file), width: meta.width, height: meta.height, space: meta.space, channels: meta.channels, hasAlpha: meta.hasAlpha, bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') });
  }
}

await sharp({ create: { width: 1266, height: 1351, channels: 3, background: '#E8EEE9' } })
  .composite(copy.panels.map((panel, index) => ({ input: path.join(output, `bokki-plan-${panel.id}-603x1311.jpg`), top: 20, left: 20 + index * 623 })))
  .jpeg({ quality: 91, chromaSubsampling: '4:4:4' }).toFile(path.join(output, 'preview-pair.jpg'));
await fs.writeFile(path.join(root, 'export-manifest.json'), JSON.stringify({ requestID: copy.requestID, status: 'illustrative feature artwork draft; not app screenshots', generatedAt: new Date().toISOString(), outputs: manifests }, null, 2) + '\n');
console.log(JSON.stringify({ status: 'exported', outputs: manifests }, null, 2));
