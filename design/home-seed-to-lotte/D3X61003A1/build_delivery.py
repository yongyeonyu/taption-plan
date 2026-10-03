#!/usr/bin/env python3
from pathlib import Path
import base64,json,zipfile,hashlib

ROOT=Path(__file__).resolve().parent


def main():
    m=json.loads((ROOT/'manifest.json').read_text());entries=m['entries'];total=m['assetCount']
    rows=json.dumps(entries,ensure_ascii=False).replace('</','<\\/')
    viewer='''<!doctype html><html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>3일마다 다른 세계 건축 · 366장</title><style>
*{box-sizing:border-box}body{margin:0;background:#f4f2e9;color:#3f493e;font-family:-apple-system,BlinkMacSystemFont,sans-serif}main{max-width:1120px;margin:auto;padding:28px}h1{font-size:25px;margin:0 0 10px}p{color:#74816f;line-height:1.6}.toolbar{display:flex;gap:10px;align-items:center;flex-wrap:wrap}button,select{font:inherit;padding:10px 14px;border:1px solid #cdd4c5;border-radius:10px;background:#fff;color:inherit}button{cursor:pointer}input{width:100%;accent-color:#789568}figure{margin:18px 0;background:#fff;border:1px solid #dbe2d3;border-radius:20px;padding:20px;text-align:center}#main-image{width:min(420px,90vw);aspect-ratio:1;display:block;margin:auto;background:repeating-conic-gradient(#f7f8f4 0 25%,#fff 0 50%) 50% /24px 24px;border-radius:16px}figcaption{margin-top:14px;font-size:18px;font-weight:650}#detail{font-size:14px;font-weight:400;line-height:1.6;color:#708066;margin-top:8px}.strip{display:grid;grid-template-columns:repeat(3,minmax(65px,1fr));gap:12px;max-width:720px;margin:auto}.thumb{padding:8px;background:#fff;border:2px solid transparent;min-width:65px}.thumb.active{border-color:#789568}.thumb img{width:100%;max-width:180px;margin:auto;display:block}.thumb span{font-size:12px}.meta{font-size:13px}a{color:#557f59}.jump{display:flex;flex-wrap:wrap;gap:8px}.overview{width:100%;border-radius:12px;margin-top:14px}details{margin-top:22px}summary{cursor:pointer}@media(max-width:560px){main{padding:18px}h1{font-size:21px}figure{padding:12px}.toolbar select{max-width:100%}}
</style><main><h1>3일마다 다른 세계 건축 · 366장</h1><p>122종 × 3일 · 매일 다른 세부 모습 · 씨앗에서 롯데월드타워까지</p><div class="toolbar"><button id="prev" aria-label="이전 날짜">← 이전</button><button id="next" aria-label="다음 날짜">다음 →</button><select id="stage" aria-label="건축 단계 선택"></select><span id="counter"></span></div><p><input id="day" type="range" min="1" max="366" value="1" aria-label="날짜 선택"></p><figure><img id="main-image" alt=""><figcaption id="caption"></figcaption><div id="detail"></div></figure><div class="strip" id="strip"></div><p class="meta" id="history"></p><div class="jump"><button id="previous-stage">← 이전 건물</button><button id="next-stage">다음 건물 →</button></div><details><summary>122종 전체 보기</summary><a href="contact-sheet-128.png"><img class="overview" src="contact-sheet-128.png" alt="122종 세계 건축 전체 미리보기"></a></details><p class="meta">압축을 푼 폴더 안에서 열어주세요. <a href="days.csv">날짜별 목록 CSV</a> · 시대는 대표 시기이며 일별 변화는 창작 표현입니다. 앱 적용은 별도입니다.</p></main><script>
const entries=__DATA__;
const byStage=new Map();for(const x of entries){if(!byStage.has(x.stage))byStage.set(x.stage,[]);byStage.get(x.stage).push(x)}
const range=document.querySelector('#day'),select=document.querySelector('#stage'),strip=document.querySelector('#strip');
for(const [stage,list]of byStage){const o=document.createElement('option');o.value=stage;o.textContent=String(stage).padStart(3,'0')+' '+list[0].name;select.append(o)}
function show(value){const d=Math.max(1,Math.min(entries.length,Number(value))),x=entries[d-1];range.value=d;select.value=x.stage;document.querySelector('#counter').textContent=d+' / '+entries.length+'일';const img=document.querySelector('#main-image');img.src=x.png;img.alt=x.name+' '+x.detail+'일차';document.querySelector('#caption').textContent='D'+String(d).padStart(3,'0')+' · '+x.name;document.querySelector('#detail').textContent=x.changes.join(' · ');document.querySelector('#history').textContent=x.region+' · '+x.representativePeriod+' · 이 건물 '+x.detail+'/3일';document.querySelector('#prev').disabled=d===1;document.querySelector('#next').disabled=d===entries.length;document.querySelector('#previous-stage').disabled=x.stage===1;document.querySelector('#next-stage').disabled=x.stage===122;strip.replaceChildren();for(const y of byStage.get(x.stage)){const b=document.createElement('button');b.className='thumb'+(y.day===d?' active':'');const i=document.createElement('img');i.src=y.png;i.alt=y.name+' '+y.detail+'일차';const t=document.createElement('span');t.textContent='D'+String(y.day).padStart(3,'0')+' · '+y.detail+'일차';b.append(i,t);b.onclick=()=>show(y.day);strip.append(b)}}
range.oninput=()=>show(range.value);select.onchange=()=>show(byStage.get(Number(select.value))[0].day);document.querySelector('#prev').onclick=()=>show(Number(range.value)-1);document.querySelector('#next').onclick=()=>show(Number(range.value)+1);document.querySelector('#previous-stage').onclick=()=>show(Math.max(1,(Number(select.value)-2)*3+1));document.querySelector('#next-stage').onclick=()=>show(Math.min(366,Number(select.value)*3+1));document.onkeydown=e=>{if(e.target.tagName==='SELECT'||e.target.tagName==='INPUT')return;if(e.key==='ArrowLeft')show(Number(range.value)-1);if(e.key==='ArrowRight')show(Number(range.value)+1)};show(1);
</script></html>'''
    # Embed the review sheet so the PNG archive contains exactly 366 PNG files.
    sheet='data:image/svg+xml;base64,'+base64.b64encode((ROOT/'contact-sheet-128.svg').read_bytes()).decode('ascii')
    viewer=viewer.replace('<a href="contact-sheet-128.png">','').replace('</a></details>','</details>').replace('src="contact-sheet-128.png"',f'src="{sheet}"')
    (ROOT/'index.html').write_text(viewer.replace('__DATA__',rows))
    for fmt in ['png','svg']:
        out=ROOT/f'daily-366-three-day-{fmt}.zip'
        with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED) as z:
            for e in entries:z.write(ROOT/e[fmt],e[fmt])
            for file in ['README.md','references.md','manifest.json','days.csv']:z.write(ROOT/file,file)
            if fmt=='png':
                z.write(ROOT/'index.html','index.html')
            else:
                for file in ['catalog.py','draw.py','approved_icons.py','generate.py','render.cjs','validate.py','build_delivery.py']:z.write(ROOT/file,file)
        with zipfile.ZipFile(out) as z:
            assert len([n for n in z.namelist() if n.endswith('.'+fmt)])==366
            assert z.testzip() is None
        print(out.name,out.stat().st_size,hashlib.sha256(out.read_bytes()).hexdigest())


if __name__=='__main__':main()
