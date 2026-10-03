#!/usr/bin/env python3
from pathlib import Path
import json,zipfile,hashlib
ROOT=Path(__file__).resolve().parent
m=json.loads((ROOT/'manifest.json').read_text());total=m['assetCount'];entries=m['entries']
readme=f'''# 매일 달라지는 세계 건축 · {total}장

수량을366장으로 정정했습니다.53개 건축 단계를 모두 포함하며1–52단계는 각각7일,53단계는365·366일의2일로 배분했습니다.365일인해는D001–D365를 사용하고 윤년에는D366까지 사용할 수 있는 이미지 매핑입니다. 실제 앱 자동 변경은 아직 연결하지 않았습니다.

- daily/: 날짜별 투명PNG512×512 {total}장. 파일명이 날짜와 단계를 가리킵니다.
- index.html: 압축을 푼 뒤 열면 날짜 슬라이더/단계 선택으로 일별 그림을 비교할 수 있습니다. 인터넷 연결은 필요하지 않습니다.
- days.csv / manifest.json: 날짜·단계·지역·대표시기·실제로 그린 세부 변화·파일 매핑.
- 별도SVG 묶음: 같은{total}장의 편집 가능한 원본 벡터. 그림 안에는 날짜나 숫자를 넣지 않았습니다.

자연 단계는 균열·뿌리·잎·가지·수관이 자랍니다. 야영은 장작·불꽃·바위 입구·해먹 짜임·차양·움막 지붕/현관이 바뀝니다. 건축 단계는 고유 기준 형태를 유지하며 기단/계단→별채→문루→회랑/창/입면→마당 시설→현관/차양을 순차적으로 확장합니다. 지역 양식에 따라 돔/기와/박공/평지붕·아치/기둥·캡슐/곡면 등을 다르게 그렸습니다. 색이나 날짜만 바꾼 복사본이 아닙니다.

역사적 지역/대표시기 순서는 확정한 H53E1003A1을 유지했습니다.1–7단계는 비연대 도입이며 대표시기는 양식의 최초 발생일이 아닙니다. 원형에 붙인 세부 구조는 일별 게임 성장 표현을 위한 창작이고 실제 유적/랜드마크를 복원한 도면이 아닙니다.

검증: PNG/SVG 각각{total}개 고유, RGBA512×512·투명모서리·날짜1–{total} 연속·단계53종·인접{total-1}일 모두48px에서50픽셀 이상 차이. 픽셀 비교와 제작 시각 검수는 앱의 실제 화면에서 사용자가 느끼는 차이와 구분합니다.

기존 주간 시안과 앱 자산은 보존했습니다. 현재는 이미지 제작 완료이며 앱 연결·설치·실기기 기능 검증은 수행하지 않았습니다.
'''
(ROOT/'README.md').write_text(readme)
rows=json.dumps(entries,ensure_ascii=False).replace('</','<\\/')
viewer='''<!doctype html><html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>매일 달라지는 세계 건축</title><style>
*{box-sizing:border-box}body{margin:0;background:#f4f2e9;color:#3f493e;font-family:-apple-system,BlinkMacSystemFont,sans-serif}main{max-width:1100px;margin:auto;padding:28px}h1{font-size:24px;margin:0 0 10px}p{color:#74816f;line-height:1.6}.toolbar{display:flex;gap:10px;align-items:center;flex-wrap:wrap}button,select{font:inherit;padding:10px 14px;border:1px solid #cdd4c5;border-radius:10px;background:#fff;color:inherit}button{cursor:pointer}input{width:100%;accent-color:#789568}figure{margin:18px 0;background:#fff;border:1px solid #dbe2d3;border-radius:20px;padding:20px;text-align:center}#main-image{width:min(420px,90vw);aspect-ratio:1;display:block;margin:auto;background:repeating-conic-gradient(#f7f8f4 0 25%,#fff 0 50%) 50% /24px 24px;border-radius:16px}figcaption{margin-top:14px;font-size:18px;font-weight:650}#detail{font-size:13px;font-weight:400;line-height:1.6;color:#708066;margin-top:8px}.strip{display:grid;grid-template-columns:repeat(7,minmax(65px,1fr));gap:8px;overflow:auto}.thumb{padding:6px;background:#fff;border:2px solid transparent;min-width:65px}.thumb.active{border-color:#789568}.thumb img{width:100%;display:block}.thumb span{font-size:11px}.meta{font-size:13px}a{color:#557f59}@media(max-width:560px){main{padding:18px}.strip{grid-template-columns:repeat(7,90px)}h1{font-size:21px}}
</style><main><h1>매일 달라지는 세계 건축 · __TOTAL__장</h1><p>53단계 · 52단계 7일 + 마지막 단계 2일 · 씨앗에서 롯데월드타워까지</p><div class="toolbar"><button id="prev" aria-label="이전 날짜">← 이전</button><button id="next" aria-label="다음 날짜">다음 →</button><select id="stage" aria-label="건축 단계 선택"></select><span id="counter"></span></div><p><input id="day" type="range" min="1" max="__TOTAL__" value="1" aria-label="날짜 선택"></p><figure><img id="main-image" alt=""><figcaption id="caption"></figcaption><div id="detail"></div></figure><div class="strip" id="strip"></div><p class="meta" id="history"></p><p class="meta">압축을 푼 폴더 안에서 열어주세요. <a href="days.csv">날짜별 목록 CSV</a> · 일별 세부 확장은 창작 표현이며 앱 적용은 별도입니다.</p></main><script>
const entries=__DATA__;
const byStage=new Map();for(const x of entries){if(!byStage.has(x.stage))byStage.set(x.stage,[]);byStage.get(x.stage).push(x)}
const range=document.querySelector('#day'), select=document.querySelector('#stage'), strip=document.querySelector('#strip');
for(const [stage,list]of byStage){const o=document.createElement('option');o.value=stage;o.textContent=String(stage).padStart(2,'0')+' '+list[0].name;select.append(o)}
function show(value){const d=Math.max(1,Math.min(entries.length,Number(value))), x=entries[d-1];range.value=d;select.value=x.stage;document.querySelector('#counter').textContent=d+' / '+entries.length+'일';const img=document.querySelector('#main-image');img.src=x.png;img.alt=x.name+' '+x.detail+'번째 세부 이미지';document.querySelector('#caption').textContent='D'+String(d).padStart(3,'0')+' · '+x.name;document.querySelector('#detail').textContent=x.changes.join(' → ');document.querySelector('#history').textContent=x.region+' · '+x.representativePeriod+' · 이 단계 '+x.detail+'/'+x.daysInStage+'일';document.querySelector('#prev').disabled=d===1;document.querySelector('#next').disabled=d===entries.length;strip.replaceChildren();for(const y of byStage.get(x.stage)){const b=document.createElement('button');b.className='thumb'+(y.day===d?' active':'');const i=document.createElement('img');i.src=y.png;i.alt=y.name+' '+y.detail+'일';const t=document.createElement('span');t.textContent='D'+String(y.day).padStart(3,'0');b.append(i,t);b.onclick=()=>show(y.day);strip.append(b)}}
range.oninput=()=>show(range.value);select.onchange=()=>show(byStage.get(Number(select.value))[0].day);document.querySelector('#prev').onclick=()=>show(Number(range.value)-1);document.querySelector('#next').onclick=()=>show(Number(range.value)+1);document.onkeydown=e=>{if(e.target.tagName==='SELECT'||e.target.tagName==='INPUT')return;if(e.key==='ArrowLeft')show(Number(range.value)-1);if(e.key==='ArrowRight')show(Number(range.value)+1)};show(1);
</script></html>'''
(ROOT/'index.html').write_text(viewer.replace('__TOTAL__',str(total)).replace('__DATA__',rows))
for fmt in ['png','svg']:
    out=ROOT/f'daily-{total}-{fmt}.zip'
    with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED) as z:
        for x in entries:z.write(ROOT/x[fmt],x[fmt])
        for file in ['README.md','manifest.json','days.csv']:
            z.writestr(file,('이 압축 파일은 SVG 원본 전용입니다. PNG와 날짜별 미리보기는 daily-366-png.zip에 있습니다.\n\n'+readme) if file=='README.md' and fmt=='svg' else (ROOT/file).read_bytes())
        if fmt=='png':z.write(ROOT/'index.html','index.html')
    with zipfile.ZipFile(out) as z:
        assert len([n for n in z.namelist() if n.endswith('.'+fmt)])==total
    print(out.name,out.stat().st_size,hashlib.sha256(out.read_bytes()).hexdigest())
