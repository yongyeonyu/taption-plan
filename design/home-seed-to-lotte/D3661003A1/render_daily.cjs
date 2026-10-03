const fs = require('node:fs/promises');
const path = require('node:path');
const sharp = require('/Users/u_mo_c/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp');
async function main() {
  const root=__dirname;
  const manifest=JSON.parse(await fs.readFile(path.join(root,'manifest.json'),'utf8'));
  for (const entry of manifest.entries) {
    await sharp(path.join(root,entry.svg)).resize(512,512).png().toFile(path.join(root,entry.png));
  }
  const previews=(await fs.readdir(root)).filter(name=>name.endsWith('.svg'));
  for (const name of previews) await sharp(path.join(root,name)).png().toFile(path.join(root,name.replace('.svg','.png')));
  console.log(`Rendered ${manifest.assetCount} daily transparent PNGs and ${previews.length} review sheets.`);
}
main().catch(error=>{console.error(error);process.exitCode=1;});
