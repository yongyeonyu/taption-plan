#!/usr/bin/env python3
"""Editable weekly artwork; leaves the application's current asset catalog intact."""
from pathlib import Path
import csv
import html
import json
import math

ROOT = Path(__file__).resolve().parent
INK = '#594939'
NAMES = [('history-01', '씨앗'), ('history-02', '새싹'), ('history-03', '큰 나무'), ('history-04', '모닥불'), ('history-05', '동굴 거처'), ('history-06', '해먹'), ('history-07', '가지 움막'), ('history-08', '차탈회위크 흙집'), ('history-09', '스카라브레이 돌집'), ('history-10', '이집트 피라미드'), ('history-11', '우르 지구라트'), ('history-12', '미노스 궁전'), ('history-13', '그리스 신전'), ('history-14', '로마 판테온'), ('history-15', '비잔틴 돔'), ('history-16', '호류지 목탑'), ('history-17', '마야 계단 신전'), ('history-18', '이슬람 아치 궁전'), ('history-19', '바이킹 롱하우스'), ('history-20', '로마네스크 석조'), ('history-21', '앙코르 사원'), ('history-22', '고딕 대성당'), ('history-23', '절벽 푸에블로'), ('history-24', '짐바브웨 석조 성곽'), ('history-25', '조선 한옥'), ('history-26', '르네상스 팔라초'), ('history-27', '푸젠 토루'), ('history-28', '튜더 목조 주택'), ('history-29', '시밤 흙탑 주택'), ('history-30', '무굴 돔 궁전'), ('history-31', '일본 성곽'), ('history-32', '바로크 궁전'), ('history-33', '네덜란드 운하집'), ('history-34', '로코코 저택'), ('history-35', '신고전주의 저택'), ('history-36', '러시아 목조 주택'), ('history-37', '빅토리아 주택'), ('history-38', '시카고 철골 빌딩'), ('history-39', '아르누보 빌라'), ('history-40', '프레리 주택'), ('history-41', '바우하우스'), ('history-42', '아르데코 빌딩'), ('history-43', '국제주의 유리 건물'), ('history-44', '브루탈리즘'), ('history-45', '메타볼리즘 캡슐'), ('history-46', '시드니 오페라하우스'), ('history-47', '포스트모던 빌딩'), ('history-48', '하이테크 빌딩'), ('history-49', '빌바오 곡면 건축'), ('history-50', '타이베이101'), ('history-51', '부르즈 칼리파'), ('history-52', '상하이타워'), ('history-53', '롯데월드타워')]


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


def natural_tree(week):
    n=week-9
    body=path(f'M59 104L60 {62-n*8}L67 {58-n*8}L72 104Z', 'url(#bark)', INK, 2)
    for x,y,r in [(48,64,16),(71,58,19),(61,43,18)]+([(84,43,14),(40,43,14)] if n>=1 else [])+([(58,27,17),(80,26,12)] if n>=2 else []):
        body+=bush(x,y,r)
    return body+path('M62 91L54 99M68 90L78 99', 'none', '#8C704A', 2)


def traditional(x,bottom,w,tiled=False):
    top=bottom-29
    b=rect(x,top,w,29,'#E5D4AB',1)+path(f'M{x+w} {top}L{x+w+9} {top-5}V{bottom-5}L{x+w} {bottom}Z','#BDA985')
    if tiled:
        b+=path(f'M{x-8} {top+4}Q{x-1} {top+1} {x+6} {top-8}L{x+w/2} {top-15}L{x+w-6} {top-8}Q{x+w+1} {top+1} {x+w+8} {top+4}Q{x+w/2} {top+11} {x-8} {top+4}Z','#657B86',INK,2)
        for j in range(9):
            xx=x-4+j*(w+8)/8
            b+=line(xx,top+3,x+w/2+(xx-x-w/2)*.7,top-7,'#BCD0CC',.9)
    else:
        b+=path(f'M{x-8} {top+6}L{x+6} {top-12}Q{x+w/2} {top-23} {x+w-6} {top-12}L{x+w+8} {top+6}Q{x+w/2} {top+11} {x-8} {top+6}Z','#CAB16E',INK,2)
        for j in range(12):
            xx=x-4+j*(w+8)/11
            b+=line(xx,top+5,x+w/2+(xx-x-w/2)*.65,top-10,'#EEDD9C',1.2)
    for xx in [x+4,x+w-15]:
        b+=rect(xx,top+12,11,10,'#B7C6AB',0)+line(xx+5.5,top+12,xx+5.5,top+22)+line(xx,top+17,xx+11,top+17)
    b+=rect(x+w/2-5,bottom-17,10,17,'#98764F',0)
    for xx in [x+1,x+w-1]: b+=line(xx,top+9,xx,bottom,'#94764E',2)
    return b


def heritage(week):
    tiled=week>=17
    n=week-(17 if tiled else 12)
    w=(28 if n==0 else 37) if n<2 else 47
    b=''
    if n>=3:
        b+=path('M28 106L70 91L104 103L62 116Z','#D6C59C',INK,1)
    if n>=2: b+=traditional(73,96,20,tiled)
    b+=traditional(35,104,w,tiled)
    if n>=1: b+=rect(30,103,w+10,5,'#B28D60',0)
    if n>=3:
        b+=bush(25,105,7)+bush(100,105,7)
        b+=line(22,109,45,116,'#B09666',3)+line(84,114,109,107,'#B09666',3)
    if n>=4:
        b+=traditional(44,116,26,tiled)+rect(49,102,15,14,'#886B4C',0)
    return b


def detached(week):
    n=week-22 if week<27 else 4
    b=''
    if n>=3: b+=house(73,100,22,1,'#D6C7AF','#956C56',2)
    b+=house(34 if n<4 else 29,105,40 if n<4 else 49,1 if n<2 else 2,'#D1AB85' if n<4 else '#E7DFCB','#A75F4B' if n<4 else '#677C7A',2)
    if n>=1: b+=rect(42,101,25,7,'#C5BAA4',0)+line(43,101,43,88,'#7C6954',2)+line(66,101,66,88,'#7C6954',2)+rect(40,86,29,4,'#A77D62',0)
    return b


def garden(week):
    n=week-27
    b=path('M20 104Q64 88 108 104Q64 121 20 104Z','#88B276','none',0)+detached(26)
    b+=path('M57 109L62 102L68 102L75 112Z','#ECE0BA',INK,1)
    if n>=1:
        for x,y in [(24,102),(28,111),(91,110),(105,100)]:
            b+=bush(x,y,6)+ellipse(x,y-5,4,4,'#D6877C')+ellipse(x+4,y-2,3,3,'#EAC574')
    if n>=2:
        for x in [83,110]: b+=line(x,113,x,76,'#A37F56',3)
        for yy in [76,82,88]: b+=line(80,yy,113,yy-5,'#A37F56',3)
    if n>=3: b+=path('M16 97V82L27 74L39 82V97Z','#B5D4CB',INK,1.5)+line(27,75,27,98)+line(17,84,38,84)
    if n>=4: b+=ellipse(93,108,10,5,'#A3CAD1',INK,1)+line(18,111,42,118,'#E9DFC7',3)+line(78,116,109,109,'#E9DFC7',3)
    return b


def residence(x,bottom,w,floors,balconies=False,glass=False):
    top=bottom-floors*12-8
    b=path(f'M{x+w} {top}L{x+w+10} {top-6}V{bottom-5}L{x+w} {bottom}Z','#9CA9A5',INK,1.5)+rect(x,top,w,bottom-top,'url(#glass)' if glass else '#E0D9C5',1)+path(f'M{x-2} {top}L{x+9} {top-6}L{x+w+11} {top-6}L{x+w+1} {top}Z','#819494',INK,1.3)
    for row in range(floors):
        yy=top+5+row*12
        for col in range(3): b+=rect(x+4+col*(w-8)/3,yy,6,7,'#7CA4AE',.5,INK,.7)
        if balconies: b+=rect(x-2,yy+7,w+4,3,'#B9C8C1',0,INK,.8)
    return b+rect(x+w/2-4,bottom-9,8,9,'#716D63',.5)


def urban_residential(week):
    villa=week<=36
    n=week-(32 if villa else 37)
    floors=(3 if n<2 else 4) if villa else (5 if n<2 else 6)
    b=''
    if n>=3 or (not villa and n==0): b+=residence(76,99,22,floors-1,n>=3)
    if not villa and n>=4: b+=residence(20,101,18,4,True)
    b+=residence(36,108,35,floors,n>=1)
    if villa and n>=4: b+=bush(45,49,6)+bush(62,49,5)+line(36,56,73,56,'#8C795B',2)
    if not villa and n>=5: b+=ellipse(79,112,19,5,'#8FAF7D')+bush(90,106,8)+path('M77 117L80 110L87 109','#E4D8AC',INK,1)
    return b


def highrise(week):
    n=week-43
    b=''
    if n>=4: b+=residence(83,100,17,6,False,True)
    if n>=2: b+=residence(24,106,22,3,False,True)
    b+=residence(43,109,32,7 if n<3 else 7,False,n>=1)
    if n>=2: b+=bush(28,64,5)+bush(43,64,4)
    if n>=3: b+=path('M45 14L52 5L70 5L77 14Z','#829FA7',INK,1.5)
    if n>=5: b+=path('M34 110L39 100L84 100L92 110Z','#B3C5C3',INK,1.5)+ellipse(63,103,13,3,'#E1D7A9')+spark(79,20,5)
    return b


def camp(week):
    n=week-6
    if n<=1:
        b=ellipse(64,105,25,9,'#B8ADA0',INK,1.5)
        for x,y in [(43,103),(52,110),(76,110),(85,103)]: b+=ellipse(x,y,5,3,'#AAA79A',INK,1)
        b+=line(50,106,77,96,'#956940',6)+line(49,97,78,107,'#805B3D',6)
        b+=path('M52 99Q44 85 58 71Q56 85 65 62Q81 78 75 99Z','#EBA35D',INK,1.5)+path('M58 99Q57 88 66 81Q76 93 70 101Z','#F7D483','none',0)
        if n: b+=rect(24,92,13,14,'#A98255',2)+rect(92,89,12,16,'#A98255',2)+spark(83,69,4)
        return b
    if n<=3:
        b=path('M25 104L27 46L34 46L35 103M94 103L96 45L103 46L104 103','#AA8655',INK,2)+bush(30,41,13)+bush(100,41,13)
        b+=path('M31 67Q64 115 99 67Q65 100 31 67Z','#DA9871',INK,2)+line(31,67,48,78)+line(99,67,81,79)
        if n==3: b+=path('M27 51L62 36L105 51L92 59L62 48L39 59Z','#E4C58C',INK,2)
        return b
    if n<=5:
        b=path('M27 107L63 47L104 107Z','#AA9062',INK,2)
        for x in range(31,100,8): b+=line(63,49,x,105,'#715D3D',2)
        b+=path('M50 106L65 77L79 106Z','#6D6047',INK,2)
        if n==5:
            for x,y in [(43,80),(56,63),(76,65),(91,86)]: b+=leaf(x,y,90,15,'#94AF6E')
        return b
    if n==6: return path('M22 108L64 53L108 108Z','#D9B374',INK,2)+path('M64 53L81 108L49 108Z','#71674D',INK,2)+line(64,53,108,108,'#EEDDAB',2)
    return path('M34 109L65 43L94 109Z','#E7D3A5',INK,2)+path('M53 109L65 86L79 109Z','#8C7653',INK,2)+line(65,43,59,29,'#8A7250',2)+line(65,43,73,30,'#8A7250',2)+path('M46 87L57 80L66 87L77 80L86 88','none','#B97958',3)


def special_home(week):
    if week==20: return house(32,106,48,1,'#AA8155','#765B42',0)
    if week==21: return bush(27,70,14)+house(39,107,36,1,'#B08D63','#667955',0)+bush(100,98,10)
    if week==22:
        return path('M27 109L64 40L103 109Z','#92745B',INK,2)+path('M37 106L64 53L91 106Z','#DECCA5',INK,2)+path('M57 108V84L66 72L76 84V108Z','url(#window)',INK,2)
    if week==23: return house(30,107,52,2,'#C9AF89','#82644D',0)+path('M24 77L89 77L98 84L24 84Z','#8D6F4E',INK,2)+line(30,84,30,105,'#82694C',2)
    if week in [24,25]:
        b=ellipse(65,109,44,9,'#95BFC6') if week==24 else path('M20 106L98 92L111 110L30 119Z','#C2BD93','none',0)
        for x in [37,59,80,95]: b+=line(x,99,x,113,'#8C7350',3)
        return b+house(34,95,43,1,'#C7AA7B','#947451',0)+(path('M18 109L35 97L43 102L24 114Z','#B1966B',INK,1.5) if week==25 else '')
    if week==29:
        b=path('M48 107L53 48L77 48L83 107Z','#DCD0AE',INK,2)+path('M50 50L65 34L81 50Z','#9E6650',INK,2)+rect(59,91,14,16,'#8D7354')
        for ang in [25,115,205,295]: b+=f'<g transform="rotate({ang} 65 64)">'+rect(63,29,5,35,'#B0A483',0)+rect(68,29,9,25,'#D8C89D',0)+'</g>'
        return b+ellipse(65,64,5,5,'#876F51',INK,1)
    if week==30: return house(28,106,49,1,'#EFE2BD','#BA795B',2)+path('M80 102V56L92 47L104 56V102Z','#E6D8B4',INK,2)+path('M78 57L92 44L106 57Z','#AF7256',INK,2)+rect(87,67,9,13,'#82AAB0')
    if week==31:
        b=house(29,108,50,2,'#E8D9B9','#716250',2)
        for x in [34,53,73]: b+=line(x,67,x,106,'#705B45',2.5)
        return b+line(31,85,79,85,'#705B45',3)+line(33,68,76,104,'#705B45',2)+line(75,68,34,104,'#705B45',2)
    if week==32: return detached(25)+path('M73 111L98 106V90L73 94Z','#C6C1A7',INK,1.5)+line(74,92,97,88,'#897A63',2)
    if week==33: return traditional(25,100,27,True)+traditional(77,99,22,True)+path('M43 108L65 99L87 109L65 119Z','#D6C99F',INK,1)+bush(64,106,6)
    if week==37: return house(17,104,25,2,'#D5B995','#946F5A',2)+house(45,108,25,2,'#E4D5B4','#718582',2)+house(73,104,25,2,'#C9BAA4','#AA775C',2)
    return ''


def diverse_home(week):
    if week==7:
        return path('M21 108L28 74L47 52L78 49L101 73L110 108Z','#A9A391',INK,2)+path('M48 108V87Q64 67 80 87V108Z','#5E6054',INK,2)+path('M31 75L50 67L66 51M83 59L77 75L102 81','none','#D0C8AE',2)
    if week==9:
        b=path('M23 107Q24 50 65 49Q106 51 107 107Z','#DDE5DF',INK,2)
        for y in [70,85,99]: b+=line(30,y,101,y,'#9DAEAD',1)
        for x in [42,64,86]: b+=line(x,74,x,98,'#9DAEAD',1)
        return b+path('M68 109V93Q82 75 96 93V109Z','#ABC1C4',INK,2)+path('M77 109V96Q82 87 88 96V109Z','#5D838E',INK,1)
    if week==11:
        return path('M29 107V75Q28 58 48 58H77Q98 60 98 79V107Z','#C7AA81',INK,2)+path('M26 72Q30 51 61 50Q95 50 102 72Z','#89A16B',INK,2)+path('M55 107V86Q64 77 73 86V107Z','#80694F',INK,1.5)+rect(35,79,12,12,'#A6BDAF',3)+rect(80,79,11,12,'#A6BDAF',3)
    if week in [13,15]:
        stone=week==15
        b=path('M28 78Q64 62 101 78V103Q64 117 28 103Z','#B6B4A5' if stone else '#E7DBC1',INK,2)+path('M24 78L63 50L106 78Q65 91 24 78Z','#9B8561' if stone else '#C8A679',INK,2)
        for x in [39,53,79,92]: b+=line(x,84,x,104,'#8D8977' if stone else '#B8A487',1.3)
        return b+rect(58,87,15,23,'#8E775A',1)+line(29,97,100,97,'#988D77',1)
    if week==17:
        b=path('M26 97V70Q28 51 50 51H76Q98 52 99 72V97Z','#CDA779',INK,2)+path('M24 68Q26 46 61 46Q98 46 101 68Z','#74846C',INK,2)
        b+=rect(36,70,17,14,'#B8CED0',2)+rect(70,65,16,32,'#877051',2)
        for x in [42,84]: b+=ellipse(x,103,10,10,'#A08A66',INK,2)+ellipse(x,103,3,3,'#D9CFAC')+line(x-8,103,x+8,103)+line(x,95,x,111)
        return b
    if week==19:
        b=house(27,108,57,2,'#DED0B1','#667981',2)
        for x in range(33,82,6):b+=line(x,89,x,105,'#897455',1.5)
        return b+path('M24 86L89 86L96 91L23 92Z','#607B80',INK,1.5)+rect(47,92,19,10,'#D9A280',0)
    if week==21:
        b=path('M57 111L59 39L68 38L73 111Z','url(#bark)',INK,2)+bush(42,40,17)+bush(84,35,20)+bush(65,23,17)
        b+=house(38,83,38,1,'#C4A37B','#8F7354',0)+rect(30,82,63,5,'#A5865A',0)
        for y in range(86,109,6):b+=line(41,y,54,y,'#AA8A5B',2)
        return b+line(41,85,41,113,'#AA8A5B',2)+line(54,85,54,113,'#AA8A5B',2)
    if week==25:
        return path('M19 101L108 101L96 113L35 113Z','#84745A',INK,2)+house(36,99,39,1,'#D9C49D','#7A8A7D',2)+ellipse(67,117,42,3,'#9FC4C9')
    if week==27:
        b=path('M23 106Q22 55 63 49Q105 55 106 106Z','url(#glass)',INK,2)
        b+=path('M23 106L43 83L33 68L64 49L82 69L101 68M43 83L82 69L87 105M43 83L65 105','none','#66858B',1.7)
        return b+path('M57 108V91Q66 78 76 91V108Z','#CEBB95',INK,2)
    if week==32:
        b=rect(25,73,75,34,'#B39478',0)+rect(41,44,60,27,'#98AFAD',0)+path('M25 73L36 68H109L100 73Z','#D5C6AB',INK,1.5)
        for x in range(29,100,7): b+=line(x,77,x,103,'#897966',.8)
        return b+rect(35,81,22,18,'url(#window)',0)+rect(76,82,15,25,'#7D7361',0)+rect(51,50,34,15,'url(#window)',0)
    if week==33:
        return rect(25,69,68,38,'#E5DFC9',0)+rect(58,46,42,24,'#D6C5AB',0)+path('M25 69L34 62H102L93 69Z','#7B908E',INK,1.5)+rect(31,77,42,11,'url(#glass)',0)+rect(65,51,28,10,'url(#glass)',0)+rect(79,88,12,19,'#A08162',0)
    if week==35:
        b=path('M25 107V68L62 44L102 68V107Z','url(#glass)',INK,2)
        b+=path('M25 68L62 81L102 68M62 44V107M25 88H102','none','#73948A',2)
        for x in [38,86]: b+=line(x,61,x,107,'#73948A',1.5)
        return b+bush(39,102,8)+bush(87,102,8)+rect(55,84,15,23,'#D9CCAB',0)
    if week==38:
        b=house(30,108,46,3,'#B3ADA0','#687780',2)
        for x in [23,82]:b+=path(f'M{x} 104V46L{x+7} 27L{x+14} 46V104Z','#A8A79A',INK,1.5)+path(f'M{x-2} 46L{x+7} 24L{x+16} 46Z','#687780',INK,1.5)
        return b+path('M48 108V86Q61 68 72 86V108Z','#837762',INK,1.5)
    if week==39:
        b=residence(32,108,52,4,False)
        for x in [39,58,77]: b+=path(f'M{x} 97Q{x-7} 75 {x+4} 61Q{x+10} 45 {x-3} 39','none','#899A70',2)
        return b+path('M28 50Q47 30 60 39Q80 28 91 49Z','#809993',INK,2)+ellipse(61,54,10,7,'#C7D8CC',INK,1.3)
    if week==40:
        b=rect(31,56,63,53,'#C4B89A',0)+rect(40,36,45,22,'#D8C7A6',0)+rect(51,22,24,16,'#B9B69E',0)
        for x in [37,47,57,67,77,87]: b+=rect(x,63,4,34,'#7499A0',0,INK,.6)
        return b+rect(55,97,17,12,'#7D7866',0)+line(63,22,63,10,'#A79365',2)
    if week==42:
        b=''
        for x,y,w,h in [(26,65,36,42),(61,43,38,64),(34,31,49,19)]:b+=rect(x,y,w,h,'#B0B1A2',0)+path(f'M{x} {y}L{x+8} {y-5}H{x+w+8}L{x+w} {y}Z','#CDCDBA',INK,1)
        for x,y in [(34,76),(49,76),(69,52),(84,52),(69,70),(84,70),(69,88),(84,88)]:b+=rect(x,y,8,11,'#648992',0)
        return b
    if week==46:
        b=path('M46 109Q31 89 53 72Q79 54 52 36L68 16Q102 41 77 65Q48 88 86 109Z','url(#glass)',INK,2)
        for y in range(36,107,10):b+=path(f'M47 {y}Q66 {y+8} 82 {y-1}','none','#D7E5DC',1.3)
        return b
    if week==47:
        b=''
        for x,y,w,h in [(26,78,72,31),(34,56,58,22),(43,34,43,22),(52,15,26,19)]:b+=rect(x,y,w,h,'#ACBFB5',0)+path(f'M{x} {y}L{x+7} {y-4}H{x+w+7}L{x+w} {y}Z','#D6DBC6',INK,1)
        for y in [85,64,42,21]:b+=line(56,y,73,y,'#638892',4)
        return b+bush(32,78,5)+bush(39,56,5)+bush(48,34,4)
    return ''


def archdoor(x,y,w,h,color='#716C59',pointed=False):
    return path(f'M{x} {y+h}V{y+h*.4}Q{x+w/2} {y-(h*.2 if pointed else 0)} {x+w} {y+h*.4}V{y+h}Z',color,INK,1.2)


def history_art(week):
    if week==1: return seed(1)
    if week==2: return plant(6)
    if week==3: return natural_tree(11)
    if week==4: return camp(6)
    if week==5: return diverse_home(7)
    if week==6: return camp(8)
    if week==7: return camp(10)
    if week==8:
        b=rect(25,78,41,30,'#C7AD88',0)+rect(63,62,38,43,'#D4BE98',0)+rect(40,50,39,28,'#B69B78',0)
        for x,y in [(30,80),(68,65),(49,52)]:b+=rect(x,y,11,7,'#76664F',0)
        return b+line(86,80,86,114,'#967B53',2)+line(97,79,97,114,'#967B53',2)+''.join(line(86,y,97,y,'#967B53',2) for y in range(83,113,7))
    if week==9:
        b=path('M22 103Q23 63 61 65Q98 63 105 102L92 111L31 111Z','#AEAD98',INK,2)+ellipse(64,89,25,14,'#DDD2AF',INK,1.5)
        for y in [83,97,105]:b+=line(27,y,98,y,'#8E947F',1)
        return b+rect(49,86,31,10,'#948970',0)+rect(52,102,16,10,'#726D59',0)
    if week==10:
        return path('M22 108L64 33L107 108Z','#DCC492',INK,2)+path('M64 33L69 108H107Z','#BAA373',INK,1)+line(38,82,88,82,'#BFA875',1)+line(29,97,99,97,'#BFA875',1)
    if week==11:
        b=''
        for x,y,w,h in [(22,88,84,22),(32,69,64,20),(43,51,43,19),(53,37,24,14)]:b+=rect(x,y,w,h,'#C4A172',0)+path(f'M{x} {y}L{x+6} {y-4}H{x+w+6}L{x+w} {y}Z','#E0C398',INK,1)
        return b+path('M52 111L59 75H70L78 111Z','#AD845C',INK,1.2)+''.join(line(56-y*.1,y,73+y*.1,y,'#D8B98A',1) for y in range(87,110,5))
    if week==12:
        b=rect(25,67,74,40,'#D3BA95',0)+rect(39,45,45,24,'#DBCCAB',0)
        for x in [31,51,73,92]:b+=rect(x,72,5,35,'#A16B55',0)+ellipse(x+2.5,72,5,2,'#DCCBAA')
        return b+rect(25,62,74,6,'#7D9EAA',0)+rect(39,40,45,6,'#A77661',0)+rect(59,78,12,29,'#756B58',0)
    if week==13:
        b=rect(22,102,84,7,'#BDB393',0)+path('M20 62L63 40L109 62Z','#D3C9A8',INK,2)+rect(24,63,81,6,'#B6B394',0)
        for x in [30,48,66,84]:b+=rect(x,71,7,31,'#E1D8BC',.5)+rect(x-2,68,11,4,'#C5BC9F',0)
        return b
    if week==14:
        b=path('M29 77Q31 36 67 36Q103 36 104 78Z','#A7AA94',INK,2)+rect(29,77,75,28,'#C3BBA1',0)+path('M21 75L61 57L95 75Z','#DBCCAB',INK,2)
        for x in [30,47,65,82]:b+=rect(x,78,6,27,'#DDD3B6',0)
        return b+ellipse(68,40,5,2,'#7B8174')
    if week==15:
        b=rect(31,72,69,36,'#D1BCA0',0)+path('M42 71Q40 43 65 40Q89 43 88 71Z','#A7B3A8',INK,2)
        b+=path('M21 92Q21 67 43 66Q60 72 58 92Z','#B9BCA9',INK,1.5)+path('M74 91Q74 66 94 65Q113 71 110 91Z','#B9BCA9',INK,1.5)
        return b+archdoor(56,82,19,26)+rect(51,65,29,8,'#DDD0B1',0)
    if week==16:
        b=rect(48,49,33,58,'#D1B990',0)
        for y,w in [(92,70),(78,59),(64,49),(50,39),(37,29)]:b+=path(f'M{64-w/2} {y}L64 {y-10}L{64+w/2} {y}L{64+w/2-3} {y+4}H{64-w/2+3}Z','#748A86',INK,1.4)
        return b+line(64,28,64,13,'#867B5C',2)+rect(58,97,13,10,'#7B725B',0)
    if week==17:
        b=''
        for x,y,w,h in [(24,90,80,19),(32,72,65,18),(41,56,48,16),(49,41,32,15)]:b+=rect(x,y,w,h,'#A7AB91',0)
        return b+rect(48,27,35,15,'#C2BDA1',0)+rect(59,30,11,11,'#727C67',0)+path('M55 109L59 43H70L78 109Z','#C9C5A4',INK,1)+''.join(line(58,y,74,y,'#8E967D',1) for y in range(54,107,7))
    if week==18:
        b=rect(24,71,79,37,'#D1C2A0',0)+path('M45 72Q43 49 64 41Q85 49 83 72Z','#99B0A4',INK,2)
        for x in [29,48,70,89]:b+=archdoor(x,83,11,25,'#859D94',True)
        return b+rect(22,62,10,46,'#C1AF8C',0)+rect(98,54,9,54,'#C1AF8C',0)+path('M97 54L102 44L108 54Z','#8FA498',INK,1)
    if week==19:
        b=path('M18 109V79L38 53L91 54L111 82V109Z','#C2A276',INK,2)+path('M15 81L36 50L94 51L115 82L97 79L85 61L47 62L32 84Z','#8D7652',INK,2)
        for x in range(24,109,9):b+=line(x,85,x,105,'#977B54',1.2)
        return b+archdoor(53,84,22,25,'#73654E')
    if week==20:
        b=rect(29,66,66,42,'#C4B99B',0)+path('M25 66L60 46L98 66Z','#9B967C',INK,1.5)+rect(24,45,18,63,'#B8B094',0)+path('M22 45L34 30L44 45Z','#8D8E79',INK,1.5)
        return b+archdoor(55,79,17,29)+archdoor(27,57,10,15,'#6F7767')+archdoor(76,79,10,17,'#7D8B80')
    if week==21:
        b=rect(22,96,85,13,'#B2B09A',0)
        for x,y,h in [(29,67,30),(48,48,49),(68,57,40),(85,69,28)]:
            b+=path(f'M{x} 98V{y}Q{x+4} {y-18} {x+10} {y-25}Q{x+16} {y-18} {x+19} {y}V98Z','#A8A98D',INK,1.5)+line(x+4,y+4,x+15,y+4,'#DBD3B1',1)
        return b+path('M52 109L57 89H71L80 109Z','#C9BDA0',INK,1)
    if week==22:
        b=rect(38,63,55,46,'#BCBDAA',0)+path('M35 64L65 43L96 64Z','#8B9893',INK,1.7)
        for x in [24,91]:
            b+=rect(x,37,17,71,'#BABDA9',0)+path(f'M{x-2} 37L{x+8} 15L{x+19} 37Z','#8B9893',INK,1.5)+archdoor(x+5,47,8,20,'#809992',True)
        b+=ellipse(66,69,10,10,'#9DBDBA',INK,1.5)+line(66,59,66,79,'#CBD6C3',1)+line(56,69,76,69,'#CBD6C3',1)
        return b+archdoor(55,84,22,25,'#768F89',True)
    if week==23:
        b=path('M18 106L23 54Q66 33 108 55L112 107Z','#B8A185',INK,2)+path('M24 65Q64 84 106 64L97 83H32Z','#7E7765',INK,1.5)
        for x,y,w,h in [(29,85,24,23),(51,72,28,36),(80,88,24,20)]:b+=rect(x,y,w,h,'#D8BD98',0)+rect(x+7,y+8,7,10,'#756F58',0)
        return b
    if week==24:
        b=path('M23 102V75Q65 51 106 76V102Q65 124 23 102Z','#ADAE96',INK,2)+ellipse(65,76,41,12,'#D7D0AE',INK,1.5)+ellipse(65,77,27,6,'#7C866E')
        for y in [87,96,104]:b+=path(f'M26 {y}Q66 {y+14} 103 {y}','none','#8D947D',1)
        return b+path('M68 99L73 64Q78 45 82 37Q87 44 92 64L99 99Z','#C3BE9D',INK,1.5)
    if week==25:return heritage(19)+path('M24 107L37 104L77 104L104 107L104 112H24Z','#C1B18E',INK,1)+bush(23,102,6)
    if week==26:
        b=rect(26,57,77,51,'#D7C6A8',0)+rect(23,52,83,7,'#AD9D7E',0)
        for y in [67,85]:
            for x in [34,54,74,92]:b+=archdoor(x,y,9,14,'#8BA69D')
        return b+archdoor(55,90,18,18)+line(28,82,101,82,'#A79A7C',2)
    if week==27:
        b=path('M20 79Q20 47 65 47Q110 47 110 79V101Q65 121 20 101Z','#B99E7B',INK,2)+ellipse(65,74,44,14,'#8F7357',INK,1.5)+ellipse(65,72,28,8,'#D8CAA2',INK,1.5)
        for y in [85,96]:
            for x in [30,45,61,77,94]:b+=rect(x,y,5,5,'#6B6B54',0,INK,.5)
        return b+archdoor(59,98,13,15)
    if week==28:return special_home(31)
    if week==29:
        b=''
        for x,y,w,h in [(25,56,22,52),(48,34,29,76),(81,51,22,55)]:
            b+=rect(x,y,w,h,'#B79D7E',0)+rect(x,y,w,6,'#E5DDC3',0)
            for yy in range(y+13,y+h-8,13):
                for xx in [x+5,x+w-10]:b+=rect(xx,yy,5,7,'#E3D7B8',1,INK,.7)
        return b
    if week==30:
        b=rect(26,76,77,32,'#E8D8BF',0)+path('M43 77Q42 49 65 42Q87 48 86 77Z','#E2D1B1',INK,2)
        for x in [25,99]:b+=rect(x,34,7,74,'#D5C4A7',0)+path(f'M{x-2} 34Q{x+3} 21 {x+9} 34Z','#C0B49B',INK,1)
        return b+archdoor(55,82,19,26,'#879E99',True)+line(64,42,64,28,'#AC966A',1.5)
    if week==31:
        b=rect(27,83,77,26,'#E6DDC5',0)+rect(38,62,55,23,'#E6DDC5',0)+rect(49,41,34,23,'#E6DDC5',0)
        for y,w in [(81,87),(59,66),(39,47)]:
            b+=path(f'M{65-w/2} {y+3}L{65-w/2+10} {y-9}H{65+w/2-10}L{65+w/2} {y+3}L{65+w/2+4} {y+5}H{65-w/2-4}Z','#758E8B',INK,1.5)
        for x,y in [(39,92),(60,92),(82,92),(50,68),(72,68),(60,47)]:b+=rect(x,y,6,8,'#7F938A',0)
        return b+rect(24,106,84,5,'#B3AD95',0)
    if week==32:
        b=rect(20,72,89,37,'#D1BD99',0)+rect(47,58,35,51,'#E2D0AE',0)+path('M18 73L31 63H99L112 73Z','#85948B',INK,1.3)+path('M42 60L64 43L87 60Z','#9DA992',INK,1.5)
        for x in [26,39,51,74,87,100]:b+=rect(x,80,5,17,'#8DA9A4',1)
        return b+archdoor(58,87,14,22)+rect(54,64,20,10,'#D9CCB0',1)
    if week==33:
        b=''
        for x,h,color in [(20,49,'#C29B7D'),(48,67,'#A7B3A6'),(77,56,'#C7B79A')]:
            y=108-h;b+=rect(x,y,25,h,color,0)+path(f'M{x-2} {y}L{x+4} {y-6}L{x+7} {y-6}V{y-12}H{x+18}V{y-6}L{x+23} {y-6}L{x+27} {y}Z',color,INK,1.5)
            for yy in range(y+8,103,13):b+=rect(x+6,yy,12,8,'#8EAAA6',.5)
        return b+path('M16 115Q64 121 113 113','none','#86B8C1',4)
    if week==34:
        b=rect(29,68,72,40,'#E1C8AF',2)+path('M25 67Q40 52 48 56Q63 34 77 56Q89 49 105 67Z','#A0B0A0',INK,1.5)
        for x in [36,53,77,91]:b+=archdoor(x,76,8,14,'#A8C0B4')
        return b+archdoor(59,87,15,21)+path('M34 62Q48 70 58 61M73 61Q87 71 99 62','none','#B99A6D',2)
    if week==35:
        b=rect(20,78,88,31,'#D9D2BB',0)+rect(43,54,43,54,'#DDD7C0',0)+path('M39 54L64 36L90 54Z','#A7B3A4',INK,1.5)
        for x in [49,62,75]:b+=rect(x,61,5,39,'#EAE4CE',0)
        for x in [26,93]:b+=rect(x,87,9,13,'#8CA69A',0)
        return b+rect(56,83,17,25,'#81998F',0)+rect(39,105,50,5,'#B3AE95',0)
    if week==36:
        b=house(31,109,47,1,'#B89F75','#829583',0)
        b+=rect(65,59,27,49,'#C5AC84',0)+path('M62 61Q59 43 70 38Q80 29 85 37Q99 43 96 61Z','#9BAD90',INK,2)+line(78,35,78,27,'#B6A275',1.5)
        for x,y in [(37,84),(56,84),(73,72)]:b+=rect(x,y,10,12,'#D9CDAB',1)+rect(x+2,y+2,6,8,'#91ACA4',0)
        return b
    if week==37:
        b=house(32,108,44,3,'#D0AE91','#7D8790',2)+path('M79 106V51L89 38L103 51V106Z','#DBC5A9',INK,1.5)+path('M76 51L90 34L106 51Z','#7D8790',INK,1.5)
        return b+rect(80,85,20,11,'#ADC5BA',1)+rect(40,95,31,6,'#D8CAB0',0)
    if week==38:
        b=residence(34,109,51,6,False,False)
        for y in range(39,103,11):
            for x in [41,58,75]:b+=rect(x,y,10,7,'#A9C4C6',0,INK,.7)
        return b+rect(31,107,58,4,'#C8BDA0',0)+line(34,49,85,49,'#8D8F7E',2)
    if week==39:return diverse_home(39)
    if week==40:
        b=rect(25,85,83,23,'#D1BB99',0)+rect(37,62,54,24,'#DFD2B7',0)+path('M15 86L52 72L117 87L109 92H22Z','#7F8E83',INK,2)+path('M29 63L61 48L101 64L93 70H36Z','#7F8E83',INK,2)
        return b+rect(29,94,60,8,'url(#window)',0)+rect(49,70,31,8,'url(#window)',0)+rect(88,90,11,18,'#8C765B',0)
    if week==41:return diverse_home(33)+rect(20,55,20,35,'url(#glass)',0)+line(20,68,40,68,'#6D8C8C',1)+line(20,80,40,80,'#6D8C8C',1)
    if week==42:return diverse_home(40)
    if week==43:
        b=residence(40,109,42,7,False,True)
        for x in [44,54,64,74]:b+=line(x,22,x,106,'#D1E0D8',1.2)
        return b+rect(28,99,69,9,'#D9D7BF',0)
    if week==44:return diverse_home(42)
    if week==45:
        b=rect(52,27,21,81,'#8B9E98',0)
        for x,y in [(27,35),(70,44),(30,61),(74,73),(27,89)]:b+=rect(x,y,27,21,'#D7D6C4',0)+ellipse(x+13,y+10,7,7,'#77969B',INK,1.5)
        return b
    if week==46:
        b=path('M20 104L109 104L103 113H25Z','#C8BDA0',INK,1.5)
        for d in ['M24 104Q16 74 43 51Q44 80 58 104Z','M43 104Q35 63 68 37Q64 77 79 104Z','M70 104Q64 73 98 57Q93 83 107 104Z']:
            b+=path(d,'#E1DFCD',INK,1.7)
        return b+line(28,103,43,53,'#B4BDAE',1)+line(49,103,67,40,'#B4BDAE',1)+line(77,103,97,60,'#B4BDAE',1)
    if week==47:
        b=rect(31,43,62,66,'#C2AB9B',0)+path('M31 43L62 23L94 43Z','#93AFAF',INK,2)+path('M51 36L63 27L75 36V43H51Z','#E3D6BB',INK,1.5)
        return b+rect(48,83,28,26,'#9DB4AF',0)+''.join(rect(x,y,7,9,'#9CB7B3',0) for x in [39,57,75] for y in [51,66])+line(61,43,61,80,'#DECBA9',2)
    if week==48:
        b=residence(40,109,44,7,False,True)
        for x in [28,90]:b+=rect(x,37,9,70,'#B6BFB5',0)+ellipse(x+4.5,37,5,3,'#D5D9C3',INK,1)
        for y in [49,70,91]:b+=line(28,y,99,y,'#E0CEAA',3)
        return b+line(93,37,93,19,'#A2B6B0',2)+rect(27,106,75,4,'#B7BCA5',0)
    if week==49:
        b=path('M22 109V86Q20 60 41 63Q48 37 68 51Q83 40 99 65L109 103L87 111Z','#B8C3B9',INK,2)
        b+=path('M32 106Q25 67 48 64Q71 50 70 104Z','#D0D6C4',INK,1.5)+path('M65 106Q60 71 91 59L106 105Z','#8FA7A4',INK,1.5)
        return b+path('M43 104Q33 79 52 66M79 104L92 64','none','#E8E2CB',1.5)
    if week==50:
        b=rect(50,93,30,16,'#8DADA6',0)
        for y,w in [(83,42),(70,39),(57,36),(44,33),(31,30),(19,25)]:b+=path(f'M{65-w/2} {y+12}L{65-w/2-3} {y}L{65+w/2+3} {y}L{65+w/2} {y+12}Z','#9BBFB3',INK,1.3)+line(65-w/2,y+8,65+w/2,y+8,'#D6DEC5',1)
        return b+rect(57,9,16,10,'#A6C3B8',0)+line(65,9,65,1,'#869B8F',1.5)
    if week==51:
        b=''
        for x,y,w,h in [(40,75,46,34),(45,52,34,24),(49,31,26,21),(54,15,16,17),(58,7,9,9)]:b+=rect(x,y,w,h,'url(#glass)',.5)+line(x+3,y+6,x+w-3,y+6,'#DBE6DB',.8)
        return b+line(62,7,62,1,'#819B9C',1.3)+rect(30,103,64,7,'#C3CDBD',0)
    if week==52:
        b=path('M43 109Q36 78 47 46Q50 23 68 10L78 13Q88 42 82 70Q78 95 88 109Z','url(#glass)',INK,2)
        b+=path('M45 107Q77 82 62 53Q54 28 76 13','none','#D6E7DB',3)
        for y in range(26,108,8):b+=path(f'M45 {y}Q65 {y+5} 83 {y}','none','#93B4B4',.8)
        return b
    return tower(53)[0]


def artwork(week):
    defs = '''<defs>
    <linearGradient id="seed" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#E5BF79"/><stop offset="1" stop-color="#B27943"/></linearGradient>
    <linearGradient id="bark"><stop stop-color="#B18A53"/><stop offset="1" stop-color="#795B37"/></linearGradient>
    <linearGradient id="window" x2="0" y2="1"><stop stop-color="#D0DFCD"/><stop offset="1" stop-color="#7EABB4"/></linearGradient>
    <linearGradient id="glass"><stop stop-color="#D5E9E2"/><stop offset=".4" stop-color="#ACCED4"/><stop offset="1" stop-color="#6D9CA9"/></linearGradient>
    </defs>'''
    body=history_art(week)
    if week==53:
        _,outline=tower(53)
        defs=defs.replace('</defs>',f'<clipPath id="towerClip">{path(outline,"#fff","none",0)}</clipPath></defs>')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 128 128">'
            f'{defs}<g stroke-linecap="round" stroke-linejoin="round">'
            f'{ellipse(64,116,43,4,"#A1ADA1")}{ground(week>=22)}{body}</g></svg>')


def daily_plan(week):
    current=NAMES[week-1][1]
    if week==53:
        return ['롯데월드타워 완성형', '윤년 마지막 날: 현관 캐노피·정원 확장']
    target=NAMES[week][1]
    action='성장' if week<3 else '구조 전환'
    return [f'{current} 기준형', f'{target} 새 구조 15% {action}',
            f'{target} 새 구조 30% {action}', f'{target} 새 구조 45% {action}',
            f'{target} 새 구조 60% {action}', f'{target} 새 구조 75% {action}',
            f'{target} 새 구조 90% {action}; 다음 주 첫날에 완성']


def sheet(stages, size=128):
    cols=8
    tile=184 if size==128 else 112
    row_h=218 if size==128 else 135
    margin=32 if size==128 else 24
    header=132 if size==128 else 88
    w=cols*tile+2*margin
    h=header+math.ceil(len(stages)/cols)*row_h+40
    pieces=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">',
            f'<rect width="{w}" height="{h}" fill="#F4F2E9"/>',
            '<g font-family="Apple SD Gothic Neo, Noto Sans CJK KR, sans-serif" fill="#3F493E">',
            f'<text x="{margin}" y="46" font-size="{28 if size==128 else 22}" font-weight="700">세계 건축 연대순 · 씨앗에서 롯데월드타워까지 · 53주</text>',
            f'<text x="{margin}" y="76" font-size="{15 if size==128 else 12}" fill="#758071">1–7주는 비연대 도입 · 8–53주는 대표 시기순 · 지역 양식의 최초 발생 연도가 아닙니다</text>']
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
        pieces.append(f'<text x="{x+(tile-12)/2}" y="{y+row_h-38}" text-anchor="middle" font-size="{12 if size==128 else 9}">{html.escape(stage["name"])}</text>')
        pieces.append(f'<text x="{x+(tile-12)/2}" y="{y+row_h-22}" text-anchor="middle" font-size="{10 if size==128 else 7}" fill="#7B8775">{html.escape(stage["region"])} · {html.escape(stage["representativePeriod"])}</text>')
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
        history=json.loads((ROOT/'chronology.json').read_text())[week-1]
        stage={'region':history['region'],'representativePeriod':history['representativePeriod'],'sortYear':history['sortYear'],'dateBasis':history['dateBasis'],'week':week,'name':name,'dayStart':1+(week-1)*7,
               'dayEnd':min(week*7,366),'svg':f'weeks/{stem}.svg','png':f'weeks/{stem}.png',
               'nextWeekTarget':NAMES[min(week,52)][1],
               'dailyVariationPlan':daily[:min(7,367-(1+(week-1)*7))]}
        stages.append(stage)
    manifest={'requestID':'H53E1003A1','assetCount':53,'weekLengthDays':7,
              'yearDaysSupported':[365,366],'style':'warm outlined RPG vector icons',
              'deliveryScope':'53 weekly keyframes; daily variants planned, not generated or integrated',
              'background':'transparent','start':'seed','end':'stylized Lotte World Tower',
              'authoringMethod':'repo-native SVG icon system extended with deterministic editable geometry; PNG exported with Sharp',
              'chronologyPolicy':'Weeks1-7 are thematic prologue without chronological claims. Weeks8-53 sort by selected representative building/period, not universal origin dates; regional styles coexist.',
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
