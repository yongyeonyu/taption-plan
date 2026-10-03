from pathlib import Path
import json
ROOT=Path(__file__).resolve().parent
# Dates are representative periods or reference buildings, not first inventions.
RAW='''
-|씨앗|자연|seed|0
-|새싹|자연|sprout|0
-|묘목|자연|sapling|0
-|큰 나무|자연|tree|0
-|모닥불|야영|fire|0
-|동굴 거처|야영|cave|0
-|해먹|야영|hammock|0
-|가지 움막|야영|hut|0
-|유르트|중앙아시아·도입|yurt|0
-|수상 움막|열대 지역·도입|stilts|0
-7000|차탈회위크 흙집|튀르키예|base|8
-6000|레펜스키비르 거처|세르비아|trapezoid|0
-5000|신석기 롱하우스|중부 유럽|longhouse|0
-3000|스카라브레이 돌집|스코틀랜드|base|9
-2800|스위스 호상 가옥|스위스|pilehouse|0
-2600|이집트 피라미드|이집트|base|10
-2500|인더스 벽돌 거처|파키스탄|indus|0
-2100|우르 지구라트|이라크|base|11
-1700|미노스 궁전|그리스 크레타|base|12
-1500|카르나크 열주전|이집트|pylon|0
-1400|히타이트 성문|튀르키예|liongate|0
-700|아시리아 궁전|이라크|assyrian|0
-500|페르세폴리스|이란|persian|0
-450|그리스 신전|그리스|base|13
-400|야흐찰 빙고|이란|icehouse|0
-350|그리스 원형극장|그리스|theatre|0
-250|산치 스투파|인도|stupa|0
50|페트라 암벽 신전|요르단|petra|0
80|콜로세움|이탈리아|colosseum|0
125|로마 판테온|이탈리아|base|14
300|푸에블로 구덩이집|미국 남서부|pithouse|0
537|비잔틴 돔|튀르키예|base|15
700|호류지 목탑|일본|base|16
750|마야 계단 신전|멕시코|base|17
800|이슬람 아치 궁전|서아시아|base|18
825|보로부두르|인도네시아|borobudur|0
850|수상 장옥|동남아시아|longstilts|0
900|바이킹 롱하우스|북유럽|base|19
950|프람바난|인도네시아|prambanan|0
1000|누비아 돔 주택|수단|nubian|0
1050|로마네스크 석조|서유럽|base|20
1060|라니키바브 계단우물|인도|stepwell|0
1100|노르웨이 스타브 교회|노르웨이|stave|0
1150|앙코르 사원|캄보디아|base|21
1200|고딕 대성당|프랑스|base|22
1250|절벽 푸에블로|미국 남서부|base|23
1300|짐바브웨 석조 성곽|짐바브웨|base|24
1320|사헬 흙 모스크 양식|말리|mudmosque|0
1350|알람브라 궁전|스페인|alhambra|0
1380|티베트 산지 주택|중국 티베트|tibethouse|0
1400|조선 한옥|한국|base|25
1420|천단 기년전 양식|중국|tiantan|0
1440|잉카 석조 가옥|페루|inca|0
1450|르네상스 팔라초|이탈리아|base|26
1500|푸젠 토루|중국|base|27
1520|이탈리아 트룰리|이탈리아|trulli|0
1550|튜더 목조 주택|영국|base|28
1580|모로코 카스바|모로코|kasbah|0
1600|시밤 흙탑 주택|예멘|base|29
1610|오스만 목조 주택|튀르키예|ottomanhouse|0
1620|이맘 모스크|이란|iwans|0
1630|무굴 돔 궁전|인도|base|30
1630|일본 성곽|일본|base|31
1640|루마니아 목조 교회|루마니아|woodchurch|0
1650|포르투갈 타일 주택|포르투갈|azulejo|0
1660|바로크 궁전|프랑스|base|32
1680|네덜란드 운하집|네덜란드|base|33
1690|포탈라 궁전|중국 티베트|potala|0
1700|조선 누각|한국|pavilion|0
1710|페르시아 바람탑|이란|windtower|0
1720|케이프더치 주택|남아프리카공화국|capedutch|0
1730|교토 마치야|일본|machiya|0
1740|부탄 궁전 양식|부탄|dzong|0
1750|로코코 저택|중부 유럽|base|34
1760|폴리네시아 팔레|사모아|fale|0
1780|유럽 풍차 주택|네덜란드|windmill|0
1800|신고전주의 저택|유럽|base|35
1810|인도네시아 루마가당|인도네시아|rumah|0
1820|가쇼즈쿠리 주택|일본|gassho|0
1850|러시아 목조 주택|러시아|base|36
1860|뉴올리언스 갤러리 주택|미국|galleryhouse|0
1870|빅토리아 주택|영국|base|37
1880|파리 맨사드 주택|프랑스|mansard|0
1889|에펠탑|프랑스|eiffel|0
1890|시카고 철골 빌딩|미국|base|38
1900|아르누보 빌라|벨기에|base|39
1905|카사 바트요|스페인|batllo|0
1910|프레리 주택|미국|base|40
1921|아인슈타인탑|독일|expressionist|0
1926|바우하우스|독일|base|41
1930|아르데코 빌딩|미국|base|42
1930|크라이슬러 빌딩|미국|chrysler|0
1939|낙수장|미국|fallingwater|0
1945|멕시코 색채 주택|멕시코|barragan|0
1950|국제주의 유리 건물|미국|base|43
1955|롱샹 성당|프랑스|ronchamp|0
1959|뉴욕 구겐하임|미국|guggenheimny|0
1960|브루탈리즘|영국|base|44
1967|아비타67|캐나다|habitat|0
1972|메타볼리즘 캡슐|일본|base|45
1973|시드니 오페라하우스|호주|base|46
1975|지오데식 돔|미국|geodesic|0
1977|퐁피두센터|프랑스|pompidou|0
1984|포스트모던 빌딩|미국|base|47
1986|하이테크 빌딩|영국|base|48
1989|루브르 유리 피라미드|프랑스|louvre|0
1996|댄싱하우스|체코|dancing|0
1997|빌바오 곡면 건축|스페인|base|49
1998|페트로나스 트윈타워|말레이시아|petronas|0
1999|부르즈 알 아랍|아랍에미리트|sailtower|0
2001|에덴 프로젝트 온실|영국|biomes|0
2004|타이베이101|대만|base|50
2008|베이징 국가체육장|중국|birdnest|0
2010|부르즈 칼리파|아랍에미리트|base|51
2011|마리나베이샌즈|싱가포르|marinabay|0
2012|CCTV 본사|중국|cctv|0
2012|런던 샤드|영국|shard|0
2012|헤이다르 알리예프 센터|아제르바이잔|heydar|0
2014|보스코 베르티칼레|이탈리아|bosco|0
2015|상하이타워|중국|base|52
2017|톈진 빈하이 도서관|중국|libraryeye|0
2017|롯데월드타워|한국|base|53
'''

def catalog():
    rows=[]
    for i,line in enumerate(RAW.strip().splitlines(),1):
        year,name,region,kind,arg=line.split('|')
        rows.append({'stage':i,'name':name,'region':region,'year':None if year=='-' else int(year),'kind':kind,'arg':int(arg),'dayStart':(i-1)*3+1,'dayEnd':i*3,'dateBasis':'thematic prologue' if year=='-' else 'selected representative period, not origin date'})
    return rows
if __name__=='__main__':
    rows=catalog();print('count',len(rows),'new drawings',sum(x['kind']!='base' for x in rows));(ROOT/'catalog.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
