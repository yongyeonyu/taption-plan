#!/usr/bin/env python3
"""Editable weekly artwork; leaves the application's current asset catalog intact."""
from pathlib import Path
import csv
import html
import json
import math

ROOT = Path(__file__).resolve().parent
INK = '#594939'
NAMES = [
    ('seed', '작은 씨앗'), ('cracked-seed', '깨어난 씨앗'),
    ('root', '첫 뿌리'), ('first-shoot', '첫 새싹'),
    ('two-leaves', '두 잎 새싹'), ('four-leaves', '네 잎 새싹'),
    ('young-sapling', '어린 묘목'), ('sapling', '튼튼한 묘목'),
    ('young-tree', '작은 나무'), ('full-tree', '풍성한 나무'),
    ('tree-platform', '나무 위 발판'), ('tree-room', '나무 속 작은 방'),
    ('tree-house', '첫 나무집'), ('tree-balcony', '발코니 나무집'),
    ('wood-cabin', '통나무 오두막'), ('stone-cottage', '돌담 집'),
    ('brick-home', '벽돌 집'), ('two-storeys', '2층 주택'),
    ('three-storeys', '3층 주택'), ('town-house', '도시형 주택'),
    ('twin-houses', '작은 주택 단지'), ('corner-block', '상가 건물'),
    ('brick-block', '벽돌 빌딩'), ('modern-block', '현대식 빌딩'),
    ('office', '작은 오피스'), ('office-annex', '확장 오피스'),
    ('glass-block', '유리 빌딩'), ('glass-highrise', '높아진 유리 빌딩'),
    ('terraced-tower', '테라스 타워'), ('city-tower', '도심 타워'),
    ('skyline', '스카이라인'), ('mixed-use', '복합 타워'),
    ('high-rise', '고층 타워'), ('slender-tower', '가늘어진 타워'),
    ('tapered-tower', '상승하는 타워'), ('core-76', '초고층 코어'),
    ('frame-84', '철골 84층'), ('frame-92', '철골 92층'),
    ('frame-100', '철골 100층'), ('frame-108', '철골 108층'),
    ('frame-116', '철골 116층'), ('frame-123', '철골 정상 도달'),
    ('lower-glass', '아래층 유리 외벽'), ('middle-glass', '중층 유리 외벽'),
    ('full-glass', '전체 유리 외벽'), ('first-crown', '첫 왕관 곡선'),
    ('split-crown', '두 갈래 왕관'), ('finished-tower', '완성된 타워 외관'),
    ('podium', '타워 앞 포디엄'), ('roof-garden', '포디엄 옥상 정원'),
    ('plaza', '타워 광장'), ('illuminated-crown', '빛나는 전망층'),
    ('lotte-world-tower', '롯데월드타워'),
]


def path(d, fill, stroke=INK, width=1.7, extra=''):
    return f'<path d="{d}" fill="{fill}" stroke="{stroke}" stroke-width="{width}" {extra}/>'


def rect(x, y, w, h, fill, radius=1.5, stroke=INK, width=1.5, extra=''):
    return (f'<rect x="{x:.2f}" y="{y:.2f}" width="{w:.2f}" height="{h:.2f}" '
            f'rx="{radius}" fill="{fill}" stroke="{stroke}" stroke-width="{width}" {extra}/>')


def ellipse(x, y, rx, ry, fill, stroke='none', width=1):
    return f'<ellipse cx="{x}" cy="{y}" rx="{rx}" ry="{ry}" fill="{fill}" stroke="{stroke}" stroke-width="{width}"/>'


def line(x1, y1, x2, y2, color=INK, width=1.3):
    return f'<path d="M{x1:.2f} {y1:.2f}L{x2:.2f} {y2:.2f}" fill="none" stroke="{color}" stroke-width="{width}"/>'


def leaf(x, y, angle, size=12, color='#77A45C'):
    return (f'<g transform="translate({x} {y}) rotate({angle})">'
            + path(f'M0 0Q{-size} {-size*.7} {-size*.75} {-size*1.6}Q{size*.2} {-size*1.5} 0 0Z', color, '#4F7348', 1.4)
            + line(0, 0, -size*.5, -size, '#C5D791', 1.3) + '</g>')


def bush(x, y, size=7, color='#7AA16B'):
    return (ellipse(x-size*.65, y, size*.7, size*.8, color)
            + ellipse(x+size*.45, y-1, size*.8, size*.8, color)
            + ellipse(x, y-size*.45, size*.8, size*.8, '#A0BD7F'))


def spark(x, y, size=5, color='#EBC679'):
    return path(f'M{x} {y-size}Q{x+1} {y-1} {x+size} {y}Q{x+1} {y+1} {x} {y+size}Q{x-1} {y+1} {x-size} {y}Q{x-1} {y-1} {x} {y-size}Z', color, 'none', 0)


def ground(urban=False):
    top = '#D9DFD1' if urban else '#B8C99A'
    side = '#AAB6A1' if urban else '#839D6F'
    return path('M16 103Q64 87 112 103L112 108Q64 124 16 108Z', side, '#667A5B', 1.2) + ellipse(64, 103, 48, 13, top, '#78916B', 1.4) + path('M25 104Q52 96 87 101Q98 103 104 104', 'none', '#E8E6C9', 1.2)


def seed(week):
    parts = [ellipse(64, 104, 25, 6, '#7B6346', 'none'),
             path('M45 94Q42 76 63 70Q84 79 80 95Q68 109 52 103Z', 'url(#seed)', '#77502F', 2),
             path('M62 76Q53 91 59 101', 'none', '#A46C38', 2),
             path('M66 78Q75 82 75 90', 'none', '#F3D59A', 2)]
    if week >= 2:
        parts = [parts[0],
                 path('M55 74Q36 78 43 96Q50 105 58 103L59 92L54 86L59 81Z', 'url(#seed)', '#77502F', 2),
                 path('M69 74Q88 82 84 97Q76 108 67 102L67 93L72 86L67 81Z', 'url(#seed)', '#77502F', 2),
                 path('M50 81Q43 91 50 98M76 81Q82 90 77 97', 'none', '#F4DFA6', 2)]
        parts.append(path('M64 75L59 82L67 88L61 95L67 101', 'none', '#573D2B', 2.1))
        parts.append(path('M58 100Q49 109 44 110M48 105L44 102', 'none', '#EEE0B4', 2.5))
    if week >= 3:
        parts.append(path('M68 82Q77 66 73 57', 'none', '#67934D', 3.5))
        parts.append(leaf(73, 58, 60, 9))
    if week >= 4:
        parts.append(path('M68 90Q53 70 61 51', 'none', '#5D8946', 4))
        parts.extend([leaf(61, 55, -37, 15), leaf(61, 55, 80, 14, '#97BC72')])
    return ''.join(parts)


def plant(week):
    count = {5:2, 6:4, 7:6, 8:8}[week]
    height = {5:39, 6:47, 7:59, 8:67}[week]
    top = 103-height
    parts = [path(f'M64 103Q59 {top+height*.48} 64 {top}', 'none', '#5D814C' if week<7 else '#926C43', 3.5 if week<7 else 5),
             ellipse(64, 104, 19, 4, '#A49771')]
    for i in range(count):
        y = top+5+(i//2)*(height-13)/max(1, count//2-1)
        parts.append(leaf(63, y, -45 if i%2==0 else 85, 12+week*.8,
                          '#719B58' if i%2==0 else '#9ABB75'))
    if week >= 7:
        parts.append(path('M64 100L57 107M64 102L74 107', 'none', '#926C43', 3))
    if week == 8:
        parts.extend([bush(35, 105, 5), bush(91, 104, 6)])
    return ''.join(parts)


def tree(week):
    top = max(15, 31-(week-9)*4)
    parts = [path(f'M58 106L60 52L68 50L70 106Z', 'url(#bark)', '#6B5139', 2),
             path('M62 76L42 57M67 66L83 47M63 105L49 110M69 103L80 109', 'none', '#81643F', 5),
             ellipse(48, top+21, 23, 20, '#6C9457', '#507045', 1.7),
             ellipse(82, top+23, 23, 23, '#779F60', '#507045', 1.7),
             ellipse(63, top+8, 24, 22, '#A1BD79', '#507045', 1.7),
             ellipse(43, top+13, 11, 7, '#C3D394'),
             ellipse(75, top+1, 10, 6, '#C3D394')]
    if week >= 11:
        parts.append(path('M36 76L73 70L92 78L55 84Z', '#C49C62', '#72583A', 1.8))
        parts.extend([line(47, 81, 43, 102, '#866342', 3), line(84, 82, 85, 104, '#866342', 3)])
    if week >= 12:
        parts.append(rect(51, 62, 28, 21, '#E4C48C', 2))
        parts.append(path('M62 83V71Q68 65 73 71V83Z', '#966C49', INK, 1.6))
    if week >= 13:
        parts.append(path('M43 65L64 49L86 65L81 69L64 56L47 69Z', '#A56548', INK, 1.8))
        parts.extend([rect(52, 68, 7, 8, '#A9D0D1', 1), rect(74, 67, 6, 7, '#A9D0D1', 1)])
    if week >= 14:
        parts.append(path('M46 84L82 79L96 86L60 92Z', '#E7C78B', INK, 1.6))
        parts.extend([line(x, 84, x, 75, '#866342', 1.6) for x in [48, 57, 67, 78, 88]])
        parts.extend([line(47, 76, 88, 70, '#866342', 1.8), path('M38 104L48 91L56 91L47 104Z', '#C79F67', INK, 1.5)])
    parts.extend([bush(33, 105, 6), bush(97, 104, 7)])
    return ''.join(parts)


def house(x, bottom, width, floors, wall, roof, style=0):
    side = 12
    height = 15 + floors*13
    top = bottom-height
    right = x+width
    parts = [path(f'M{right} {top}L{right+side} {top-6}V{bottom-5}L{right} {bottom}Z', '#AE9877', INK, 1.7),
             rect(x, top, width, height, wall, 1.5),
             path(f'M{x-5} {top+2}L{x+width*.46} {top-14}L{right+5} {top+2}L{right} {top+7}L{x+width*.46} {top-7}L{x} {top+7}Z', roof, INK, 2),
             path(f'M{x+width*.46} {top-14}L{x+width*.46+side} {top-20}L{right+side+4} {top-3}L{right+5} {top+2}Z', '#835E48', INK, 1.5)]
    if style in [0, 1]:
        for y in range(int(top+5), int(bottom-2), 6):
            parts.append(line(x+2, y, right-2, y, '#B68E60' if style==0 else '#AC9A7D', .7))
    for row in range(floors):
        y=top+8+row*13
        for col in range(2):
            wx=x+7+col*(width-18)
            parts.extend([rect(wx, y, 7, 8, 'url(#window)', .8, INK, 1), line(wx+3.5, y+.5, wx+3.5, y+7.5, '#E8D8B0', .8)])
        parts.append(rect(right+3, y-2, 5, 7, '#6E9B9F', .8, INK, 1))
    parts.append(path(f'M{x+width*.43} {bottom}V{bottom-14}Q{x+width*.57} {bottom-19} {x+width*.7} {bottom-14}V{bottom}Z', '#7C654C', INK, 1.3))
    parts.extend([rect(x+width*.14, top-16, 5, 11, '#B87E59', .5), bush(x-7, bottom-1, 5), bush(right+14, bottom-6, 5)])
    return ''.join(parts)


def homes(week):
    if week <= 20:
        floors={15:1,16:1,17:1,18:2,19:3,20:4}[week]
        walls={15:'#DEBD87',16:'#D6CFB1',17:'#C98267',18:'#E1B681',19:'#D3A789',20:'#B9C8C0'}
        roofs={15:'#B17A48',16:'#758663',17:'#A05E49',18:'#826674',19:'#5C7D7F',20:'#4D7687'}
        parts=[house(39, 105, 43, floors, walls[week], roofs[week], min(2,week-15))]
        if week==16:
            parts.append(path('M19 105L43 105L43 97L19 97Z', '#C4BB9A', INK, 1.4))
        if week==17:
            parts.extend([line(20, 104, 32, 104, '#A1684F', 3), rect(23, 89, 9, 14, '#D4A887', 1)])
        if week==18:
            parts.extend([rect(41, 76, 39, 7, '#E8CE9E', 1), line(42, 73, 80, 73, INK, 1.5)])
        if week==19:
            parts.extend([path('M84 105V77L103 75V101Z', '#C2AD83', INK, 1.5), rect(88, 80, 8, 10, '#86B7BC', 1)])
        if week==20:
            parts.append(path('M25 106L40 101L86 106L75 111Z', '#CEBE98', INK, 1.3))
        return ''.join(parts)
    return house(18, 108, 35, 2, '#CF9B79', '#967062', 2) + house(64, 105, 30, 3, '#C8C6A5', '#5C7E77', 2) + path('M52 108L65 103L75 108L63 115Z', '#E2D1A4', INK, 1.2)


def block(week):
    heights = [48, 54, 57, 61, 66, 70, 74, 78, 82, 86, 89, 92, 95]
    h=heights[week-22]
    top=105-h
    width=45 if week<27 else 39 if week<31 else 34
    x=61-width/2
    side=13
    warm=week<=23
    wall=['#D1B992','#BC8570'][week-22] if warm else '#D9DCCB' if week<27 else '#A8C9D2'
    parts=[path(f'M{x+width} {top}L{x+width+side} {top-5}V100L{x+width} 105Z', '#9BADA8' if not warm else '#97745E', INK, 1.6), rect(x,top,width,h,wall,1), path(f'M{x} {top}L{x+13} {top-5}H{x+width+13}L{x+width} {top}Z', '#EEE4C5' if week<27 else '#CFE4E2', INK,1.4)]
    row_count=4+(week-22)//2
    for row in range(row_count):
        y=top+7+row*(h-16)/row_count
        if week>=27:
            parts.append(rect(x+4,y,width-8,4.5,'#668F9F',.5,'#CDE4E1',.5))
            parts.extend(line(x+8+col*(width-16)/3,y,x+8+col*(width-16)/3,y+4.5,'#DFEEDE',.7) for col in range(4))
        else:
            parts.extend(rect(x+5+col*12,y,7,6,'#739FA5',.7,INK,.7) for col in range(3))
        parts.append(rect(x+width+4,y-2,5,5,'#6C8E91',.3,'#D4E0CA',.5))
    parts.append(rect(x+width*.4,94,11,11,'#668C92',.7))
    if week in [22,24,26,28,30,32,34]:
        podium_width=24+(week-22)
        parts.append(rect(x-12,88,podium_width,18,'#DFCCAA',1.4))
        parts.append(rect(x-9,93,podium_width-6,8,'#83B3B8',.7))
        parts.append(path(f'M{x-13} 88L{x-6} 84H{x+podium_width-7}L{x+podium_width-12} 88Z','#B6C9A5',INK,1.1))
    if week in [23,25,27,29,31,33]:
        parts.append(rect(x+width+8,74,18,27,'#C4BBA1',1.2))
        for y in [79,88]: parts.append(rect(x+width+11,y,10,5,'#709AA3',.5,INK,.6))
    if week>=29:
        parts.extend([path(f'M{x-4} {top+19}H{x+width+3}V{top+25}H{x-4}Z','#D4E3C0',INK,1.2),bush(x+5,top+20,4)])
    if week>=31:
        parts.append(path(f'M{x+width*.4} {top}V{top-8}H{x+width*.7}V{top}Z','#BBCBBA',INK,1.2))
    if week==34:
        parts.append(path(f'M{x+10} {top}Q{x+width*.5} {top-14} {x+width-2} {top}Z','#CCE0D6',INK,1.5))
    parts.extend([bush(24,106,5),bush(105,103,5)])
    return ''.join(parts)


def tower(week):
    building_height=72+(week-35)*4 if week<=42 else 100
    bottom=104
    top=bottom-building_height
    left=46; right=82
    crown=week>=46
    start=top+12 if crown else top
    outline=(f'M{left} {bottom}Q47 {top+40} 57 {start} '
             f'L64 {start-3}L71 {start}Q81 {top+40} {right} {bottom}Z')
    structural=36<=week<=44
    parts=[]
    if week<=42:
        parts.append(path(outline,'#DBCDB0' if week==35 else '#E1C78D', '#645748',1.7))
    else:
        parts.append(path(outline,'url(#glass)', '#4F717A',1.7))
    parts.append(f'<g clip-path="url(#towerClip)">')
    if week<=42:
        row_count=5+week-35
        for row in range(row_count):
            y=bottom-7-row*building_height/row_count
            parts.append(line(left-2,y,right+2,y,'#8E7857',1.4))
            if week>=37:
                parts.append(path(f'M{left+3} {y}L{right-3} {y-8}M{right-3} {y}L{left+3} {y-8}','none','#BE8D51',1))
        for x in [52,59,66,73,80]: parts.append(line(x,top-5,x,bottom,'#8A7458',1.1))
    else:
        for x in [49,53,57,61,65,69,73,77,81]:
            parts.append(line(x,top,x,bottom,'#D6EAE5',.75))
        for i in range(24):
            y=bottom-4-i*4
            parts.append(line(left,y,right,y,'#7BA3AF',.6))
        parts.append(path(f'M54 {bottom}Q52 {top+44} 61 {top+5}L64 {top+6}Q57 {top+48} 62 {bottom}Z','#EBF1DE','none',0))
        parts.append(path(f'M68 {bottom}Q68 {top+30} 70 {top+4}L74 {top+8}Q77 {top+49} 77 {bottom}Z','#6F9FAA','none',0))
        if week in [43,44]:
            unglazed=building_height*(.48 if week==43 else .27)
            parts.append(rect(left-4,top-4,right-left+8,unglazed,'#E0C58F',0,'none',0))
            for y in range(int(top+4),int(top+unglazed),7):
                parts.append(line(left,y,right,y,'#8F7856',1.1))
                parts.append(path(f'M{left+3} {y}L{right-3} {y-7}M{right-3} {y}L{left+3} {y-7}','none','#C19257',1))
    parts.append('</g>')
    if crown:
        parts.append(path(f'M57 {top+16}Q55 {top+8} 61 {top}L63 {top+19}Z','#DBEEE7','#537A84',1.4))
        if week>=47:
            parts.append(path(f'M66 {top+19}L68 {top}Q76 {top+7} 71 {top+17}Z','#8CBBC3','#537A84',1.4))
        if week>=48:
            parts.append(path(f'M61 {top}Q61 {top+10} 64 {top+21}Q67 {top+10} 68 {top}','none','#F0EEDA',1.1))
        if week==46:
            parts.extend([path(f'M41 {top+11}H87V{top+36}H41Z','none','#AA854B',1.7),
                          path(f'M39 {top+30}H89V{top+36}H39Z','#DDBF81','#AA854B',1.2),
                          line(42,top+20,86,top+20,'#A98D58',1.5),
                          line(47,top+11,47,top+30,'#A98D58',1.2),
                          line(81,top+11,81,top+30,'#A98D58',1.2)])
        elif week==47:
            parts.extend([path(f'M42 {top+30}H86V{top+36}H42Z','#DDBF81','#AA854B',1.2),
                          line(47,top+36,47,top+48,'#AA854B',1.7),
                          line(81,top+36,81,top+48,'#AA854B',1.7)])
    if structural:
        crane_x=96 if week%2==0 else 33
        parts.extend([line(crane_x,103,crane_x,max(10,top-3),'#A7793D',2),line(crane_x-14,max(10,top-3),crane_x+18,max(10,top-3),'#D4AA53',3),line(crane_x+14,max(10,top-3),crane_x+14,max(10,top-3)+12,'#A7793D',1.2),path(f'M{crane_x-8} {max(10,top-3)}L{crane_x} {max(3,top-13)}L{crane_x+14} {max(10,top-3)}','none','#B78C44',1.3)])
    if week>=45:
        parts.append(rect(56,94,16,11,'#527D8B',.6,'#4E6A71',1))
        parts.extend([line(61,95,61,104,'#D7E6D3',.8),line(67,95,67,104,'#D7E6D3',.8)])
    if week>=49:
        parts.extend([path('M20 97L41 89L58 98L36 107Z','#D8E1D1',INK,1.4),path('M20 97L36 105V112L20 104Z','#A8BAAE',INK,1.3),path('M36 105L58 98V105L36 112Z','#799E9E',INK,1.3),rect(28,98,7,4,'#B9DDDD',.5,'none',0)])
    if week>=50:
        parts.extend([path('M79 96L96 89L111 96L95 103Z','#CFDDC7',INK,1.4),path('M79 96V106L95 113V103Z','#93ACA6',INK,1.2),path('M95 103L111 96V106L95 113Z','#739697',INK,1.2),bush(95,93,5),bush(85,96,3)])
    if week>=51:
        parts.extend([path('M43 107L65 102L86 108L66 116Z','#EEE4C6','#AAB6A0',1),line(55,108,70,112,'#C5CBB3',1.2),bush(17,106,5),bush(111,106,5)])
    if week>=52:
        parts.extend([path(f'M53 {top+32}L74 {top+32}L74 {top+38}L53 {top+38}Z','#E9C57C','#A1936B',.8),spark(89,22,5),spark(39,39,4)])
    if week==53:
        parts.extend([path('M51 101L63 97L80 101L68 106Z','#DBE8DE','#6B9494',1.2),path('M51 101V106L68 111V106Z','#9ABCB7','#6B9494',1),line(68,106,80,101,'#F1EDD8',1.3),spark(37,17,5),spark(87,53,4)])
    return ''.join(parts), outline


def artwork(week):
    defs = '''<defs>
    <linearGradient id="seed" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#E5BF79"/><stop offset="1" stop-color="#B27943"/></linearGradient>
    <linearGradient id="bark"><stop stop-color="#B18A53"/><stop offset="1" stop-color="#795B37"/></linearGradient>
    <linearGradient id="window" x2="0" y2="1"><stop stop-color="#D0DFCD"/><stop offset="1" stop-color="#7EABB4"/></linearGradient>
    <linearGradient id="glass"><stop stop-color="#D5E9E2"/><stop offset=".4" stop-color="#ACCED4"/><stop offset="1" stop-color="#6D9CA9"/></linearGradient>
    </defs>'''
    if week<=4: body=seed(week)
    elif week<=8: body=plant(week)
    elif week<=14: body=tree(week)
    elif week<=21: body=homes(week)
    elif week<=34: body=block(week)
    else:
        body, outline=tower(week)
        defs=defs.replace('</defs>',f'<clipPath id="towerClip">{path(outline,"#fff","none",0)}</clipPath></defs>')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 128 128">'
            f'{defs}<g stroke-linecap="round" stroke-linejoin="round">'
            f'{ellipse(64,116,43,4,"#A1ADA1")}{ground(week>=22)}{body}</g></svg>')


def daily_plan(week):
    current=NAMES[week-1][1]
    if week==53:
        return ['롯데월드타워 완성형', '윤년 마지막 날: 현관 캐노피·정원 확장']
    target=NAMES[week][1]
    return [f'{current} 기준형', f'{target} 새 구조 15% 시공',
            f'{target} 새 구조 30% 시공', f'{target} 새 구조 45% 시공',
            f'{target} 새 구조 60% 시공', f'{target} 새 구조 75% 시공',
            f'{target} 새 구조 90% 시공; 다음 주 첫날에 완성']


def sheet(stages, size=128):
    cols=8
    tile=184 if size==128 else 112
    row_h=194 if size==128 else 111
    margin=32 if size==128 else 24
    header=132 if size==128 else 88
    w=cols*tile+2*margin
    h=header+math.ceil(len(stages)/cols)*row_h+40
    pieces=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">',
            f'<rect width="{w}" height="{h}" fill="#F4F2E9"/>',
            '<g font-family="Apple SD Gothic Neo, Noto Sans CJK KR, sans-serif" fill="#3F493E">',
            f'<text x="{margin}" y="46" font-size="{28 if size==128 else 22}" font-weight="700">씨앗에서 롯데월드타워까지 · 53주</text>',
            f'<text x="{margin}" y="76" font-size="{15 if size==128 else 12}" fill="#758071">7일마다 새 구조 · 1주차 1–7일 / 53주차 365–366일 · 투명 배경 아이콘</text>']
    for i, stage in enumerate(stages):
        x=margin+(i%cols)*tile
        y=header+(i//cols)*row_h
        pieces.append(rect(x,y,tile-12,row_h-12,'#FFFFFF',12,'#DDE2D6',1))
        pieces.append(f'<text x="{x+12}" y="{y+23}" font-size="12" fill="#7B8775" font-weight="700">W{stage["week"]:02d} · {stage["dayStart"]}–{stage["dayEnd"]}일</text>')
        svg=artwork(stage['week'])
        inner=svg.split('>',1)[1].rsplit('</svg>',1)[0]
        prefix=f'w{stage["week"]}-'
        for key in ['seed','bark','window','glass','towerClip']:
            inner=inner.replace(f'id="{key}"',f'id="{prefix+key}"').replace(f'url(#{key})',f'url(#{prefix+key})')
        icon_x=x+(tile-12-size)/2
        icon_y=y+30
        pieces.append(f'<g transform="translate({icon_x} {icon_y}) scale({size/128})">{inner}</g>')
        pieces.append(f'<text x="{x+(tile-12)/2}" y="{y+row_h-22}" text-anchor="middle" font-size="{13 if size==128 else 10}">{html.escape(stage["name"])}</text>')
    pieces.extend(['</g>','</svg>'])
    return ''.join(pieces)


def main():
    out=ROOT/'weeks'
    out.mkdir(exist_ok=True)
    stages=[]
    for week,(slug,name) in enumerate(NAMES,1):
        stem=f'week-{week:02d}-{slug}'
        (out/f'{stem}.svg').write_text(artwork(week),encoding='utf-8')
        daily=daily_plan(week)
        stage={'week':week,'name':name,'dayStart':1+(week-1)*7,
               'dayEnd':min(week*7,366),'svg':f'weeks/{stem}.svg','png':f'weeks/{stem}.png',
               'nextWeekTarget':NAMES[min(week,52)][1],
               'dailyVariationPlan':daily[:min(7,367-(1+(week-1)*7))]}
        stages.append(stage)
    manifest={'requestID':'H53A1003B1','assetCount':53,'weekLengthDays':7,
              'yearDaysSupported':[365,366],'style':'warm outlined RPG vector icons',
              'deliveryScope':'53 weekly keyframes; daily variants planned, not generated or integrated',
              'background':'transparent','start':'seed','end':'stylized Lotte World Tower',
              'authoringMethod':'repo-native SVG icon system extended with deterministic editable geometry; PNG exported with Sharp',
              'architectureReference':'https://www.kpf.com/project/lotte-world-tower',
              'dailyTransition':'Build new outlines, walls, leaves or floors in seven distinct structural steps; do not crossfade or only recolor. Day 7 previews 90% of the next weekly shape so the next week never resets progress.',
              'stages':stages}
    (ROOT/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    with (ROOT/'stages.csv').open('w',newline='',encoding='utf-8-sig') as f:
        writer=csv.writer(f);writer.writerow(['week','day_start','day_end','name','daily_change_plan'])
        writer.writerows([s['week'],s['dayStart'],s['dayEnd'],s['name'],' / '.join(s['dailyVariationPlan'])] for s in stages)
    (ROOT/'contact-sheet.svg').write_text(sheet(stages),encoding='utf-8')
    (ROOT/'contact-sheet-48.svg').write_text(sheet(stages,48),encoding='utf-8')
    print(f'Created {len(stages)} weekly SVGs and two review sheets.')


if __name__=='__main__':
    main()
