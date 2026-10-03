const fs = require('node:fs/promises');
const path = require('node:path');
const sharp = require('/Users/u_mo_c/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp');

async function main() {
  const root = __dirname;
  const manifest = JSON.parse(await fs.readFile(path.join(root, 'manifest.json'), 'utf8'));
  for (const stage of manifest.stages) {
    await sharp(path.join(root, stage.svg)).resize(512, 512).png().toFile(path.join(root, stage.png));
  }
  for (const name of ['contact-sheet', 'contact-sheet-48']) {
    await sharp(path.join(root, `${name}.svg`)).png().toFile(path.join(root, `${name}.png`));
  }
  console.log(`Rendered ${manifest.stages.length} transparent PNG icons and two review sheets.`);
}
main().catch(error => { console.error(error); process.exitCode = 1; });
