"""366 editable icons: 122 architectural subjects, three structural states each."""
from pathlib import Path
import importlib.util
import math

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('approved_icons', ROOT / 'approved_icons.py')
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)
path, rect, ellipse, line, leaf, bush = a.path, a.rect, a.ellipse, a.line, a.leaf, a.bush
INK = a.INK
CREAM, STONE, EARTH, WOOD = '#E0D5B7', '#ACB3A0', '#C9A37E', '#A8865C'
BLUE, ROOF, DARK, WHITE = '#91BAC2', '#738B83', '#6B7564', '#EBE7D8'


def windows(xs, ys, w=7, h=9, color=BLUE):
    return ''.join(rect(x,y,w,h,color,.5,INK,.8) for y in ys for x in xs)


def arch(x,y,w,h,fill=DARK,pointed=False):
    return a.archdoor(x,y,w,h,fill,pointed)


def gable(x,y,w,h,fill=ROOF):
    return path(f'M{x-4} {y+h}L{x+w/2} {y}L{x+w+4} {y+h}Z',fill)


def roof(x,y,w,h=13,fill=ROOF):
    return path(f'M{x-5} {y+h}Q{x+2} {y+h-3} {x+8} {y}H{x+w-8}Q{x+w-2} {y+h-3} {x+w+5} {y+h}L{x+w+2} {y+h+4}H{x-2}Z',fill)


def dome(x,y,w,h,fill=WHITE):
    return path(f'M{x} {y+h}Q{x-2} {y+h*.25} {x+w/2} {y}Q{x+w+2} {y+h*.25} {x+w} {y+h}Z',fill)


def steps(x,y,w,n,fill=CREAM):
    return ''.join(rect(x-i*2,y+i*3,w+i*4,3,fill,0,INK,.8) for i in range(n))


def columns(x,y,n,gap,h,fill=CREAM):
    return ''.join(rect(x+i*gap,y,5,h,fill,0)+rect(x+i*gap-2,y-3,9,3,fill,0) for i in range(n))


def pool(x,y,w,h=10):
    return ellipse(x+w/2,y,w/2,h/2,'#ACCFD0',INK,1)+line(x+5,y,x+w-6,y,'#E5EEDC',1.7)


def reeds(x,y):
    return line(x,y,x-2,y-17,'#6E895B',2)+line(x+4,y,x+7,y-13,'#6E895B',2)+leaf(x-2,y-13,-45,5)


def plant(kind,d):
    if kind=='seed':
        if d==0:return a.seed(1)
        b=a.seed(2)
        if d==1:
            return b+path('M56 100Q47 105 36 99M71 101Q85 107 92 96','none','#E6D8AA',3)
        return b+path('M64 86Q69 63 63 49','none','#6A934E',4)+leaf(64,56,-45,14)+leaf(64,58,83,13)
    if kind=='sprout':
        top=69-d*10
        b=path(f'M64 104Q59 84 64 {top}','none','#60884A',4)+ellipse(64,106,20,4,'#AD9A71')
        for i in range(2+d*2):
            y=top+4+(i//2)*16
            b+=leaf(64,y,-45 if i%2==0 else 85,13+d*2)
        return b
    if kind=='sapling':
        top=37-d*5
        b=path(f'M60 107L62 {top}L67 {top}L71 107Z',WOOD,INK,2)
        for i in range(4+d*2):
            yy=top+8+i//2*15; xx=42 if i%2==0 else 85
            b+=line(65,yy+12,xx,yy,WOOD,3)
            b+=ellipse(xx,yy,15+d,11+d,'#82A56A',INK,1.5)
        return b+path('M62 105L46 111M70 105L83 111','none',WOOD,3)
    b=path('M57 108L60 54L68 51L73 108Z','url(#bark)',INK,2)
    b+=path('M62 73L40 52M68 67L88 44','none',WOOD,5)
    for x,y,rx,ry in [(45,53,22,21),(76,40,24,23),(58,26,23,19)][:2+d]:
        b+=ellipse(x,y,rx,ry,['#668C54','#80A363','#AAC887'][d],INK,1.6)
    if d>=1:b+=ellipse(90,64,19,20,'#749858',INK,1.5)
    if d==2:b+=ellipse(37,78,18,16,'#86A865',INK,1.5)+path('M62 105L45 111M70 106L85 112','none',WOOD,4)
    return b


def camping(kind,d):
    if kind=='fire':
        b=''.join(line(x,108,x+31,97,WOOD,7) for x in [37,52])+line(38,96,87,109,WOOD,6)
        b+=path(f'M41 96Q30 80 48 {60-d*8}Q47 76 58 68Q63 {52-d*9} 73 {72-d*6}Q91 66 84 94Q69 110 41 96Z','#DA975C',INK,2)
        b+=path(f'M51 98Q48 82 61 {73-d*6}Q67 87 74 76Q83 98 66 102Z','#F0CD7D',INK,1)
        if d>=1:b+=path('M29 106Q22 94 31 87Q40 92 38 104Z',STONE)+path('M91 109Q84 99 94 91Q104 101 101 108Z',STONE)
        if d==2:b+=line(26,74,96,67,WOOD,3)+line(33,72,23,109,WOOD,3)+line(90,68,108,110,WOOD,3)+rect(55,78,20,16,DARK,3)+line(61,67,62,78,INK,1.5)
        return b
    if kind=='cave':
        b=path(f'M18 105Q20 {43-d*3} 67 {43-d*7}Q104 43 112 105Z',STONE,INK,2)
        b+=path('M36 107Q34 69 64 64Q94 71 94 107Z',DARK,INK,2)
        b+=path('M43 103Q48 81 67 77L87 104Z','#91876C',INK,1)
        if d>=1:b+=path('M25 74L40 61L49 76L44 99L24 102Z','#C8C4AA')+line(75,47,91,63,'#D7D3BA',3)
        if d==2:b+=path('M32 98L58 83L88 99Z',WOOD)+line(43,94,39,112,WOOD,3)+line(79,94,83,112,WOOD,3)+ellipse(64,112,22,4,EARTH)
        return b
    if kind=='hammock':
        b=path('M20 108L26 38H32L29 108M98 109L99 36H105L108 109',WOOD,INK,3)
        b+=path(f'M30 71Q65 {102+d*5} 101 62L97 81Q60 120 33 88Z',['#ADC28A','#C8B683','#BB8E70'][d],INK,2)
        for x in range(38,95,9):b+=path(f'M{x} 78Q{x+3} 91 {x+10} 99','none','#806F50',1)
        if d>=1:b+=roof(16,36,36,13,'#8CAB6F')+roof(85,30,30,14,'#8CAB6F')
        if d==2:b+=path('M26 56L64 37L101 48L91 58L44 62Z','#DCD2A8',INK,2)+line(63,40,68,63,INK,1)+rect(60,86,24,8,'#E8DBC0',4)
        return b
    if kind=='hut':
        b=path('M29 107L48 65H82L101 107Z',EARTH,INK,2)+path(f'M22 90L63 {35-d*5}L108 91Z',WOOD,INK,2)
        for x in range(28,104,10):b+=line(63,36-d*5,x,88,'#D7BB82',1.8)
        b+=rect(53,86,21,23,DARK,0)
        if d>=1:b+=path('M25 100L34 82L43 100Z','#A68B65')+path('M84 100L93 78L106 100Z','#A68B65')
        if d==2:b+=roof(44,78,41,14,'#BAA06E')+line(43,91,38,111,WOOD,3)+line(88,90,94,111,WOOD,3)+steps(43,109,42,2)
        return b
    if kind=='yurt':
        b=rect(28,73,73,33,CREAM,5)+path(f'M22 74Q27 48 64 {35-d*4}Q104 47 108 74Z',WHITE,INK,2)
        b+=ellipse(65,37-d*4,12,4,WOOD,INK,1.3)+rect(56,82,19,25,DARK,1)
        if d>=1:
            for x in range(30,103,13):b+=path(f'M{x} 77L{x+7} 86L{x} 96L{x+7} 105','none','#B78668',2.5)
        if d==2:b+=rect(27,75,76,7,'#8BACA0',0)+roof(46,76,38,13,'#B88565')+steps(48,109,32,2)
        return b
    b=pool(13,109,103,19)+''.join(line(x,69,x,111,WOOD,4) for x in [34,62,92])
    b+=rect(31,70,65,24,EARTH,0)+gable(24,36-d*4,80,36+d*4,WOOD)+rect(55,75,16,21,DARK,0)
    if d>=1:b+=rect(18,92,92,5,CREAM,0)+windows([36,78],[76],10,10)
    if d==2:b+=line(99,95,109,111,WOOD,2)+line(105,95,115,110,WOOD,2)+''.join(line(100+i,98+i*1.1,106+i,98+i*1.1,WOOD,1.8) for i in range(0,9,2))+reeds(18,103)
    return b


def old_subject(week,d):
    # Older approved forms acquire subject-specific parts, plus body construction.
    body=a.history_art(week)
    if week==52:
        outline='M43 109Q36 78 47 46Q50 23 68 10L78 13Q88 42 82 70Q78 95 88 109Z'
        body=f'<g clip-path="url(#shanghaiClip)">{body}</g>'+path(outline,'none',INK,2)
    sy=[.78,.90,1][d]
    b=f'<g transform="translate(0 {109*(1-sy):.3f}) scale(1 {sy})">{body}</g>'
    if d==0:return b
    if week==8:
        b+=rect(18,90,27,20,EARTH,0)+rect(17,84,29,7,CREAM,0)+rect(26,94,11,16,DARK,0)
        if d==2:b+=rect(82,75,26,33,'#B99773',0)+rect(84,73,28,5,CREAM,0)+windows([89],[82,94],10,7)
    elif week==9:
        b+=path('M22 91L38 78L43 96L33 110L17 108Z','#8D967F',INK,2)
        if d==2:b+=rect(78,86,27,17,CREAM,2)+rect(83,93,17,10,DARK,0)+steps(43,108,42,2)
    elif week==10:
        b+=path('M84 111L101 80L117 111Z','#BDA276',INK,1.8)
        if d==2:b+=path('M13 111L25 71L30 71L34 111Z',CREAM,INK,1.8)+ellipse(52,112,15,4,'#AD936C')+rect(42,103,19,6,'#A78965',0)
    elif week in [11,17]:
        b+=path('M42 111L48 78H76L87 111Z',CREAM)+''.join(line(47-i*.3,81+i*4,77+i*.6,81+i*4,'#998562',1.3) for i in range(8))
        if d==2:b+=rect(15,95,25,16,STONE,0)+gable(15,81,25,14,CREAM)+rect(92,86,20,25,STONE,0)
    elif week in [12,13,14]:
        b+=columns(18,82,3,12,27,CREAM)+rect(15,75,38,7,CREAM,0)
        if d==2:b+=columns(87,79,2,14,30,CREAM)+gable(82,65,34,13,CREAM)+steps(34,108,56,2)
    elif week in [15,18,30]:
        b+=dome(16,76,28,16,'#9CB9AE')+rect(16,92,28,18,CREAM,0)+arch(24,94,12,16)
        if d==2:b+=dome(88,67,26,17,'#9CB9AE')+rect(88,84,26,26,CREAM,0)+arch(95,88,12,22)+pool(45,113,43,6)
    elif week in [16,21,31]:
        b+=rect(19,85,27,25,CREAM,0)+roof(15,69,35,17)+windows([27],[91],9,16)
        if d==2:b+=rect(89,83,23,25,CREAM,0)+roof(85,67,29,16)+steps(41,110,46,2)
    elif week==19:
        b+=path('M20 82L34 57L97 58L112 82L100 81L89 65H44L30 86Z','#A9B67B',INK,2)+line(40,55,31,35,WOOD,3)+line(88,55,97,33,WOOD,3)
        if d==2:b+=path('M36 105V86L64 72L92 86V107Z',WOOD,INK,2)+rect(56,89,18,19,DARK,0)+gable(30,70,66,19,'#85915C')
    elif week in [20,22]:
        b+=rect(13,69,14,39,STONE,0)+gable(11,51,18,18)+arch(16,75,7,18,BLUE,week==22)
        if d==2:b+=rect(104,63,12,46,STONE,0)+gable(102,44,16,19)+arch(107,74,6,20,BLUE,week==22)+steps(45,110,37,2)
    elif week==23:
        b+=rect(18,82,26,26,EARTH,0)+rect(22,72,25,11,CREAM,0)+rect(28,91,8,13,DARK,0)
        if d==2:b+=rect(82,73,28,36,EARTH,0)+windows([90],[80,94],10,9)+line(71,88,69,113,WOOD,2.5)+line(82,88,80,113,WOOD,2.5)+''.join(line(70,y,81,y,WOOD,2) for y in [94,100,106])
    elif week==24:
        b+=path('M13 101V85Q25 80 40 87V110Z',STONE,INK,2)+ellipse(25,85,12,4,CREAM,INK,1)
        if d==2:b+=path('M97 111L101 71Q107 56 111 71L117 111Z',CREAM,INK,2)+line(102,90,114,90,'#969980',1.5)
    elif week==25:
        b+=rect(14,88,32,22,WHITE,0)+roof(10,71,38,18)+rect(25,94,14,16,WOOD,0)
        if d==2:b+=rect(89,90,25,22,WHITE,0)+roof(85,75,31,16)+path('M42 114Q67 104 89 114',CREAM,INK,1.5)
    elif week in [26,32,34,35]:
        b+=rect(13,91,26,19,CREAM,0)+gable(10,76,32,15)+arch(19,94,14,16,BLUE)
        if d==2:b+=rect(93,80,23,30,CREAM,0)+gable(91,67,27,13)+windows([100],[86,99],9,8)+steps(46,110,33,2)
    elif week==27:
        b+=path('M17 79Q64 54 113 80L109 87Q64 64 21 87Z','#716E51',INK,1.5)+arch(54,95,24,17,WOOD)
        if d==2:b+=path('M40 89Q65 80 87 88V103Q65 113 40 103Z',CREAM,INK,1.5)+ellipse(65,89,24,7,'#ABC3A4',INK,1)+rect(59,96,12,16,DARK,0)
    elif week==28:
        b+=rect(15,81,27,29,CREAM,0)+gable(11,57,36,24,'#795F4E')+path('M19 85L38 105M38 85L19 105','none',WOOD,3)
        if d==2:b+=rect(91,78,23,32,CREAM,0)+gable(88,53,29,25,'#795F4E')+windows([97],[83,97],11,8)
    elif week==29:
        b+=rect(11,70,20,39,EARTH,0)+rect(12,70,20,5,CREAM,0)+windows([17],[83,96],8,8)
        if d==2:b+=rect(100,58,17,51,EARTH,0)+rect(99,57,19,6,CREAM,0)+windows([105],[70,83,97],7,8)
    elif week==33:
        b+=pool(12,116,104,10)+line(22,108,109,108,'#ADC4B0',3)
        if d==2:b+=path('M38 110Q59 98 83 109L84 115H38Z',CREAM,INK,1.5)+path('M45 114Q61 104 77 114Z',DARK,INK,1)+line(36,110,87,110,WOOD,2)
    elif week in [36,37,39]:
        b+=rect(13,86,26,24,EARTH,0)+gable(10,63,32,23)+windows([19],[90],13,14)
        if d==2:b+=rect(95,80,21,30,CREAM,0)+gable(92,61,27,20)+windows([101],[85,99],9,9)+steps(42,110,35,2)
    elif week==38:
        b+=rect(84,69,21,41,EARTH,0)+windows([89],[77,90,102],11,7)
        if d==2:b+=rect(16,88,23,22,CREAM,0)+windows([21],[94],13,12)+rect(27,34,65,7,CREAM,0)
    elif week==40:
        b+=rect(13,93,29,18,CREAM,0)+path('M8 94L38 81L59 94Z',ROOF,INK,2)+windows([18],[97],19,8)
        if d==2:b+=rect(89,97,26,14,CREAM,0)+path('M78 97L98 88L120 97Z',ROOF,INK,2)+rect(84,54,9,29,EARTH,0)
    elif week==41:
        b+=rect(86,70,29,40,WHITE,0)+rect(89,76,23,25,BLUE,0)
        if d==2:b+=rect(13,93,34,18,WHITE,0)+rect(17,97,25,8,BLUE,0)+rect(49,64,26,19,'#B4795F',0)
    elif week in [42,47]:
        b+=rect(16,84,28,27,EARTH,0)+rect(20,76,20,8,CREAM,0)+windows([23],[89],15,16)
        if d==2:b+=rect(88,74,24,37,EARTH,0)+rect(92,66,17,8,CREAM,0)+windows([94],[83,96],11,9)+steps(44,110,40,2)
    elif week in [43,48]:
        b+=rect(81,61,26,48,'url(#glass)',0)+''.join(line(85,y,102,y,WHITE,1) for y in [71,81,91,101])
        if d==2:b+=rect(14,88,32,22,'url(#glass)',0)+rect(13,87,33,5,WHITE,0)+line(28,89,28,108,WHITE,1.5)
    elif week==44:
        b+=rect(15,79,24,32,STONE,0)+rect(13,74,27,8,CREAM,0)+rect(20,91,14,20,DARK,0)
        if d==2:b+=rect(87,64,25,47,STONE,0)+rect(85,60,29,9,CREAM,0)+windows([94],[79,98],12,7)
    elif week==45:
        b+=rect(76,25,27,23,CREAM,0)+ellipse(89,36,7,7,BLUE,INK,1.2)
        if d==2:b+=rect(79,88,33,23,WHITE,0)+ellipse(95,99,8,8,BLUE,INK,1.5)+rect(17,61,24,21,WHITE,0)+ellipse(28,71,6,6,BLUE,INK,1)
    elif week==46:
        b+=path('M14 106Q9 82 29 65Q28 88 43 106Z',WHITE,INK,1.7)
        if d==2:b+=path('M85 107Q79 81 107 73Q107 92 119 107Z',WHITE,INK,1.7)+pool(16,115,97,6)
    elif week==49:
        b+=path('M17 109Q6 83 26 77Q43 82 43 111Z','#ADBAB1',INK,2)
        if d==2:b+=path('M92 111Q92 78 108 72L119 108Z','#8CA9A8',INK,2)+line(103,79,111,106,WHITE,2)
    elif week in [50,51,52,53]:
        b+=rect(21,90,29,20,'#B6C9BE',0)+rect(19,85,33,6,WHITE,0)+windows([27],[95],17,10)
        if d==2:
            b+=rect(84,88,30,22,'url(#glass)',0)+roof(79,79,35,11,WHITE)+windows([89],[94],18,11)+steps(42,110,41,2)
    return b


def new_subject(kind,d):
    b=''
    if kind in ['trapezoid','longhouse','pilehouse','indus']:
        if kind=='trapezoid':
            b=path(f'M30 106L36 {68-d*6}L90 {68-d*6}L106 106Z',CREAM,INK,2)+path('M35 67L63 43L96 68Z',WOOD,INK,2)+rect(58,83,15,23,DARK,0)
            if d>=1:b+=path('M25 106L30 72L46 78L44 107Z',EARTH,INK,1.5)+ellipse(75,98,12,6,'#BC986D',INK,1)
            if d==2:b+=path('M14 107L23 79L41 91L34 112Z',STONE)+steps(47,108,42,2)
        elif kind=='longhouse':
            b=rect(18,76,91,31,CREAM,0)+path(f'M13 77L28 {44-d*5}L100 {44-d*5}L116 78Z',WOOD,INK,2)
            for x in range(20,113,9):b+=line(x,77,x+9,46-d*5,'#D8BC86',1.6)
            b+=rect(72,84,18,25,DARK,0)
            if d>=1:b+=windows([26,48],[83],13,15)+line(16,95,70,95,WOOD,2)
            if d==2:b+=rect(77,91,32,19,EARTH,0)+gable(72,78,41,14,WOOD)+steps(76,111,27,2)
        elif kind=='pilehouse':
            b=pool(12,110,104,16)+''.join(line(x,76,x,110,WOOD,4) for x in [30,47,79,97])+rect(28,69,72,22,CREAM,0)+gable(21,39-d*5,86,32+d*5,WOOD)
            b+=rect(56,75,17,19,DARK,0)
            if d>=1:b+=rect(19,91,91,5,WOOD,0)+windows([34,82],[76],11,11)
            if d==2:b+=line(26,95,16,115,WOOD,2)+line(34,96,23,115,WOOD,2)+''.join(line(25-i,99+i*2,33-i,99+i*2,WOOD,1.8) for i in range(7))+reeds(105,104)
        else:
            b=rect(24,66-d*8,78,44+d*8,EARTH,0)+rect(20,61-d*8,85,7,CREAM,0)+rect(54,85,20,25,DARK,0)
            if d>=1:b+=rect(16,85,27,26,'#BC9270',0)+windows([32,79],[69],14,13)+rect(51,49,34,17,CREAM,0)
            if d==2:b+=pool(30,113,66,7)+rect(83,81,28,29,CREAM,0)+path('M102 93L111 112','none',INK,2)
        return b
    if kind in ['pylon','liongate','assyrian','persian']:
        if kind=='pylon':
            for x in [17,78]:b+=path(f'M{x} 109L{x+5} {42-d*6}H{x+28}L{x+34} 109Z',EARTH,INK,2)+rect(x+7,61,16,28,CREAM,0)
            b+=rect(45,61,35,11,CREAM,0)+rect(52,77,20,33,DARK,0)
            if d>=1:b+=columns(14,84,2,16,25)+columns(87,84,2,16,25)
            if d==2:b+=path('M47 111L50 48L54 42L58 48L61 111Z',CREAM)+steps(35,110,61,2)
        elif kind=='liongate':
            b=rect(17,53-d*5,95,57+d*5,STONE,0)+arch(45,65-d*4,39,45+d*4,DARK)
            if d>=1:
                for x in [16,96]:b+=rect(x,89,16,21,EARTH,2)+ellipse(x+8,83,11,12,EARTH,INK,1.4)+ellipse(x+8,84,5,6,CREAM,INK,1)
            if d==2:b+=rect(14,47,102,9,CREAM,0)+''.join(rect(x,37,11,12,STONE,0) for x in [17,42,67,94])+steps(38,110,55,2)
        elif kind=='assyrian':
            b=rect(22,56-d*7,82,54+d*7,EARTH,0)+rect(19,52-d*7,88,7,CREAM,0)+arch(49,73,30,38,DARK)
            if d>=1:
                for x in [14,92]:b+=rect(x,66,21,42,CREAM,0)+path(f'M{x} 76L{x+7} 58L{x+18} 64L{x+21} 89L{x+11} 80Z','#B4A884')+ellipse(x+10,65,6,7,CREAM,INK,1)
            if d==2:b+=''.join(rect(x,34,9,16,EARTH,0) for x in [20,37,54,71,88,101])+steps(33,110,63,2)
        else:
            b=steps(16,97,94,4)+columns(24,50-d*5,5,17,47+d*5,CREAM)
            for x in [26,43,60,77,94]:b+=path(f'M{x-4} 44L{x-7} 35H{x+2}L{x+6} 40L{x+10} 35H{x+17}L{x+14} 44Z',STONE)
            if d>=1:b+=rect(14,46,100,6,EARTH,0)+path('M13 109L33 100L42 107L38 115Z',STONE)
            if d==2:b+=columns(13,77,2,92,29,CREAM)+rect(11,70,108,7,CREAM,0)
        return b
    if kind in ['icehouse','theatre','stupa','petra','colosseum','pithouse']:
        if kind=='icehouse':
            b=path(f'M28 109Q28 83 44 61L63 {32-d*5}L82 61Q101 91 102 109Z',EARTH,INK,2)
            for y in [58,71,84,96]:b+=path(f'M{44-(y-58)*.4} {y}Q63 {y+6} {84+(y-58)*.4} {y}','none',CREAM,2)
            b+=arch(53,92,20,20,DARK)
            if d>=1:b+=rect(17,83,22,28,CREAM,0)+gable(14,68,28,15,EARTH)
            if d==2:b+=pool(90,109,29,7)+rect(96,68,12,34,EARTH,0)+rect(94,60,16,10,CREAM,0)
        elif kind=='theatre':
            b=path('M14 61Q64 30 114 61L80 107Q64 117 48 107Z',CREAM,INK,2)
            for y,w in [(64,46),(71,36),(78,26)][:1+d]:b+=path(f'M{64-w} {y}Q64 {y+38} {64+w} {y}', 'none','#9DAB91',6)
            b+=ellipse(64,106,17,6,EARTH,INK,1.3)
            if d>=1:b+=rect(28,54,70,9,STONE,0)+columns(32,31,4,18,23)
            if d==2:b+=path('M28 51L64 32L101 51Z',CREAM)+line(24,64,49,104,INK,1.2)+line(105,64,79,104,INK,1.2)
        elif kind=='stupa':
            b=rect(24,96,81,13,CREAM,0)+dome(25,53-d*6,78,44+d*6,EARTH)+rect(54,46-d*6,20,9,CREAM,0)
            b+=line(64,48-d*6,64,22-d*4,INK,2)+ellipse(64,24-d*4,11,3,CREAM,INK,1)
            if d>=1:b+=columns(19,79,2,17,30,WOOD)+rect(15,71,29,8,WOOD,0)+rect(12,64,35,5,CREAM,0)
            if d==2:b+=columns(83,80,2,17,30,WOOD)+rect(79,73,30,7,WOOD,0)+steps(44,109,41,3)
        elif kind=='petra':
            b=path('M17 110L23 44L41 24L70 21L104 36L112 111Z','#C3977E',INK,2)+rect(29,58,69,48,EARTH,0)+columns(33,73,4,18,33,CREAM)+gable(29,40,68,18,CREAM)
            if d>=1:b+=rect(41,26,46,22,EARTH,0)+dome(52,13,23,16,CREAM)+columns(44,27,3,16,20,CREAM)
            if d==2:b+=arch(53,82,21,27,DARK)+steps(25,108,78,3)+line(26,48,17,81,'#A87D64',3)+line(100,53,107,84,'#A87D64',3)
        elif kind=='colosseum':
            top=61-d*10
            b=path(f'M16 73Q64 {top-21} 113 73V101Q64 125 16 101Z',EARTH,INK,2)+ellipse(64,top,47,14,CREAM,INK,1.5)+ellipse(64,top,31,8,DARK,INK,1)
            for yy in range(top+13,108,16):
                for xx in [22,40,59,78,97]:b+=arch(xx,yy,10,12,DARK)
            if d>=1:b+=path('M18 85Q63 106 112 85','none',CREAM,3)
            if d==2:b+=path('M16 70V52L24 49V41L35 38V32L50 30V42L43 43V51L34 54V61Z',CREAM)+line(17,100,16,76,INK,2)
        else:
            b=ellipse(64,96,44,17,EARTH,INK,2)+ellipse(64,94,29,11,DARK,INK,1.5)+path('M35 88Q32 51 62 46Q98 54 94 88Z',CREAM,INK,2)+rect(55,79,20,27,DARK,0)
            if d>=1:b+=path('M30 79L64 31L101 78Z',WOOD,INK,2)+line(51,105,63,62,WOOD,3)+line(64,105,74,65,WOOD,3)
            if d==2:b+=roof(44,82,41,13,EARTH)+steps(46,109,37,2)+rect(29,60,9,21,STONE,0)
        return b
    if kind in ['borobudur','longstilts','prambanan','nubian','stepwell','stave','mudmosque']:
        if kind=='borobudur':
            for i in range(3+d):b+=rect(14+i*10,99-i*12,101-i*20,12,STONE,0)
            top=99-(2+d)*12
            b+=dome(52,top-21,25,21,CREAM)+rect(60,top-28,9,10,STONE,0)
            for x,y in [(22,99),(93,99),(35,87),(80,87),(47,75),(68,75)][:2+d*2]:b+=dome(x,y-12,15,12,CREAM)+line(x+7,y-13,x+7,y-18,INK,1)
            if d==2:b+=steps(47,98,34,5)
        elif kind=='longstilts':
            b=pool(10,111,108,12)+''.join(line(x,67,x,113,WOOD,3) for x in range(22,111,14))+rect(19,68,93,24,WOOD,0)+gable(12,33-d*4,107,35+d*4,EARTH)
            b+=windows([25,45,65,87],[73],12,13)
            if d>=1:b+=rect(12,91,106,6,CREAM,0)+''.join(line(x,83,x,97,WOOD,2) for x in range(17,117,11))
            if d==2:b+=path('M13 99L33 76L49 76L36 99Z',EARTH)+line(39,94,23,114,WOOD,3)+line(48,94,31,115,WOOD,3)+reeds(109,110)
        elif kind=='prambanan':
            def spire(x,top,w):
                t=path(f'M{x} 105V{top+25}L{x+w/2} {top}L{x+w} {top+25}V105Z',STONE,INK,2)
                for yy in range(top+20,100,11):t+=rect(x-2,yy,w+4,4,CREAM,0)
                return t+arch(x+w*.32,86,w*.36,20,DARK,True)
            b=spire(45,21-d*3,35)
            if d>=1:b+=spire(16,47,23)
            if d==2:b+=spire(87,43,25)+steps(35,105,58,3)
        elif kind=='nubian':
            b=rect(21,81,87,27,'#BDD0B2',0)+dome(32,42-d*4,48,40+d*4,'#E6D7AA')+arch(46,83,22,26,DARK)
            if d>=1:b+=dome(81,69,29,18,'#A8C6C5')+rect(83,88,26,21,'#A8C6C5',0)+windows([90],[92],12,10)
            if d==2:b+=dome(14,62,27,19,'#D0A981')+rect(13,81,28,27,'#D0A981',0)+path('M18 86L25 92L32 86','none',WHITE,3)
        elif kind=='stepwell':
            b=path('M12 60L112 60L104 109L24 110Z',EARTH,INK,2)+rect(18,50,90,12,CREAM,0)
            for i in range(3+d):b+=path(f'M{22+i*7} {65+i*8}H{104-i*7}V{72+i*8}H{27+i*7}Z',CREAM,INK,1.3)
            b+=pool(47,105,36,7)
            if d>=1:b+=columns(20,32,3,17,26)+rect(17,25,47,7,STONE,0)
            if d==2:b+=columns(79,29,2,17,29)+roof(74,15,39,13,STONE)+line(44,64,58,104,'#AB8E68',2)+line(86,64,74,104,'#AB8E68',2)
        elif kind=='stave':
            b=rect(39,70,55,39,WOOD,0)+gable(32,39-d*5,65,35+d*5,'#6D7F6B')+rect(54,90,22,20,DARK,0)
            b+=rect(51,46-d*4,26,29,EARTH,0)+gable(44,22-d*4,39,25,'#6D7F6B')
            if d>=1:b+=rect(21,83,88,26,WOOD,0)+gable(15,59,100,26,'#6D7F6B')+line(19,78,14,60,WOOD,3)+line(108,77,114,59,WOOD,3)
            if d==2:b+=rect(57,21,15,22,WOOD,0)+gable(52,7,24,15,ROOF)+steps(46,110,36,2)+windows([27,91],[90],11,13)
        elif kind=='mudmosque':
            b=rect(19,80,92,29,EARTH,0)
            for x,h in [(22,44),(52,59),(86,48)][:1+d]:
                b+=path(f'M{x} 110L{x+4} {110-h}L{x+13} {99-h}L{x+23} {110-h}L{x+28} 110Z','#B3916D',INK,2)+arch(x+9,88,11,22,DARK,True)
                for y in range(66,93,9):b+=line(x-3,y,x+28,y,WOOD,2)
            if d==2:b+=steps(42,110,43,2)+''.join(rect(x,68,5,14,CREAM,0) for x in [37,72,102])
        return b
    if kind in ['alhambra','tibethouse','tiantan','inca','trulli','kasbah','ottomanhouse','iwans']:
        if kind=='alhambra':
            b=rect(16,59,95,49,EARTH,0)+rect(13,54,101,7,CREAM,0)
            for x in [23,47,71,95]:b+=arch(x,72,13,31,DARK,True)
            if d>=1:b+=rect(19,41,21,33,EARTH,0)+rect(88,35,23,39,EARTH,0)+''.join(rect(x,31,5,9,CREAM,0) for x in [89,98,107])
            if d==2:b+=pool(37,112,54,12)+ellipse(65,106,9,3,WHITE,INK,1)+line(65,89,65,106,WHITE,3)+bush(16,108,9)+bush(111,108,9)
        elif kind=='tibethouse':
            b=path(f'M24 110L31 {53-d*6}H96L105 110Z',WHITE,INK,2)+rect(27,48-d*6,73,9,'#AE7560',0)
            b+=windows([35,59,82],[72,93],11,10,DARK)+rect(52,91,23,20,'#A7735D',0)
            if d>=1:b+=rect(42,34,47,18,WHITE,0)+rect(38,29,55,7,EARTH,0)+windows([49,70],[39],10,7)
            if d==2:b+=rect(13,83,25,28,WHITE,0)+rect(9,77,33,7,'#AE7560',0)+path('M98 63H116V110H104Z',WHITE)+windows([108],[78,96],6,9)
        elif kind=='tiantan':
            b=ellipse(64,108,44,8,CREAM,INK,1.5)+rect(31,76,66,31,'#BC8B6A',0)+ellipse(64,78,37,9,'#7094A0',INK,1.7)
            b+=path('M26 77Q30 55 64 54Q96 55 104 77Z','#749DA4',INK,2)
            if d>=1:b+=rect(41,48,46,24,'#A9785F',0)+path('M35 50Q43 31 64 30Q89 33 93 50Z','#628A99',INK,2)+ellipse(64,51,30,5,BLUE,INK,1)
            if d==2:b+=rect(52,31,23,13,'#B58B63',0)+path('M44 32Q52 14 64 13Q78 16 86 32Z','#63899A',INK,2)+ellipse(64,11,4,5,'#C3AB70',INK,1)+columns(35,83,4,17,23,CREAM)+steps(32,110,65,2)
        elif kind=='inca':
            b=path('M23 110L30 65H99L106 110Z',STONE,INK,2)+gable(20,35-d*5,88,31+d*5,WOOD)+path('M56 110L59 82H73L78 110Z',DARK)
            for y in [71,82,96]:b+=line(27,y,101,y,'#738576',1.6)
            if d>=1:b+=path('M14 111L19 85H37L42 111Z',STONE)+windows([37,82],[73],10,10,DARK)+steps(39,111,48,2)
            if d==2:b+=path('M90 111L93 82H116L119 111Z',STONE)+gable(89,63,28,20,WOOD)+line(17,85,42,85,CREAM,2)+bush(13,108,5)
        elif kind=='trulli':
            def cone(x,y,w):return rect(x,y+30,w,35,WHITE,3)+path(f'M{x-5} {y+32}L{x+w/2} {y}L{x+w+5} {y+32}Z',STONE,INK,2)+ellipse(x+w/2,y-2,3,4,CREAM,INK,1)+arch(x+w*.35,y+44,w*.3,22,DARK)
            b=cone(43,34-d*3,41)
            if d>=1:b+=cone(13,53,34)
            if d==2:b+=cone(81,46,33)+steps(40,110,49,2)
        elif kind=='kasbah':
            b=rect(24,67,83,43,EARTH,0)+arch(53,84,23,27,DARK,True)
            for x in [16,92][:1+d]:b+=path(f'M{x} 110L{x+4} 45H{x+17}L{x+22} 110Z','#AF8564',INK,2)+rect(x+1,39,21,9,EARTH,0)+windows([x+7],[55,78],7,11,DARK)
            if d>=1:b+=rect(37,53,58,15,EARTH,0)+''.join(rect(x,46,6,9,CREAM,0) for x in [40,54,69,84])
            if d==2:b+=rect(37,83,55,27,CREAM,0)+arch(51,87,27,24,DARK,True)+rect(34,77,61,7,EARTH,0)+path('M38 74L44 69L50 74L56 69L62 74L68 69L74 74L80 69L86 74','none',CREAM,2)+steps(40,110,47,2)
        elif kind=='ottomanhouse':
            b=rect(33,78,65,32,CREAM,0)+rect(21,51-d*3,88,34+d*3,WHITE,0)+roof(16,33-d*5,98,19,EARTH)+rect(55,89,20,22,WOOD,0)
            b+=windows([29,48,74,93],[61],10,17)
            if d>=1:b+=rect(15,61,29,29,WOOD,0)+windows([21,32],[65],7,18)+path('M20 92L33 105L42 91Z',EARTH)
            if d==2:b+=rect(87,60,28,31,WOOD,0)+windows([93,103],[64],7,18)+path('M91 93L102 106L111 92Z',EARTH)+steps(46,110,36,2)
        else:
            b=rect(31,43-d*5,67,67+d*5,'#76ABB1',0)+arch(43,54-d*5,42,57+d*5,DARK,True)+rect(27,37-d*5,75,9,CREAM,0)
            for x in [16,104][:1+d]:b+=rect(x,34,8,76,EARTH,0)+rect(x-2,29,12,7,BLUE,0)+line(x+4,29,x+4,19,INK,1.5)
            if d>=1:b+=path('M38 43L65 28L92 43','none',WHITE,3)+path('M36 75L42 67M93 75L87 67','none',WHITE,2.5)
            if d==2:b+=dome(75,58,34,28,BLUE)+rect(87,82,28,28,CREAM,0)+arch(92,89,18,21,BLUE,True)+steps(36,110,61,2)
        return b
    if kind in ['woodchurch','azulejo','potala','pavilion','windtower','capedutch','machiya','dzong']:
        if kind=='woodchurch':
            b=rect(25,83,79,27,WOOD,0)+gable(20,58,90,25,ROOF)+rect(45,48,24,50,EARTH,0)+gable(37,18-d*5,41,34+d*5,ROOF)+arch(47,89,20,21,DARK)
            if d>=1:b+=rect(49,37,15,18,WOOD,0)+windows([52],[41],8,10)+line(57,22,57,6,INK,1.5)
            if d==2:b+=rect(83,73,29,37,WOOD,0)+gable(78,47,39,27,ROOF)+windows([30,89],[91],13,12)+steps(43,110,30,2)
        elif kind=='azulejo':
            b=rect(27,54-d*8,76,56+d*8,WHITE,0)+gable(24,34-d*8,82,20,EARTH)+windows([36,56,80],[68,88],13,14,DARK)
            if d>=1:
                for x in [31,52,75,95]:
                    for y in [60,79,100]:b+=path(f'M{x} {y-3}L{x+3} {y}L{x} {y+3}L{x-3} {y}Z',BLUE,'#5C90A1',.8)
                b+=rect(21,83,91,5,'#6D92A0',0)
            if d==2:b+=path('M16 100V77L37 69V100Z',CREAM)+rect(14,73,26,5,EARTH,0)+arch(53,88,22,24,WOOD)+steps(36,110,56,2)
        elif kind=='potala':
            b=path('M15 110L25 76L101 74L116 111Z',STONE,INK,2)+path('M21 93L31 48H97L107 95Z',WHITE,INK,2)+rect(43,31-d*7,40,62+d*7,'#AE7965',0)+rect(40,27-d*7,46,8,EARTH,0)
            b+=windows([48,63,76],[47,62,77],6,7,DARK)
            if d>=1:b+=windows([33,87],[58,73,84],8,8,DARK)+rect(16,84,27,26,WHITE,0)+steps(50,94,26,6)
            if d==2:b+=rect(76,17,15,23,WHITE,0)+roof(72,9,23,8,EARTH)+rect(19,42,25,14,WHITE,0)+roof(15,31,33,12,EARTH)+windows([22,34],[44],6,9)
        elif kind=='pavilion':
            b=pool(14,110,102,15)+''.join(rect(x,62,5,38,WOOD,0) for x in [28,46,78,96])+rect(23,96,83,7,CREAM,0)+roof(17,36-d*3,96,27+d*3,ROOF)
            if d>=1:b+=rect(32,75,63,5,'#A17857',0)+''.join(line(x,78,x,97,WOOD,1.5) for x in range(35,96,9))
            if d==2:b+=rect(51,32,26,17,EARTH,0)+roof(43,17,43,16,ROOF)+path('M21 103L11 111M105 103L116 111','none',CREAM,3)+leaf(16,96,-30,10)
        elif kind=='windtower':
            b=rect(23,82,86,28,EARTH,0)+dome(56,58,43,24,CREAM)+rect(29,30-d*6,27,60+d*6,CREAM,0)+rect(25,25-d*6,35,7,EARTH,0)
            b+=windows([33,44],[36-d*6],7,25,DARK)+arch(64,89,22,23,DARK)
            if d>=1:b+=rect(17,87,29,23,CREAM,0)+arch(23,91,18,19,DARK)+line(31,66,55,66,WOOD,2)
            if d==2:b+=rect(94,48,19,59,CREAM,0)+rect(90,42,27,8,EARTH,0)+windows([99,107],[55],4,19,DARK)+pool(49,111,36,8)
        elif kind=='capedutch':
            b=rect(18,77,95,33,WHITE,0)+roof(12,56,107,23,'#7D7E63')+path('M44 80V59Q40 50 48 50Q58 50 63 32Q69 50 80 49Q88 50 83 59V80Z',WHITE,INK,2)+arch(54,88,21,23,WOOD)
            b+=windows([24,88],[87],15,16,BLUE)
            if d>=1:b+=ellipse(64,63,8,8,BLUE,INK,1.5)+path('M39 81Q64 87 88 81','none',EARTH,2)+rect(20,72,8,21,EARTH,0)
            if d==2:b+=rect(90,88,27,23,WHITE,0)+path('M87 89L98 74L116 75L121 89Z','#7D7E63')+windows([98],[93],13,11)+steps(42,110,43,2)
        elif kind=='machiya':
            b=rect(24,67,82,43,WOOD,0)+roof(18,40-d*3,93,27+d*3,ROOF)+rect(32,74,64,20,'#DCD1B2',0)
            b+=''.join(line(x,74,x,110,WOOD,2.3) for x in range(33,97,8))
            if d>=1:b+=roof(17,74,93,17,ROOF)+rect(27,95,77,15,CREAM,0)+''.join(line(x,96,x,110,WOOD,1.8) for x in range(31,102,7))
            if d==2:b+=rect(80,91,27,19,'#7C9E97',0)+path('M78 87H111V94H78Z',EARTH)+rect(14,91,13,17,STONE,0)+ellipse(20,87,8,7,WHITE,INK,1.3)+steps(39,110,39,2)
        else:
            b=path('M19 110L25 67H107L113 110Z',WHITE,INK,2)+rect(36,47-d*6,53,47+d*6,CREAM,0)+roof(27,28-d*6,70,21,'#A57053')+windows([43,61,78],[57,76],10,11,DARK)
            if d>=1:b+=path('M14 109L20 73H39V109Z',WHITE)+roof(12,58,32,15,'#A57053')+path('M89 109V67H111L117 109Z',WHITE)+roof(86,49,33,19,'#A57053')
            if d==2:b+=rect(49,28,29,17,WHITE,0)+roof(40,12,47,17,EARTH)+arch(57,88,18,24,WOOD)+steps(43,110,43,2)
        return b
    if kind in ['fale','windmill','rumah','gassho','galleryhouse','mansard','eiffel','batllo','expressionist']:
        if kind=='fale':
            b=rect(21,100,89,8,WOOD,0)+columns(29,65,5,16,36,WOOD)+dome(15,32-d*6,103,38+d*6,EARTH)
            if d>=1:b+=path('M21 67Q66 52 113 67','none',CREAM,4)+rect(26,97,79,5,CREAM,0)+ellipse(65,90,20,5,'#C0AE7E')
            if d==2:b+=path('M30 75L60 70L76 75V91H30Z','#D6C3A0')+steps(36,108,58,2)+bush(111,102,7)+reeds(15,108)
        elif kind=='windmill':
            b=path('M41 110L49 42H77L88 110Z',EARTH,INK,2)+gable(43,27,40,20,ROOF)+rect(56,90,18,22,DARK,0)
            c=(64,54)
            for ang in [25,115,205,295][:2+d]:
                b+=f'<g transform="rotate({ang} {c[0]} {c[1]})">'+rect(61,10,7,40,CREAM,0)+line(64,14,64,54,WOOD,2)+''.join(line(62,y,68,y,WOOD,1) for y in range(16,48,6))+'</g>'
            b+=ellipse(64,54,6,6,WOOD,INK,1.5)
            if d>=1:b+=rect(17,86,28,25,CREAM,0)+gable(13,70,36,17,ROOF)+windows([24],[92],14,11)
            if d==2:b+=rect(30,82,65,5,WOOD,0)+line(34,85,44,96,WOOD,2)+line(90,85,84,96,WOOD,2)+steps(42,110,49,2)
        elif kind=='rumah':
            b=''.join(line(x,81,x,111,WOOD,4) for x in [29,51,81,100])+rect(25,77,78,24,EARTH,0)+path('M13 76Q27 55 24 29Q38 61 64 61Q92 61 106 29Q100 56 116 76Z','#745E4D',INK,2)+windows([33,56,82],[81],13,14)
            if d>=1:b+=path('M34 70Q39 49 38 40Q52 63 63 62Q74 61 91 39Q87 60 97 70Z',WOOD,INK,2)+rect(22,100,85,5,CREAM,0)
            if d==2:b+=path('M48 64Q49 34 63 20Q78 34 80 65Z','#806B52',INK,2)+path('M46 105L53 88H76L87 111Z',CREAM,INK,1.5)+steps(47,104,32,3)
        elif kind=='gassho':
            b=rect(28,77,75,34,WHITE,0)+path(f'M14 80L65 {23-d*4}L118 80Z',WOOD,INK,2)+path('M24 79L65 34L106 79Z','#BBA275',INK,1)+windows([37,77],[87],14,15)+rect(56,90,15,21,DARK,0)
            if d>=1:b+=windows([53,66],[63],9,13,DARK)+''.join(line(x,78,65,29,'#D0B789',1.2) for x in range(24,108,11))
            if d==2:b+=rect(18,95,26,16,EARTH,0)+gable(14,74,33,21,WOOD)+steps(43,110,41,2)+path('M14 112L25 96L31 103L24 116Z',STONE)
        elif kind=='galleryhouse':
            b=rect(24,49-d*6,80,62+d*6,EARTH,0)+roof(16,33-d*6,94,18,ROOF)+windows([34,60,85],[58,84],12,18)
            if d>=1:b+=rect(16,77,98,6,CREAM,0)+columns(21,80,5,21,31,WOOD)+''.join(line(x,69,x,80,INK,1.3) for x in range(20,112,7))
            if d==2:b+=rect(17,102,98,7,CREAM,0)+roof(12,55,108,10,ROOF)+''.join(line(x,92,x,105,INK,1.2) for x in range(20,112,7))+steps(37,110,55,2)
        elif kind=='mansard':
            b=rect(28,53,75,57,CREAM,0)+path(f'M21 56L31 {31-d*5}H100L111 56Z','#7C8D94',INK,2)+windows([36,59,83],[63,83],14,14)
            if d>=1:
                for x in [36,61,85]:b+=rect(x,37,12,16,WHITE,0)+gable(x-2,28,16,9,ROOF)
                b+=line(26,80,106,80,WOOD,2.5)
            if d==2:b+=rect(13,76,23,34,CREAM,0)+windows([18],[81,96],12,10)+rect(92,96,26,15,EARTH,0)+arch(56,94,20,18,DARK)+steps(44,110,37,2)
        elif kind=='eiffel':
            b=path('M19 111L44 78L53 39L64 8L74 39L84 78L111 111H88L64 85L42 111Z','#B48A64',INK,2)+path('M47 79L64 40L80 79Z',CREAM,INK,1.2)+arch(39,86,49,25,DARK)
            b+=rect(42,76,42,7,EARTH,0)+rect(48,43,32,6,EARTH,0)
            if d>=1:
                b+=path('M52 73L75 52M52 54L76 74M28 107L46 91M98 106L82 92','none',CREAM,2.8)+rect(13,107,35,5,STONE,0)+rect(80,107,36,5,STONE,0)
            if d==2:b+=rect(56,27,15,8,CREAM,0)+line(64,8,64,1,INK,1.5)+pool(43,114,43,7)+bush(14,102,8)+bush(111,102,8)
        elif kind=='batllo':
            b=path('M29 109V53Q33 37 54 38Q82 17 104 48V109Z','#BCD1C5',INK,2)+path('M29 52Q37 32 59 40Q80 19 105 45L105 54Q77 40 58 50Z','#84A69B',INK,2)
            for x in [38,59,81]:
                for y in [58,80]:b+=ellipse(x+6,y,6,8,BLUE,INK,1.2)
            if d>=1:
                for x in [34,57,80]:b+=path(f'M{x} 76Q{x+9} 66 {x+18} 76L{x+16} 82Q{x+9} 77 {x+2} 82Z',CREAM,INK,1.4)
                b+=rect(17,55,15,55,EARTH,3)+ellipse(23,51,11,11,WHITE,INK,1.4)
            if d==2:b+=path('M29 108V95Q34 83 50 89Q69 80 93 91V109Z',WHITE,INK,2)+windows([37,55,75],[94],11,15)+line(23,41,23,20,CREAM,3)+line(16,27,30,27,CREAM,3)
        else:
            b=path('M31 110Q20 88 34 75L39 66V44Q36 27 58 24Q82 23 81 43V69Q105 82 99 110Z',WHITE,INK,2)+path('M39 46Q38 20 59 18Q82 17 84 45Z',CREAM,INK,2)+ellipse(60,41,14,8,BLUE,INK,1.4)
            if d>=1:b+=rect(42,61,31,17,DARK,6)+windows([46,61],[65],8,10)+path('M32 108Q30 83 42 78H75Q89 82 91 109Z',EARTH,INK,1.8)
            if d==2:b+=path('M18 110Q14 88 35 85H93Q116 92 110 110Z',WHITE,INK,2)+arch(51,91,22,21,DARK)+steps(33,110,67,2)
        return b
    if kind in ['chrysler','fallingwater','barragan','ronchamp','guggenheimny','habitat','geodesic','pompidou']:
        if kind=='chrysler':
            b=rect(40,59,47,51,'#BBC3B5',0)+rect(49,38,28,25,CREAM,0)
            b+=path(f'M48 42Q48 27 63 {16-d*4}Q78 27 79 42Z','#A1B5B4',INK,2)+line(63,16-d*4,63,2,INK,1.4)
            b+=windows([46,60,75],[68,82,97],7,8)
            if d>=1:b+=rect(28,87,15,23,STONE,0)+rect(85,79,17,31,STONE,0)+path('M49 39L55 31L63 37L70 29L78 39','none',WHITE,2.7)+path('M44 62L32 55L43 52M84 62L97 55L85 52',CREAM)
            if d==2:b+=rect(16,100,96,11,STONE,0)+path('M50 28L58 22L64 28L70 21L76 27','none',WHITE,2.4)+windows([22,39,56,73,91],[102],10,8)
        elif kind=='fallingwater':
            b=path('M14 110Q26 77 49 81L70 103L117 108Z',STONE,INK,1.5)+pool(17,115,95,7)+rect(46,41-d*5,27,65+d*5,EARTH,0)+rect(28,78,66,20,BLUE,0)+rect(13,73,105,7,CREAM,0)
            if d>=1:b+=rect(37,57,68,17,BLUE,0)+rect(23,52,91,8,CREAM,0)+line(45,72,45,58,WHITE,2)+line(83,72,83,58,WHITE,2)
            if d==2:b+=rect(58,39,31,12,BLUE,0)+rect(44,33,58,8,CREAM,0)+path('M31 99Q47 97 51 112M54 100Q67 101 66 113','none','#C8E0D7',4)+bush(110,87,10)
        elif kind=='barragan':
            b=rect(21,58-d*9,58,52+d*9,'#D0A27C',0)+rect(71,83,40,28,'#B97872',0)+rect(55,85,17,26,DARK,0)
            if d>=1:b+=rect(15,83,30,27,'#D9BA79',0)+rect(82,46,24,53,'#A9BCC1',0)+windows([28],[68],17,13)
            if d==2:b+=pool(44,110,61,12)+rect(67,30,12,48,'#BB8173',0)+line(20,90,33,100,WHITE,2)+bush(109,98,7)
        elif kind=='ronchamp':
            b=path('M23 110L28 66Q62 76 95 61L105 109Z',WHITE,INK,2)+path('M18 56Q54 68 112 45L106 66Q60 85 21 70Z','#767E6D',INK,2)+arch(60,84,20,26,DARK)
            if d>=1:b+=path('M29 80Q12 71 18 42Q27 26 37 33L44 94Z',CREAM,INK,2)+windows([30,42,89],[86],5,9,'#BCB281')
            if d==2:b+=path('M84 75V37Q94 17 105 31L111 89Z',CREAM,INK,2)+windows([35,43,85,97],[96],5,6,BLUE)+steps(47,110,40,2)
        elif kind=='guggenheimny':
            b=path('M24 52Q67 41 105 54L91 107Q68 121 39 108Z',WHITE,INK,2)+ellipse(65,52,41,11,CREAM,INK,1.5)+ellipse(65,51,23,6,BLUE,INK,1.2)
            for y,w in [(68,75),(85,65),(99,55)][:1+d]:b+=path(f'M{65-w/2} {y}Q65 {y+13} {65+w/2} {y}','none','#AAAFA0',5)
            if d>=1:b+=rect(91,59,23,45,CREAM,0)+windows([97],[70,83],11,8)
            if d==2:b+=rect(16,96,94,14,WHITE,0)+windows([24,42,62,83],[100],14,8,BLUE)+steps(29,111,71,2)
        elif kind=='habitat':
            units=[(15,86),(44,86),(74,86),(30,61),(62,57),(88,65),(45,33),(74,37),(17,57)]
            for i,(x,y) in enumerate(units[:3+d*3]):
                b+=rect(x,y,27,23,CREAM if i%2 else STONE,0)+path(f'M{x} {y}L{x+6} {y-5}H{x+33}L{x+27} {y}Z',WHITE,INK,1)+rect(x+7,y+6,15,11,BLUE,0)
            if d==2:b+=bush(36,59,5)+bush(80,34,5)+steps(48,110,31,2)
        elif kind=='geodesic':
            b=dome(14,32-d*6,103,75+d*6,'#BED4C5')+path('M15 107H117',CREAM,INK,2)
            points={0:[(22,82),(43,53),(64,36),(86,53),(110,83),(92,106),(64,106),(37,106)],1:[(17,82),(38,48),(64,27),(93,50),(115,82),(98,106),(64,106),(31,106)],2:[(17,78),(36,43),(64,20),(95,44),(115,79),(98,106),(64,106),(30,106)]}[d]
            for i,(x,y) in enumerate(points):
                nx,ny=points[(i+1)%len(points)];b+=line(x,y,nx,ny,'#71958D',1.7)+line(x,y,64,76,'#71958D',1.7)
            if d>=1:b+=ellipse(64,76,21,20,'none','#71958D',1.5)+rect(54,89,23,21,DARK,0)
            if d==2:b+=path('M52 107V87Q64 77 79 87V107Z',BLUE,INK,1.5)+steps(38,110,56,2)
        else:
            b=rect(20,39-d*5,89,71+d*5,WHITE,0)+rect(28,47,73,51,BLUE,0)
            for x in range(27,107,17):b+=line(x,41,x,110,INK,2)
            for y in [55,70,84,99]:b+=line(20,y,111,y,CREAM,3)
            if d>=1:b+=path('M24 105L96 50L103 55L30 111Z','#BA7D64',INK,1.5)+rect(13,55,10,55,'#A1B888',0)+rect(106,49,9,61,'#A1B888',0)
            if d==2:b+=path('M14 54V24H24V36H103V22H114V49','none',BLUE,7)+steps(29,111,67,2)+line(16,84,112,43,'#D4B876',2)
        return b
    if kind in ['louvre','dancing','petronas','sailtower','biomes','birdnest','marinabay','cctv','shard','heydar','bosco','libraryeye']:
        if kind=='louvre':
            b=path('M15 108L64 36L115 108Z','#A1C3CB',INK,2)+path('M64 36L77 108H115Z','#80A7B5',INK,1.2)
            for y in [64,82,97]:b+=line(15+(108-y)*.68,y,115-(108-y)*.71,y,WHITE,1.2)
            for x in [30,49,73,95]:b+=line(64,36,x,107,WHITE,1.2)
            if d>=1:b+=path('M8 112L25 82L41 112Z',BLUE,INK,1.5)+rect(13,107,103,5,CREAM,0)
            if d==2:b+=path('M89 113L108 75L123 113Z',BLUE,INK,1.5)+pool(43,116,40,6)+rect(15,79,16,22,CREAM,0)
        elif kind=='dancing':
            b=path('M21 111Q34 89 27 73Q17 55 30 37L48 34Q61 59 49 78Q44 90 62 111Z','url(#glass)',INK,2)+path('M62 110L61 41Q82 28 103 42L111 110Z',CREAM,INK,2)
            b+=windows([69,87],[52,70,88],9,10)
            if d>=1:b+=path('M24 51L50 56M24 69L51 73M29 90L55 94','none',WHITE,3)+path('M68 40Q81 15 94 26L104 43Z',STONE,INK,1.5)
            if d==2:b+=path('M14 111L22 74L31 84L29 111Z',WHITE)+path('M102 109L103 64L115 76L118 111Z',WHITE)+rect(43,103,45,9,BLUE,0)+steps(28,111,74,2)
        elif kind=='petronas':
            def tower(x):
                t=rect(x,45,23,65,'#9FB7B4',0)+rect(x+3,26,17,22,CREAM,0)+dome(x+3,15,17,13,STONE)+line(x+11,15,x+11,2,INK,1.5)
                return t+''.join(rect(x-2,y,27,4,WHITE,0) for y in range(52,105,10))
            b=tower(26)+tower(79)
            if d>=1:b+=rect(44,60,42,9,BLUE,0)+line(45,68,51,80,CREAM,2)+line(86,68,79,80,CREAM,2)
            if d==2:b+=rect(15,94,99,17,STONE,0)+windows([23,43,63,83],[99],14,8)+steps(33,111,60,2)+dome(52,82,27,14,CREAM)
        elif kind=='sailtower':
            b=pool(11,113,106,9)+path('M36 109Q54 79 51 34L68 8Q69 73 109 108Z',WHITE,INK,2)+path('M54 96Q64 62 66 25Q91 48 101 98Z','url(#glass)',INK,1.5)+rect(35,104,73,7,CREAM,0)
            if d>=1:b+=path('M54 80L94 80M59 63L86 63M63 45L77 45','none',WHITE,3)+ellipse(66,31,17,4,STONE,INK,1.4)
            if d==2:b+=rect(26,99,14,12,STONE,0)+path('M11 115Q35 99 61 111','none',CREAM,6)+ellipse(111,101,11,4,CREAM,INK,1.2)
        elif kind=='biomes':
            for x,y,w,h in [(38,39,59,66),(13,66,43,43),(81,61,36,48)][:1+d]:
                b+=dome(x,y,w,h,'#BFD4BA')
                clip=f'biome-{x}-{d}'
                b+=f'<clipPath id="{clip}">{dome(x,y,w,h,"#fff")}</clipPath><g clip-path="url(#{clip})">'
                for ratio in [.28,.55,.80]:b+=path(f'M{x+w*.07} {y+h*ratio}Q{x+w/2} {y+h*ratio-14} {x+w*.93} {y+h*ratio}','none','#7D9C85',1.6)
                for xx in [x+w*.28,x+w*.53,x+w*.76]:b+=path(f'M{xx} {y+h}Q{xx-12} {y+h*.35} {x+w/2} {y}','none','#7D9C85',1.6)
                b+='</g>'+dome(x,y,w,h,'none')
            if d>=1:b+=bush(62,100,9)
            if d==2:b+=bush(98,99,7)+rect(49,94,20,16,BLUE,2)+steps(36,110,49,2)
        elif kind=='birdnest':
            b=path('M14 78Q15 61 63 54Q112 55 116 76L110 107Q63 121 19 106Z',STONE,INK,2)+ellipse(65,75,46,14,WHITE,INK,1.5)+ellipse(65,75,29,8,DARK,INK,1.1)
            paths=['M18 82L108 103M20 99L107 74M38 63L72 112M68 56L96 110M100 62L41 110','M15 93L104 66M30 106L84 59M57 114L113 81M17 79L53 112','M18 105L104 84M22 66L84 112M43 59L112 99M86 59L20 103']
            for p in paths[:d+1]:b+=path(p,'none',CREAM,3.2)
            if d==2:b+=rect(11,108,108,4,STONE,0)+steps(39,112,52,2)
        elif kind=='marinabay':
            for x in [21,52,86]:b+=path(f'M{x} 110Q{x+6} 70 {x+2} 43L{x+21} 42Q{x+28} 84 {x+19} 111Z','url(#glass)',INK,1.8)+''.join(line(x+3,y,x+21,y,WHITE,1.3) for y in range(52,107,9))
            b+=path('M11 42Q40 29 116 33L111 45Q67 53 17 50Z',CREAM,INK,2)
            if d>=1:b+=path('M17 40Q62 28 111 35L107 40Q66 39 27 45Z','#91AF7A',INK,1)+pool(32,40,68,4)
            if d==2:b+=path('M16 109Q33 88 48 105Q68 92 85 109Z',WHITE,INK,1.8)+pool(46,115,66,6)+bush(105,34,6)
        elif kind=='cctv':
            b=path('M22 109L34 31L54 22L95 30L110 81L92 96L73 54L56 56L43 110Z','url(#glass)',INK,2)+path('M54 22L62 36L82 40L73 54L56 56L51 39Z',DARK,INK,1.4)
            if d>=1:
                for x,y,xx,yy in [(29,80,47,90),(35,59,51,66),(40,40,53,45),(83,53,105,74),(90,74,110,81)]:b+=line(x,y,xx,yy,WHITE,2)
                b+=path('M23 107L52 39M34 31L42 110M74 53L105 80','none','#789EAA',1.7)
            if d==2:b+=rect(16,101,34,10,STONE,0)+path('M65 105L103 88L118 105V111H65Z',CREAM)+windows([78,96],[103],13,7)
        elif kind=='shard':
            b=path('M38 111L63 9L77 42L94 111Z','url(#glass)',INK,2)+path('M63 9L60 111H39Z','#B9D4D4',INK,1)+path('M65 26L71 4L79 110H63Z','#93B4BE',INK,1.2)
            for y in [49,66,83,100]:b+=line(48,y,82,y,WHITE,1.3)
            if d>=1:b+=path('M27 111L45 63L51 111Z',BLUE,INK,1.7)+path('M80 110L82 72L104 110Z',BLUE,INK,1.7)
            if d==2:b+=rect(16,96,28,15,CREAM,0)+rect(95,93,20,18,CREAM,0)+windows([20,98],[101],15,7)+steps(42,111,45,2)
        elif kind=='heydar':
            b=path('M12 107Q24 78 46 88Q69 95 74 48Q78 18 99 40Q101 62 117 109Z',WHITE,INK,2)+path('M26 103Q46 88 65 103Q85 112 96 81Q100 92 112 107Z',BLUE,INK,1.6)
            if d>=1:b+=path('M16 109Q16 70 37 61Q62 51 71 88Q80 100 99 107Z',CREAM,INK,2)+path('M26 98Q42 73 69 104','none',WHITE,3)
            if d==2:b+=path('M10 111Q29 100 54 110Q80 120 120 111Z',WHITE,INK,1.5)+path('M43 65Q65 71 87 104M83 41Q76 65 94 79','none','#A6B7AD',1.4)+steps(23,112,82,2)
        elif kind=='bosco':
            b=rect(26,42,32,68,STONE,0)+rect(72,25,29,84,STONE,0)+windows([33,47],[50,68,88],7,11)+windows([78,91],[33,51,70,89],6,11)
            for x,y,w in [(18,62,48),(64,44,45),(19,85,47),(66,70,45),(22,102,43),(66,96,47)][:2+d*2]:b+=rect(x,y,w,5,CREAM,0)+bush(x+9,y-4,7)+bush(x+w-8,y-5,6)
            if d==2:b+=bush(42,37,9)+bush(85,19,9)+steps(47,111,35,2)
        else:
            b=path('M13 109V49Q64 24 115 49V109Z',WHITE,INK,2)+ellipse(65,77,31,29,BLUE,INK,2)+ellipse(65,79,17,17,CREAM,INK,1.5)
            for y in [47,57,94,104][:2+d]:b+=path(f'M16 {y}Q64 {y+17} 112 {y}','none','#A8B9AC',3)
            if d>=1:b+=path('M21 101Q15 75 39 62M94 61Q120 79 108 105','none',CREAM,7)
            if d==2:b+=path('M21 96Q21 78 38 71M92 70Q107 81 105 96','none',WHITE,4)+rect(47,100,36,11,DARK,0)+steps(33,111,64,2)
        return b
    raise KeyError(kind)


DEFS = '''<defs>
<linearGradient id="seed"><stop stop-color="#E5BF79"/><stop offset="1" stop-color="#B27943"/></linearGradient>
<linearGradient id="bark"><stop stop-color="#B18A53"/><stop offset="1" stop-color="#795B37"/></linearGradient>
<linearGradient id="window" x2="0" y2="1"><stop stop-color="#D0DFCD"/><stop offset="1" stop-color="#7EABB4"/></linearGradient>
<linearGradient id="glass"><stop stop-color="#D5E9E2"/><stop offset=".4" stop-color="#ACCED4"/><stop offset="1" stop-color="#6D9CA9"/></linearGradient>
</defs>'''


def artwork(stage,d):
    kind=stage['kind'];defs=DEFS
    if kind in ['seed','sprout','sapling','tree']:body=plant(kind,d)
    elif kind in ['fire','cave','hammock','hut','yurt','stilts']:body=camping(kind,d)
    elif kind=='base':
        body=old_subject(stage['arg'],d)
        if stage['arg']==52:
            outline='M43 109Q36 78 47 46Q50 23 68 10L78 13Q88 42 82 70Q78 95 88 109Z'
            defs=defs.replace('</defs>',f'<clipPath id="shanghaiClip">{path(outline,"#fff","none",0)}</clipPath></defs>')
        if stage['arg']==53:
            _,outline=a.tower(53)
            defs=defs.replace('</defs>',f'<clipPath id="towerClip">{path(outline,"#fff","none",0)}</clipPath></defs>')
    else:body=new_subject(kind,d)
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 128 128">{defs}<g stroke-linecap="round" stroke-linejoin="round">{ellipse(64,116,43,4,"#A1ADA1")}{a.ground(stage["stage"]>=50)}<g transform="translate(0 3) scale(1 .97)">{body}</g></g></svg>'
