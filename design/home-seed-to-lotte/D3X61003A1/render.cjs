const fs=require('fs');
const path=require('path');
const sharpLocations=[process.env.TAPTION_SHARP_PATH,'sharp','/Users/u_mo_c/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp'].filter(Boolean);
let sharp;
for(const location of sharpLocations){try{sharp=require(location);break}catch(error){if(error.code!=='MODULE_NOT_FOUND')throw error}}
if(!sharp)throw new Error('Sharp is required; install it locally or set TAPTION_SHARP_PATH.');
const root=__dirname;
async function main(){
 const m=JSON.parse(fs.readFileSync(path.join(root,'manifest.json'),'utf8'));
 const files=m.entries.map(x=>x.svg).concat(['contact-sheet-128.svg','contact-sheet-48.svg'],fs.readdirSync(path.join(root,'review')).filter(x=>x.endsWith('.svg')).map(x=>'review/'+x));
 for(let start=0;start<files.length;start+=8){
  await Promise.all(files.slice(start,start+8).map(async p=>{await sharp(path.join(root,p)).png().toFile(path.join(root,p.replace(/\.svg$/,'.png')))}));
 }
 console.log(JSON.stringify({rendered:files.length,daily:m.entries.length,format:'PNG RGBA',size:512}));
}
main().catch(e=>{console.error(e);process.exitCode=1});
