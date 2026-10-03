#!/usr/bin/env python3
"""Daily vector details extending the approved 53 architectural keyframes."""
from pathlib import Path
import argparse
import csv
import hashlib
import html
import importlib.util
import json
import math
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parent
TOTAL=366
SOURCE=ROOT.parent/'H53E1003A1'
spec=importlib.util.spec_from_file_location('approved_art',SOURCE/'generate.py')
a=importlib.util.module_from_spec(spec);spec.loader.exec_module(a)
P,R,E,L=a.path,a.rect,a.ellipse,a.line
INK=a.INK
HISTORY=json.loads((SOURCE/'chronology.json').read_text())

# Regional wall/roof and opening types. These identify the approved silhouette;
# the additions are illustrative daily details rather than historical replicas.
FAMILIES={
8:('earth','#C9AF89','#A58D6B'),9:('stone','#BCB9A3','#969A83'),
10:('egypt','#DCC69B','#BDA579'),11:('terrace','#C9A979','#AC875E'),
12:('columns','#D5C09D','#A46D56'),13:('greek','#DED5B9','#B8AF92'),
14:('roman','#CCC2A8','#A2AA92'),15:('dome','#D8C5AA','#A4B3A5'),
16:('pagoda','#D6C09A','#788D86'),17:('terrace','#B9B89F','#8E9B84'),
18:('pointed','#D8C6A6','#92ABA0'),19:('timber','#BEA27B','#8A795B'),
20:('round','#C8BCA0','#999C86'),21:('khmer','#BDB99D','#969E83'),
22:('gothic','#C3C2AF','#839B92'),23:('earth','#D1B994','#AF9376'),
24:('stone','#BFC0A7','#9CA68B'),25:('tile','#DFCEA8','#728B84'),
26:('round','#D8C7AA','#AF9E83'),27:('earth','#C4A684','#897252'),
28:('tudor','#E0D0B0','#766753'),29:('earth','#BCA586','#A78D71'),
30:('pointed','#E7D5B8','#BBC0A7'),31:('tile','#E5DCC6','#738A85'),
32:('round','#DECAAA','#8B9E91'),33:('dutch','#C7AA91','#8EA699'),
34:('rococo','#E2CBB5','#98B0A1'),35:('greek','#DED9C2','#A8B5A4'),
36:('timber','#C3AC88','#819B87'),37:('victorian','#D7BCA2','#798F92'),
38:('grid','#D1CAB4','#8B9E99'),39:('organic','#E0D5B7','#87A99B'),
40:('prairie','#DBC4A0','#809788'),41:('modern','#E4DFCC','#8AA8A2'),
42:('deco','#D5C5A6','#9BAA9B'),43:('glass','#BCD6CF','#7D9D9D'),
44:('concrete','#BDBDAF','#96A398'),45:('capsule','#DADACA','#8DABA5'),
46:('shell','#E5E2CC','#AEBFAF'),47:('postmodern','#D0B9A6','#90B0A9'),
48:('steel','#BDD0C7','#7F9F9D'),49:('organic','#CFD4C4','#8CA6A0'),
50:('taipei','#A7C7BA','#82A89B'),51:('burj','#B1CDC7','#7A999D'),
52:('shanghai','#B3CFC6','#83A6A5'),53:('lotte','#B3CCBF','#8DADA7')}


def stage_lengths(total):
    if total==356:
        # Fifteen six-day stages, spread through the first52 stages; all53 remain.
        shortened={1+int(i*52/15) for i in range(15)}
        return [6 if i in shortened else 7 for i in range(1,54)]
    if total==365:return [7]*52+[1]
    if total==366:return [7]*52+[2]
    raise ValueError('Supported totals:356,365,366')


def step_for(index,count):
    return round(index*6/(count-1)) if count>1 else 6


def window(x,y,w,h,point=False):
    if point:return a.archdoor(x,y,w,h,'url(#window)',True)
    return R(x,y,w,h,'url(#window)',1,INK,1)+L(x+w/2,y,x+w/2,y+h,'#E6DFC7',.8)


def traditional_roof(x,y,w,family,color):
    if family in ['tile','pagoda','khmer']:
        return P(f'M{x-4} {y+5}Q{x+3} {y+2} {x+w/2} {y-8}Q{x+w-3} {y+2} {x+w+4} {y+5}Q{x+w/2} {y+8} {x-4} {y+5}Z',color,INK,1.5)
    if family in ['dome','pointed','roman']:
        return P(f'M{x-2} {y+4}Q{x-1} {y-10} {x+w/2} {y-14}Q{x+w+1} {y-10} {x+w+2} {y+4}Z',color,INK,1.5)
    if family in ['earth','modern','concrete','grid','glass','capsule','steel','postmodern','deco','taipei','burj','shanghai','lotte']:
        return P(f'M{x-2} {y+2}L{x+4} {y-2}H{x+w+5}L{x+w+1} {y+2}Z',color,INK,1.4)
    return P(f'M{x-3} {y+4}L{x+w/2} {y-10}L{x+w+3} {y+4}Z',color,INK,1.5)


def porch(family,wall,roof):
    # Low entrance expansion keeps the landmark's main shape unobstructed.
    if family in ['greek','columns']:
        b=traditional_roof(45,88,43,family,roof)
        for x in [47,63,83]:b+=R(x,93,4,20,wall,0)
        return b+R(45,110,40,4,wall,0)
    if family in ['terrace','egypt']:
        return P('M45 111L51 82H81L95 114Z',wall,INK,1.7)+L(48,106,90,106,roof,2)+L(49,98,86,98,roof,2)+L(50,90,83,90,roof,2)
    if family=='earth':
        return R(45,81,43,32,wall,0)+R(42,77,49,6,roof,0)+a.archdoor(53,87,27,27,'#78674E')
    if family in ['dome','pointed','gothic','round']:
        return a.archdoor(48,83,34,30,roof,family in ['pointed','gothic'])+a.archdoor(57,94,16,19,'url(#window)',family in ['pointed','gothic'])
    if family in ['shell','organic']:
        return P('M42 112Q35 85 60 81Q84 86 95 112Z',wall,INK,1.7)+P('M52 108Q59 97 73 107','none',roof,2)
    return traditional_roof(45,86,44,family,roof)+L(46,92,46,113,wall,4)+L(88,92,88,113,wall,4)+R(43,111,48,5,wall,0)


def annex(family,wall,roof):
    if family in ['egypt','terrace']:
        return R(93,93,24,17,wall,0)+R(98,85,14,8,wall,0)+L(93,104,117,104,roof,1.3)
    if family in ['stone','earth']:
        return P('M94 110V88Q105 79 118 90V110Z',wall,INK,1.5)+R(101,96,8,13,roof,1)
    if family=='capsule':
        return R(94,81,22,25,wall,0)+E(105,94,6,6,'url(#glass)',INK,1.3)
    if family=='shell':
        return P('M94 110Q85 87 115 78Q108 95 118 110Z',wall,INK,1.5)
    b=R(92,84,25,26,wall,0)+traditional_roof(91,81,27,family,roof)
    b+=window(99,94,11,13,family in ['pointed','gothic'])
    if family in ['timber','tudor']:
        b+=L(96,97,114,105,roof,1.2)+L(97,104,113,94,roof,1.2)
    return b


def gateway(family,wall,roof):
    if family in ['earth','stone','terrace','egypt']:
        return R(11,92,23,18,wall,0)+R(9,88,27,5,roof,0)+R(19,98,8,12,roof,0)
    if family in ['greek','columns']:
        return R(12,88,5,21,wall,0)+R(30,88,5,21,wall,0)+traditional_roof(10,84,27,family,roof)
    if family in ['pointed','gothic','round','dome']:
        return a.archdoor(6,76,32,34,wall,family in ['pointed','gothic'])+a.archdoor(14,87,17,23,roof,family in ['pointed','gothic'])
    if family in ['glass','modern','steel','concrete','taipei','burj','shanghai','lotte']:
        return R(9,85,27,25,'url(#glass)',0)+R(8,80,29,5,roof,0)+L(22,86,22,109,'#D8E1CD',1)
    b=R(12,89,23,20,wall,0)+traditional_roof(10,85,26,family,roof)
    if family=='capsule':b+=E(24,99,6,6,'url(#glass)',INK,1.2)
    else:b+=window(19,95,10,12,family=='postmodern')
    return b


def court(family,wall,roof):
    if family in ['earth','stone','egypt','terrace','timber','tudor']:
        b=P('M18 112L43 106L56 119L30 123Z',wall,INK,1.5)
        b+=P('M21 110V99Q19 91 27 90H34Q42 92 39 100V112Q29 119 21 110Z','#977A54',INK,1.5)
        return b+E(30,93,7,3,'#D1BB8D',INK,1)+P('M41 117V102Q44 97 49 100L51 112Z','#AF8960',INK,1.2)
    return P('M16 112L43 105L59 117L31 125Z',wall,INK,1.5)+E(34,112,13,7,'#739FA9',INK,1.3)+P('M27 112Q32 90 42 108','none','#D5E3CF',2.5)+E(34,111,6,2,'#C4D9D4')


def detail_facade(family,wall,roof,stage):
    x=39 if stage%2 else 42
    if family in ['greek','columns','khmer']:
        b=R(x-3,76,51,5,roof,0)+R(x-3,103,51,4,wall,0)
        for xx in [x+1,x+13,x+26,x+39]:b+=R(xx,81,5,22,wall,0)+R(xx-1,80,7,3,roof,0)
        return b
    if family=='capsule':
        b=''
        for xx in [x-2,x+14,x+30]:b+=R(xx,80,16,24,wall,0)+E(xx+8,91,5,5,'url(#glass)',INK,1.3)
        return b+R(x-4,104,53,4,roof,0)
    if family in ['shell','organic']:
        b=P(f'M{x-4} 104Q{x-9} 82 {x+22} 74Q{x+43} 80 {x+50} 104Z',wall,INK,1.7)
        return b+P(f'M{x+3} 104Q{x+11} 83 {x+33} 85L{x+40} 104Z','url(#glass)',INK,1.5)+L(x+18,84,x+20,104,roof,1.5)
    b=R(x,78,45,24,wall,0)
    if family in ['earth','stone','terrace','egypt']:
        b+=R(x-3,75,51,5,roof,0)
        for xx in [x+4,x+17,x+30]:b+=R(xx,82,9,17,'#75694F',0)
        return b
    if family in ['glass','grid','steel','modern','taipei','burj','shanghai','lotte']:
        return R(x,78,45,24,'url(#glass)',0)+R(x-3,101,51,4,roof,0)+L(x+14,78,x+14,101,'#E3E5D0',2)+L(x+30,78,x+30,101,'#E3E5D0',2)+L(x,89,x+45,89,wall,2)
    for xx in [x+4,x+17,x+30]:b+=window(xx,82,10,18,family in ['pointed','gothic'])
    b+=R(x-3,76,51,4,roof,0)+R(x-3,100,51,4,roof,0)
    if family in ['tudor','timber']:b+=L(x,80,x+45,100,roof,2)
    return b


def architecture(stage,step):
    family,wall,roof=FAMILIES[stage]
    behind=''
    front=''
    names=['승인된 기준 형태']
    if step>=1:
        front+=P('M37 105L79 103L96 114L46 124L27 116Z',wall,INK,1.7)+L(34,113,85,107,roof,2)+L(40,118,91,112,roof,2)+L(45,121,95,115,roof,1.7)
        names+=['넓은 기단·진입 계단']
    if step>=2:
        behind+=annex(family,wall,roof);names+=['지역 양식의 측면 별채·저층 확장']
    if step>=3:
        behind+=gateway(family,wall,roof);names+=['지역 양식의 문루·입구동']
    if step>=4:
        front+=detail_facade(family,wall,roof,stage);names+=['입면 창·아케이드·파사드 확장']
    if step>=5:
        front+=court(family,wall,roof);names+=['마당 시설·정원 또는 저장 마당']
    if step>=6:
        front+=porch(family,wall,roof);names+=['현관·차양·포치 완성']
    return a.history_art(stage)+behind+front,names


def plant_daily(stage,step):
    if stage==1:
        if step==0:body=a.seed(1)
        elif step==1:body=a.seed(2)
        else:
            body=a.seed(2)+P(f'M64 96Q{60-step} 77 64 {81-step*6}','none','#719553',4)
            if step>=2:body+=P('M58 105Q42 121 23 109M66 105Q90 125 106 104','none','#E1CEA1',4.5)
            if step>=3:body+=P('M60 105Q41 109 33 105M65 106Q79 118 91 111','none','#E1CEA1',3)+L(64,73,51,55,'#719553',2.5)+a.leaf(51,55,-35,11)
            if step>=4:body+=a.leaf(64,81-step*6,65,11+step,'#99B974')
            if step>=5:body+=a.leaf(64,83-step*6,-35,9+step)
            if step>=6:body+=P('M39 94L30 99L38 107L47 104Z','#D5AE69',INK,1.2)
        return body,['씨앗 껍질·균열·뿌리·새 잎 성장'][0:1]+[f'성장 세부 단계{step+1}']
    if stage==2:
        count=4+step; height=43+step*5;top=105-height
        body=P(f'M64 105Q{58-step} {top+height*.5} 64 {top}','none','#6E8F50',3.5)+E(64,107,18,4,'#A89771')
        for i in range(count):
            yy=top+6+(i//2)*(height-12)/max(1,math.ceil(count/2)-1)
            body+=a.leaf(64,yy,-40 if i%2==0 else 85,13+step*.8,'#759D5B' if i%2==0 else '#9ABB75')
        if step>=2:body+=P('M63 103L51 109M65 103L78 110','none','#9C7F50',2)
        return body,[f'줄기{height}·잎{count}장·새 가지 성장']
    body=P('M57 108L60 56L68 50L73 108Z','url(#bark)',INK,2)+P('M62 70L42 51M67 68L87 47','none','#967548',3)
    clusters=[(43,65,16),(77,62,17),(62,44,19),(34,42,12),(89,40,14),(53,25,15),(78,20,14),(24,61,13),(108,55,13)]
    for x,y,size in clusters[:3+step]:body+=a.bush(x,y,size)
    body+=P('M62 99L49 109M67 99L83 109','none','#9C7D4E',2)
    return body,[f'나무의 가지와 수관{3+step}개']


def camping(stage,step):
    if stage==4:
        body=E(64,104,24,8,'#AEA58E',INK,1)
        stones=[(43,105),(51,111),(76,110),(84,105),(81,97),(50,97),(64,96)]
        for x,y in stones[:3+step]:body+=E(x,y,5,3,'#ADA99A',INK,1)
        body+=L(48,104,78,97,'#997447',5)+L(49,97,78,105,'#805F40',5)
        flame_top=85-step*7
        body+=P(f'M51 101Q48 91 58 {flame_top+8}L63 {flame_top}Q81 81 77 101Z','#E7A15D',INK,1.5)+P('M59 101Q57 90 68 80Q79 93 72 102Z','#F1D18A','none',0)
        if step>=1:body+=R(93,101,23,9,'#9E7A4D',2)+E(95,105,4,4,'#D7BA87',INK,1)+E(111,105,4,4,'#D7BA87',INK,1)
        if step>=2:body+=R(24,96,13,13,'#A18255',2)
        if step>=3:body+=R(91,94,14,16,'#A18255',2)
        if step>=4:body+=L(30,84,30,61,'#967B51',2)+P('M27 64L18 54L27 44L36 54Z','#E8C178',INK,1.3)
        if step>=5:body+=P('M43 112L49 117H89L93 112Z','#B79667',INK,1)
        if step>=6:body+=P('M22 89Q19 76 26 70Q35 77 35 87Z','#CAB28A',INK,1.3)
        return body,[f'불꽃·돌 테두리·장작·캠프 시설{step+1}단계']
    if stage==5:
        body=a.history_art(stage)
        features=[P('M25 109L63 106L78 115L37 123Z','#BFB39A',INK,1.5)+L(33,116,68,111,'#8D8470',2),R(97,88,18,23,'#A29D88',2),P('M7 110V83Q18 66 36 86V110Z','#BBB4A1',INK,1.7)+P('M15 110V93Q23 81 30 95V110Z','#726F5E',INK,1.2),P('M46 97L53 79L72 77L85 97L80 109L73 94L57 94L52 109Z','#B3A68C',INK,1.5),R(87,98,17,22,'#AA8D66',1)+a.bush(113,107,8),P('M19 77L41 62L61 62L75 58L97 70L99 80L79 69L65 70L44 71L25 86Z','#C6B798',INK,1.5)]
        return body+''.join(features[:step]),[f'바위 입구·측벽·저장 공간{step+1}단계']
    if stage==6:
        body=a.history_art(stage)
        features=[P('M20 109L39 105L96 105L113 113L91 122H40Z','#CDB68E',INK,1.5)+L(27,113,102,113,'#A1835C',2)+L(35,118,95,118,'#A1835C',1.5),P('M37 79Q63 104 91 79Q78 100 64 104Q49 99 37 79Z','#D4BB84',INK,1.5),P('M22 52L60 35L108 51L92 60L61 49L34 60Z','#E0C28B',INK,2),R(91,87,24,21,'#BBA275',1)+L(103,88,103,108,INK,1),a.bush(22,93,10)+a.bush(105,90,8),P('M39 105Q65 119 91 104L102 115L78 124H44L26 115Z','#DACAA2',INK,1.7)+L(40,116,88,116,'#987D54',2)]
        return body+''.join(features[:step]),[f'해먹 지지·짜임·차양·수납{step+1}단계']
    body=a.history_art(stage)
    features=[P('M20 107L43 107L60 120L22 124L11 116Z','#BBA580',INK,1.7)+L(18,116,51,116,'#8B7651',2),P('M82 108V87L99 70L114 107Z','#B39B6B',INK,1.5),P('M16 110V84L28 71L37 105Z','#8AA166',INK,1.5),P('M44 111V83L63 59L86 83V111L76 111V91L64 74L54 91V111Z','#D0B58A',INK,1.7),P('M24 83L54 44L81 49L111 89L109 100L66 59L35 95Z','#A7BA7F',INK,2),R(11,104,34,6,'#967B52',0)+L(10,94,43,97,'#E1D0A5',4)+L(14,84,14,110,'#E1D0A5',3)+L(28,86,28,112,'#E1D0A5',3)+L(42,89,42,113,'#E1D0A5',3)]
    return body+''.join(features[:step]),[f'움막 기단·별채·지붕·현관{step+1}단계']


def artwork(stage,step):
    template=a.artwork(stage)
    defs=template[template.index('<defs>'):template.index('</defs>')+7]
    if stage<=3:body,changes=plant_daily(stage,step)
    elif stage<=7:body,changes=camping(stage,step)
    else:body,changes=architecture(stage,step)
    svg=(f'<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 128 128">{defs}'
         f'<g stroke-linecap="round" stroke-linejoin="round">{E(64,116,43,4,"#A1ADA1")}{a.ground(stage>=22)}{body}</g></svg>')
    return svg,changes


def embed(svg,uid,size,x,y):
    inner=svg.split('>',1)[1].rsplit('</svg>',1)[0]
    for key in ['seed','bark','window','glass','towerClip']:
        inner=inner.replace(f'id="{key}"',f'id="{uid}-{key}"').replace(f'url(#{key})',f'url(#{uid}-{key})')
    return f'<g transform="translate({x} {y}) scale({size/128})">{inner}</g>'


def stage_sheet(groups,size):
    #53 rows allow every variant of every stage to be inspected side by side.
    cell=size+18; left=220 if size==128 else 200; header=90;row_h=size+40;w=left+7*cell+24;h=header+len(groups)*row_h+30
    pieces=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}">',f'<rect width="{w}" height="{h}" fill="#F4F2E9"/>','<g font-family="Apple SD Gothic Neo, Noto Sans CJK KR, sans-serif" fill="#4C5748">',f'<text x="24" y="34" font-size="24" font-weight="700">세계 건축 · 일별{TOTAL}장 · 현재{sum(len(g) for g in groups)}장 비교</text>',f'<text x="24" y="61" font-size="13">단계별 상세 비교 · 그림 안에 날짜나 숫자를 넣지 않았습니다 · {size}px</text>']
    for row,g in enumerate(groups):
        y=header+row*row_h;hist=HISTORY[g[0]['stage']-1]
        pieces+=[f'<text x="18" y="{y+27}" font-size="14" font-weight="700">{g[0]["stage"]:02d} {html.escape(hist["name"])}</text>',f'<text x="18" y="{y+47}" font-size="11">{html.escape(hist["region"])}</text>',f'<text x="18" y="{y+64}" font-size="11">D{g[0]["day"]:03d}–D{g[-1]["day"]:03d} · {len(g)}일</text>']
        for col,item in enumerate(g):
            x=left+col*cell
            pieces.append(R(x,y,cell-4,row_h-6,'#FFF',8,'#D8DED2',1))
            pieces.append(embed((ROOT/item['svg']).read_text(),f'd{item["day"]}',size,x+7,y+5))
            pieces.append(f'<text x="{x+cell/2}" y="{y+size+27}" text-anchor="middle" font-size="11">D{item["day"]:03d}</text>')
    return ''.join(pieces+['</g></svg>'])


def sample_sheet(groups):
    selection=[0,2,3,5,9,12,15,24,27,38,44,49,52]
    return stage_sheet([groups[i] for i in selection],128)


def main():
    global TOTAL
    parser=argparse.ArgumentParser();parser.add_argument('--total',type=int,default=366);args=parser.parse_args();lengths=stage_lengths(args.total);TOTAL=args.total
    out=ROOT/'daily';out.mkdir(exist_ok=True)
    day=1;entries=[];groups=[]
    for stage,count in enumerate(lengths,1):
        group=[]
        for index in range(count):
            step=step_for(index,count);svg,changes=artwork(stage,step);stem=f'day-{day:03d}-stage-{stage:02d}-detail-{index+1:02d}'
            ET.fromstring(svg);(out/f'{stem}.svg').write_text(svg)
            item={'day':day,'stage':stage,'detail':index+1,'daysInStage':count,'geometryStep':step,'name':HISTORY[stage-1]['name'],'region':HISTORY[stage-1]['region'],'representativePeriod':HISTORY[stage-1]['representativePeriod'],'changes':changes,'svg':f'daily/{stem}.svg','png':f'daily/{stem}.png'}
            entries.append(item);group.append(item);day+=1
        groups.append(group)
    assert len(entries)==args.total
    source_manifest_hash=hashlib.sha256((SOURCE/'manifest.json').read_bytes()).hexdigest()
    manifest={'requestID':'D3661003A1','assetCount':args.total,'architectureStageCount':53,'stageLengths':lengths,'schedulePolicy':'356=38 stages of7 days plus15 stages of6 days;365=52 stages of7 days and final1 day;366=52 stages of7 days and final2 days','approvedSourceRequest':'H53E1003A1','approvedSourceManifestSHA256':source_manifest_hash,'dailyPolicy':'Native structural additions and growth, no recoloring/crossfade or in-icon date labels','style':'warm outlined RPG SVG; transparent512px PNG','scope':'Actual daily assets; app integration and device review not performed','historyPolicy':'Same accepted representative chronology; days are growth days, not historical years','entries':entries}
    (ROOT/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    with (ROOT/'days.csv').open('w',newline='',encoding='utf-8-sig') as f:
        w=csv.writer(f);w.writerow(['day','stage','detail','stage_days','name','region','representative_period','daily_detail','svg','png'])
        for x in entries:w.writerow([x['day'],x['stage'],x['detail'],x['daysInStage'],x['name'],x['region'],x['representativePeriod'],'; '.join(x['changes']),x['svg'],x['png']])
    for name,data in [('stage-comparison',stage_sheet(groups,128)),('stage-comparison-48',stage_sheet(groups,48)),('daily-samples',sample_sheet(groups))]:
        (ROOT/f'{name}.svg').write_text(data)
    for start in range(0,len(groups),8):
        for size,suffix in [(128,''),(48,'-48')]:
            (ROOT/f'review-{start//8+1:02d}{suffix}.svg').write_text(stage_sheet(groups[start:start+8],size))
    print(f'Created{len(entries)} actual daily SVGs for53 stages; length sum{sum(lengths)}.')

if __name__=='__main__':main()
