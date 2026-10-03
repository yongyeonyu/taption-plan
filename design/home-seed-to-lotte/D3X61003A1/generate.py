#!/usr/bin/env python3
from pathlib import Path
import csv, html, json, math, re
from catalog import catalog
from draw import artwork, a

ROOT=Path(__file__).resolve().parent
CHANGES={
 'seed':['씨앗 껍질','껍질이 갈라지고 뿌리가 뻗음','줄기와 큰 두 잎이 올라옴'],
 'sprout':['두 잎 새싹','줄기가 길어지고 네 잎','더 긴 줄기와 여섯 잎'],
 'sapling':['가느다란 줄기와 두 쌍 수관','가지와 세 쌍 수관','큰 줄기와 네 쌍 수관'],
 'tree':['줄기와 양쪽 수관','윗 수관·오른쪽 가지 확장','아랫 수관·뿌리까지 큰 나무'],
 'fire':['장작과 작은 불꽃','큰 불꽃과 돌 화덕','가로 받침대와 조리 냄비'],
 'cave':['바위와 깊은 동굴 입구','입구 바위와 외벽 돌출','목재 차양과 입구 발판'],
 'hammock':['기둥과 해먹','양쪽 나무 지붕·깊은 해먹','큰 차양·해먹 쿠션'],
 'hut':['가지 지붕과 움막 입구','지붕 높이·양쪽 지지 구조','앞 차양·지지 기둥·계단'],
 'yurt':['돔 텐트와 문','큰 천막·넓은 벽 무늬','띠 장식·입구 차양·발판'],
 'stilts':['기둥 위 초가지붕','수상 데크·큰 창','사다리와 물가 갈대'],
 'trapezoid':['사다리꼴 거처와 박공','측벽·안쪽 화덕','전면 석벽과 계단'],
 'longhouse':['길게 이어진 초가','큰 창·목재 벽 띠','앞쪽 별채 박공·계단'],
 'pilehouse':['물 위 기둥과 큰 박공','긴 데크·양쪽 창','수변 사다리·갈대'],
 'indus':['벽돌집 본체','옥상층·측면 증축','오른쪽 벽체·수로'],
 'pylon':['사다리꼴 쌍탑 성문','앞쪽 열주','오벨리스크·넓은 기단'],
 'liongate':['석벽과 큰 아치','양쪽 사자 모양 석상','성벽 상부 요철·기단'],
 'assyrian':['평지붕 궁전과 아치','양쪽 날개 수호상 표현','상부 요철·계단'],
 'persian':['동물 장식 기둥과 기단','상부 보·옆 석벽','전면 열주와 긴 보'],
 'icehouse':['원뿔 빙고와 둥근 띠','왼쪽 입구 건물','물 저장부와 환기탑'],
 'theatre':['원형극장 바닥과 첫 객석','두 번째 객석·무대 열주','세 번째 객석·무대 박공'],
 'stupa':['반구 스투파','왼쪽 토라나 문','오른쪽 문·중앙 계단'],
 'petra':['암벽과 아래 열주','상층 열주·중앙 둥근 지붕','깊은 중앙 입구·석조 계단'],
 'colosseum':['낮은 원형 아케이드','상층 아케이드·수평 띠','높은 외벽·열린 상부 윤곽'],
 'pithouse':['땅속 거처와 입구','박공 지붕·경사 사다리','입구 차양·앞 발판'],
 'borobudur':['세 층 기단과 작은 스투파','네 층 기단·추가 스투파','다섯 층 기단·중앙 계단'],
 'longstilts':['긴 수상 주택과 기둥','긴 데크·난간','출입 지붕·사다리·갈대'],
 'prambanan':['중앙 첨탑 사원','왼쪽 첨탑','오른쪽 첨탑·큰 기단'],
 'nubian':['주 돔과 녹색 벽','오른쪽 푸른 돔','왼쪽 흙빛 돔·벽 장식'],
 'stepwell':['낮은 계단우물','깊은 계단·왼쪽 열주','더 깊은 계단·오른쪽 지붕'],
 'stave':['중앙 교회와 높은 지붕','넓은 아래 지붕·벽체','꼭대기 탑·창·계단'],
 'mudmosque':['첫 흙탑과 연결 벽','두 번째 흙탑','세 번째 흙탑·벽 요철·계단'],
 'alhambra':['네 아치가 있는 회랑','양쪽 궁전 탑','중앙 연못·분수·정원'],
 'tibethouse':['경사진 흰 벽과 창','옥상층과 작은 창','양쪽 흰 벽 증축'],
 'tiantan':['원형 기단·아래 푸른 지붕','두 번째 원형층과 지붕','세 번째 지붕·기둥·계단'],
 'inca':['경사진 돌벽과 초가','왼쪽 석조 구획·큰 창','오른쪽 가옥과 박공'],
 'trulli':['큰 원뿔 지붕 집','왼쪽 작은 원뿔 집','오른쪽 원뿔 집·기단'],
 'kasbah':['흙 성곽과 첫 모서리 탑','둘째 탑·성벽 요철','큰 돌출 성문·앞 계단'],
 'ottomanhouse':['튀어나온 위층과 창','왼쪽 돌출 목재 창실','오른쪽 창실·기단'],
 'iwans':['높은 푸른 이완과 첫 탑','둘째 탑·문 상부 무늬','옆 돔·입구 건물·계단'],
 'woodchurch':['긴 교회와 가파른 목탑','상부 창·첨탑','오른쪽 박공·계단'],
 'azulejo':['흰 박공 집','푸른 타일 문양·층 띠','왼쪽 돌출부·큰 입구'],
 'potala':['흰 기단과 붉은 중심부','외벽 창·앞 계단','높은 지붕·옆 누각'],
 'pavilion':['물가 누각과 지붕','목재 난간','상층 누각·추가 지붕'],
 'windtower':['큰 바람탑과 돔','왼쪽 아케이드','오른쪽 작은 바람탑·연못'],
 'capedutch':['곡선 박공과 긴 집','원형 창·굴뚝','오른쪽 초가지붕 건물'],
 'machiya':['긴 목재 격자 집','아래 기와지붕·격자 벽','천 차양·입구 등·계단'],
 'dzong':['중앙 궁전과 경사진 벽','양쪽 탑과 지붕','상부 누각·중앙 입구'],
 'fale':['열린 기둥과 둥근 지붕','넓은 지붕 띠·바닥','실내 가구·계단·수변 식물'],
 'windmill':['풍차탑과 두 날개','세 번째 날개·옆 작업실','네 날개·둘레 데크'],
 'rumah':['양 끝이 치솟는 지붕','안쪽 뿔 지붕·데크','중앙 큰 뿔 지붕·계단'],
 'gassho':['가파른 초가와 벽','큰 지붕 창·지붕 살','앞쪽 초가 증축·기단'],
 'galleryhouse':['두 층 긴 주택','위층 갤러리·아래 기둥','아래 난간·긴 차양'],
 'mansard':['맨사드 지붕과 두 층','세 개 돌출 지붕 창','양쪽 증축·중앙 입구'],
 'eiffel':['격자 철탑의 큰 윤곽','철골 대각선·네 기단','상층 전망대·분수 정원'],
 'batllo':['물결 지붕과 창','곡선 발코니·왼쪽 탑','물결 1층 창·상부 십자'],
 'expressionist':['곡선 천문대와 돔','중앙 창·둥근 하부','넓은 곡선 입구와 계단'],
 'chrysler':['단차 타워와 금속 왕관','측면 단차·독수리 장식 표현','넓은 기단·왕관 장식'],
 'fallingwater':['석조 중심과 긴 아래 테라스','중간 유리층·돌출 테라스','위층 테라스·아래 폭포'],
 'barragan':['높은 흙빛 벽·붉은 낮은 벽','노란 구획·푸른 높은 벽','수면·붉은 세로 벽'],
 'ronchamp':['흰 본당·짙은 곡선 지붕','왼쪽 곡선 탑','오른쪽 높은 탑·작은 창'],
 'guggenheimny':['뒤집힌 원뿔과 첫 띠','두 번째 띠·옆 건물','세 번째 띠·긴 출입층'],
 'habitat':['세 개 겹친 주거 블록','여섯 블록','아홉 블록·옥상 정원'],
 'geodesic':['돔과 방사형 격자','높은 돔·중앙 격자','최종 격자·유리 출입구'],
 'pompidou':['외부 철골과 유리층','붉은 경사 통로·녹색 설비','푸른 외부 배관·기단'],
 'louvre':['큰 유리 피라미드','왼쪽 작은 피라미드','오른쪽 피라미드·물가'],
 'dancing':['휘어진 유리 탑과 옆 탑','곡선 유리 격자·위 지붕','측면 받침 구조·출입층'],
 'petronas':['쌍둥이 첨탑','두 타워를 잇는 스카이브리지','넓은 기단·낮은 돔'],
 'sailtower':['큰 돛과 유리 면','상부 헬리패드·수평 프레임','바다 위 진입 다리·출입층'],
 'biomes':['큰 온실 한 동','왼쪽 온실','오른쪽 온실·정원 입구'],
 'birdnest':['타원 경기장과 첫 교차 구조','추가 사선 외피','촘촘한 입체 외피·입구 기단'],
 'marinabay':['세 타워와 긴 스카이파크','옥상 정원·수영장','곡선 아래 건물·물가'],
 'cctv':['닫힌 고리형 본체','외벽 격자·사선 철골','양쪽 하부 진입 건물'],
 'shard':['날카로운 유리 조각 타워','양쪽 낮은 유리 조각','기단 건물·앞 계단'],
 'heydar':['긴 파도 지붕과 유리 면','왼쪽 큰 곡면','연속 곡면 기단·패널 선'],
 'bosco':['두 개 직사각형 타워·첫 식재','중층 발코니와 나무','하층 발코니·옥상 나무'],
 'libraryeye':['반원형 도서관과 중앙 구체','곡선 벽과 선반','더 많은 선반·입구 기단'],
}


def changes(s):
    if s['kind']!='base':return CHANGES[s['kind']]
    w=s['arg']
    packs={8:'흙집 증축',9:'돌벽 구획',10:'작은 피라미드·오벨리스크',11:'계단·기단',12:'궁전 열주',13:'신전 열주',14:'포르티코 열주',15:'양쪽 작은 돔',16:'양쪽 기와 누각',17:'계단·옆 신전',18:'양쪽 아치·돔',19:'초가지붕·입구 박공',20:'측면 석탑',21:'양쪽 사원 지붕',22:'양쪽 고딕 첨탑',23:'추가 흙집·사다리',24:'옆 성벽·원뿔 탑',25:'양쪽 한옥채',26:'옆 궁전 건물',27:'원형 지붕·안마당 건물',28:'양쪽 목조 박공',29:'추가 흙탑',30:'양쪽 돔·수면',31:'양쪽 기와 누각',32:'궁전의 날개 건물',33:'운하·돌다리',34:'양쪽 곡선 박공',35:'양쪽 고전식 날개',36:'목조 박공 증축',37:'측면 박공 증축',38:'높이가 다른 건물 동',39:'양쪽 주택 증축',40:'긴 돌출 지붕·굴뚝',41:'큰 유리 구획·흰 건물 동',42:'단차 기단 건물',43:'높이가 다른 유리 동',44:'큰 콘크리트 블록',45:'추가 주거 캡슐',46:'추가 조개껍질 지붕',47:'단차 기단 건물',48:'추가 유리 동',49:'추가 금속 곡면',50:'고층 기단·진입 건물',51:'고층 기단·진입 건물',52:'고층 기단·진입 건물',53:'고층 기단·진입 건물'}
    return [f'{s["name"]} 초기 본체',f'본체 성장·{packs[w]} 1차',f'완성 본체·{packs[w]} 2차']


def embed(svg,uid,x,y,size):
    inner=svg.split('>',1)[1].rsplit('</svg>',1)[0]
    for key in re.findall(r'id="([^" ]+)"',inner):
        inner=inner.replace(f'id="{key}"',f'id="{uid}-{key}"').replace(f'url(#{key})',f'url(#{uid}-{key})')
    return f'<g transform="translate({x} {y}) scale({size/128})">{inner}</g>'


def stage_sheet(stages,size=128):
    cols,tile,rh=(10,180,210) if size==128 else (10,113,138)
    w=cols*tile+48;h=96+math.ceil(len(stages)/cols)*rh+20
    b=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}"><rect width="100%" height="100%" fill="#F4F2E9"/><g font-family="Apple SD Gothic Neo,sans-serif" fill="#3F493E">',
       '<text x="24" y="35" font-size="24" font-weight="700">3일마다 다른 세계 건축 · 122종 · 366장</text>',
       '<text x="24" y="64" font-size="13" fill="#758071">씨앗·야영 도입 뒤 대표 시기순 / 각 단계의 3일차 모습</text>']
    for i,s in enumerate(stages):
        x=24+i%cols*tile;y=86+i//cols*rh
        b+=[a.rect(x,y,tile-9,rh-9,'#FFF',9,'#DDE2D6',1),f'<text x="{x+9}" y="{y+20}" font-size="10" fill="#7B8775">{s["stage"]:03d} · D{s["dayStart"]:03d}–{s["dayEnd"]:03d}</text>',embed(artwork(s,2),f's{s["stage"]}',x+(tile-9-size)/2,y+25,size)]
        name=s['name']
        if size==128:
            b+=[f'<text x="{x+(tile-9)/2}" y="{y+rh-37}" font-size="11" text-anchor="middle">{html.escape(name)}</text>',f'<text x="{x+(tile-9)/2}" y="{y+rh-21}" font-size="9" fill="#7B8775" text-anchor="middle">{html.escape(s["region"])}</text>']
        else:
            lines=[name[:10],name[10:]] if len(name)>10 else [name]
            b+=[f'<text x="{x+(tile-9)/2}" y="{y+rh-35+j*12}" font-size="8" text-anchor="middle">{html.escape(label)}</text>' for j,label in enumerate(lines)]
            b+=[f'<text x="{x+(tile-9)/2}" y="{y+rh-11}" font-size="7" fill="#7B8775" text-anchor="middle">{html.escape(s["region"])}</text>']
    return ''.join(b)+ '</g></svg>'


def review_sheet(stages,page,size=128):
    rh=174 if size==128 else 108;tile=152 if size==128 else 80
    w=220+tile*3+24;h=75+len(stages)*rh+20
    b=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}"><rect width="100%" height="100%" fill="#F4F2E9"/><g font-family="Apple SD Gothic Neo,sans-serif" fill="#3F493E">',f'<text x="20" y="32" font-size="21" font-weight="700">3일 변화 검수 {page:02d} · {size}px</text>','<text x="20" y="57" font-size="12" fill="#758071">본체와 지붕·열주·날개 건물이 매일 달라집니다</text>']
    for i,s in enumerate(stages):
        y=74+i*rh
        b+=[a.rect(12,y,w-24,rh-7,'#FFF',10,'#DDE2D6',1),f'<text x="25" y="{y+29}" font-size="12" font-weight="650">{s["stage"]:03d} {html.escape(s["name"])}</text>',f'<text x="25" y="{y+50}" font-size="10" fill="#758071">{html.escape(s["region"])}</text>']
        for d in range(3):
            x=220+tile*d
            b+=[embed(artwork(s,d),f'p{page}-s{s["stage"]}-d{d}',x+(tile-size)/2,y+9,size),f'<text x="{x+tile/2}" y="{y+size+27}" text-anchor="middle" font-size="10">D{s["dayStart"]+d:03d} · {d+1}일차</text>']
    return ''.join(b)+'</g></svg>'


def main():
    stages=catalog();assert len(stages)==122
    years=[s['year'] for s in stages if s['year'] is not None];assert years==sorted(years)
    daily=ROOT/'daily';daily.mkdir(exist_ok=True);review=ROOT/'review';review.mkdir(exist_ok=True)
    entries=[]
    for s in stages:
        s['dailyChanges']=changes(s)
        for d in range(3):
            day=s['dayStart']+d
            stem=f'day-{day:03d}-stage-{s["stage"]:03d}-{s["kind"]}-{s["arg"]:02d}-detail-{d+1}'
            (daily/f'{stem}.svg').write_text(artwork(s,d))
            entries.append({'day':day,'stage':s['stage'],'detail':d+1,'daysInStage':3,'name':s['name'],'region':s['region'],'year':s['year'],'changes':[s['dailyChanges'][d]],'svg':f'daily/{stem}.svg','png':f'daily/{stem}.png','representativePeriod':'자연·야영 도입' if s['year'] is None else f'{"기원전 "+str(-s["year"]) if s["year"]<0 else s["year"]}년 대표 시기'})
    m={'requestID':'D3X61003A1','assetCount':366,'stageCount':122,'stageLengths':[3]*122,'width':512,'height':512,'background':'transparent','appIntegrated':False,'authoringMethod':'Editable native SVG geometry; Sharp PNG export. No generative image service.','chronologyPolicy':'10 thematic nature/camping subjects, followed by 112 world architecture subjects in selected representative year order. Vernacular dates are curatorial periods, not first occurrences; silhouettes are stylized game illustrations, not reconstructions.','dailyPolicy':'The subject changes every three days. Main volume, roof, wings, columns, facade or context changes inside each three-day subject; no date labels or crossfades in artwork.','stages':stages,'entries':entries}
    (ROOT/'catalog.json').write_text(json.dumps(stages,ensure_ascii=False,indent=2)+'\n')
    (ROOT/'manifest.json').write_text(json.dumps(m,ensure_ascii=False,indent=2)+'\n')
    with (ROOT/'days.csv').open('w',newline='',encoding='utf-8-sig') as f:
        writer=csv.writer(f);writer.writerow(['day','stage','day_in_stage','name','region','representative_year','daily_change','png','svg'])
        for e in entries:writer.writerow([e['day'],e['stage'],e['detail'],e['name'],e['region'],e['year'],' / '.join(e['changes']),e['png'],e['svg']])
    for size in [128,48]:(ROOT/f'contact-sheet-{size}.svg').write_text(stage_sheet(stages,size))
    for i in range(math.ceil(len(stages)/12)):
        part=stages[i*12:(i+1)*12]
        for size in [128,48]:(review/f'three-days-{i+1:02d}-{size}.svg').write_text(review_sheet(part,i+1,size))
    print(f'Created {len(entries)} SVGs, {len(stages)} subjects, two contact sheets and 22 review sheets.')


if __name__=='__main__':main()
