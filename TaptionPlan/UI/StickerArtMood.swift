extension StickerCatalog {
    /// 표정 파츠는 검정 선 위주라 단색·다색이 함께 쓴다. `A`는 얼굴색, `B`·`C`는 강조색.
    static let moodParts = #"""
    mood.round|A o 50 52 39
    mood.cheek|pink! e 24 66 7 4.5;pink! e 76 66 7 4.5
    mood.dots|k o 36 54 4.6;k o 64 54 4.6
    mood.arcup|k q 3.6 27 58 36 44 45 58;k q 3.6 55 58 64 44 73 58
    mood.arcdown|k q 3.6 27 50 36 62 45 50;k q 3.6 55 50 64 62 73 50
    mood.smile|k q 3.2 40 66 50 77 60 66
    mood.open|k s M35 62 L65 62 C66 86 34 86 35 62 Z
    mood.frown|k q 3.2 40 75 50 64 60 75
    mood.flat|k l 3.2 42 71 58 71
    mood.drop|A s M50 12 C50 12 26 46 26 62 C26 77 37 88 50 88 C63 88 74 77 74 62 C74 46 50 12 50 12 Z
    mood.brow.sad|k l 3.2 26 44 40 37;k l 3.2 74 44 60 37
    mood.brow.mad|k l 4.2 25 37 43 47;k l 4.2 75 37 57 47
    mood.lid|k l 3.6 25 49 47 49;k l 3.6 53 49 75 49;k s M29 50 L43 50 C43 62 29 62 29 50 Z;k s M57 50 L71 50 C71 62 57 62 57 50 Z
    mood.vein|B! l 3 58 24 62 24 62 20;B! l 3 67 20 67 24 71 24;B! l 3 58 30 62 30 62 34;B! l 3 67 34 67 30 71 30
    mood.thumb|A b 24 44 52 40 12;A b 36 10 18 46 9;k l 2.6 30 58 70 58;k l 2.6 30 70 70 70
    mood.crown|A p 2.5 18 76 12 28 34 50 50 18 66 50 88 28 82 76
    mood.f.happy|@mood.arcup;@mood.open;B! e 50 76 8 5
    mood.f.flutter|k o 35 53 8;k o 65 53 8;A! o 38 50 3;A! o 68 50 3;k q 3.2 43 68 50 75 57 68;B heart 80 24 18
    mood.f.proud|@mood.arcup;k q 3.6 36 68 52 80 66 62;B star 84 26 13 4.5 4;B star 15 28 9 3 4
    mood.f.calm|@mood.arcdown;k q 3 43 69 50 74 57 69;B e 40 17 9 5 25;B e 60 17 9 5 -25;k l 2.6 50 26 50 16
    mood.f.thrill|B star 35 52 13 6 5;B star 65 52 13 6 5;@mood.open;C! e 50 76 8 5;C star 14 22 7 2.5 4;C star 86 22 7 2.5 4
    mood.f.love|B heart 35 52 22;B heart 65 52 22;k q 3.2 41 68 50 78 59 68
    mood.f.thanks|@mood.arcup;k q 3 43 64 50 70 57 64;B heart 50 80 24;C o 31 80 7;C o 69 80 7
    mood.f.laugh|k l 3.8 27 44 43 52 27 60;k l 3.8 73 44 57 52 73 60;@mood.open;C! e 50 76 8 5;@mood.drop 12 46 .2 A=B;@mood.drop 88 46 .2 A=B
    mood.f.tears|@mood.brow.sad;k l 3.6 28 52 44 52;k l 3.6 56 52 72 52;k e 50 70 8 6;B b 30 53 12 36 6;B b 58 53 12 36 6
    mood.f.sad|@mood.brow.sad;@mood.dots;@mood.frown;@mood.drop 66 68 .24 A=B
    mood.f.gloom|B! l 2.8 34 18 34 30;B! l 2.8 44 15 44 31;B! l 2.8 54 15 54 31;B! l 2.8 64 17 64 30;@mood.lid;k q 3 42 74 50 69 58 74
    mood.f.angry|@mood.brow.mad;k o 37 57 4.4;k o 63 57 4.4;k q 3.6 38 76 50 66 62 76;@mood.vein
    mood.f.annoy|@mood.lid;k l 3.2 34 74 41 67 50 74 59 67 66 74;@mood.vein
    mood.f.tired|@mood.lid;k q 2.4 28 66 36 69 44 66;k q 2.4 56 66 64 69 72 66;k q 3 42 76 46 72 50 76;k q 3 50 76 54 80 58 76;@mood.drop 84 34 .22 A=B
    mood.f.sleepy|@mood.arcdown;k e 46 70 3.4 2.8;C o 58 68 7;B! t 54 34 17 Z;B! t 68 26 12 Z
    mood.f.sick|k l 3.6 28 56 44 50;k l 3.6 72 56 56 50;k q 3 38 70 44 66 50 70;k l 8 50 70 76 84;C l 4 50 70 76 84;D! o 76 84 3;B b 60 18 30 13 5 28;k l 2.4 71 24 77 28;k l 2.4 77 22 71 30
    mood.f.wow|k l 3 26 34 42 30;k l 3 74 34 58 30;k o 35 51 8.5;k o 65 51 8.5;A! o 37.5 48 3;A! o 67.5 48 3;k e 50 72 7.5 9.5;B b 84 10 6.5 17 3.2;B o 87 33 3.6
    mood.f.flustered|k o 35 52 8.5;A o 35 52 4.6;k o 35 52 1.8;k o 65 52 8.5;A o 65 52 4.6;k o 65 52 1.8;k l 3.2 34 73 41 67 50 73 59 67 66 73;@mood.drop 86 28 .34 A=B
    mood.f.shy|k q 3.6 28 52 36 58 44 52;k q 3.6 56 52 64 58 72 52;k q 3 44 70 50 66 56 70;B! l 2.8 17 68 22 60;B! l 2.8 24 70 29 62;B! l 2.8 31 72 36 64;B! l 2.8 83 68 78 60;B! l 2.8 76 70 71 62;B! l 2.8 69 72 64 64
    mood.f.blank|k o 33 54 2.8;k o 67 54 2.8;k l 3 44 71 56 71;B o 38 36 3.2;B o 50 36 3.2;B o 62 36 3.2
    mood.f.hungry|k o 35 48 5;k o 65 48 5;A! o 37 46 1.8;A! o 67 46 1.8;@mood.open;B! e 50 76 8 5;@mood.drop 62 86 .17 A=C
    mood.f.full|@mood.arcup;k q 3.2 40 66 50 74 60 66;B s M45 71 L55 71 C56 83 44 83 45 71 Z;C o 82 26 9;C o 72 12 4.5
    mood.f.nervous|k l 3 26 40 38 34;k l 3 74 40 62 34;k o 35 52 4;k o 65 52 4;C b 32 64 36 16 6;k l 2.4 41 65 41 79;k l 2.4 50 65 50 79;k l 2.4 59 65 59 79;k l 2.4 33 72 67 72;@mood.drop 15 38 .2 A=B;@mood.drop 86 30 .24 A=B
    mood.f.bored|k l 3.6 25 49 47 49;k l 3.6 53 49 75 49;k s M36 50 L47 50 C47 61 36 61 36 50 Z;k s M64 50 L75 50 C75 61 64 61 64 50 Z;k l 3.2 44 72 62 68;C o 80 74 5;C o 88 66 3
    mood.f.best|@mood.arcup;@mood.open;@mood.crown 50 19 .4 A=B;@mood.thumb 79 74 .46 A=C
    mood.f.meh|@mood.lid;k q 3 40 74 50 69 60 74;@mood.thumb 79 74 .46 180 A=C
    mood.meter|A o 13 86 5.5;B o 31.5 86 5.5;C o 50 86 5.5;D o 68.5 86 5.5;E o 87 86 5.5
    mood.level.1|@mood.brow.sad;@mood.dots;k s M38 80 C38 62 62 62 62 80 Z
    mood.level.2|@mood.dots;@mood.frown
    mood.level.3|@mood.dots;@mood.flat
    mood.level.4|@mood.dots;@mood.smile
    mood.level.5|@mood.arcup;@mood.open
    """#

    static let weatherParts = #"""
    weather.cloud|A s M26 74 C8 74 4 52 20 46 C18 28 40 18 52 32 C64 18 86 28 80 46 C96 50 94 74 76 74 Z
    weather.sun|A star 50 50 44 31 12;A o 50 50 27
    weather.face|k o 39 52 4;k o 61 52 4;k q 2.8 44 60 50 66 56 60
    weather.sadface|k o 39 50 4;k o 61 50 4;k q 2.8 44 64 50 58 56 64
    weather.ears|A p 4 22 34 20 8 40 24;A p 4 78 34 80 8 60 24
    weather.drop|A s M50 12 C50 12 26 46 26 62 C26 77 37 88 50 88 C63 88 74 77 74 62 C74 46 50 12 50 12 Z
    weather.flake|A l 7 50 12 50 88;A l 7 17 31 83 69;A l 7 17 69 83 31;A l 5 40 18 50 28 60 18;A l 5 40 82 50 72 60 82
    weather.bolt|A p 3 58 8 26 54 46 54 36 92 76 40 54 40 68 8
    weather.umbrella|k l 4.5 50 22 50 10;A s M10 54 C12 12 88 12 90 54 C84 44 76 44 70 54 C64 44 56 44 50 54 C44 44 36 44 30 54 C24 44 16 44 10 54 Z;k l 4.5 50 54 50 80;k q 4.5 50 80 52 92 64 84
    weather.boot|A p 4 28 12 60 12 60 58 88 68 88 90 28 90;B! b 30 26 28 9 2
    weather.moon|A s M64 10 C36 10 14 30 14 54 C14 76 34 92 58 92 C72 92 84 84 90 72 C62 80 42 64 44 40 C46 26 54 16 64 10 Z
    weather.mask|A q 4 22 40 0 52 22 64;A q 4 78 40 100 52 78 64;A b 18 30 64 44 15;k l 2.6 26 44 74 44;k l 2.6 24 53 76 53;k l 2.6 26 62 74 62
    weather.shades|k l 3.8 8 42 14 40;k l 3.8 92 42 86 40;k q 3.8 44 44 50 40 56 44;A b 10 36 36 30 12;A b 54 36 36 30 12
    weather.fan|A b 42 62 16 30 7;B o 50 38 30;C! e 50 25 9 12;C! e 39 44 9 12 120;C! e 61 44 9 12 240;k o 50 38 5;A p 4 26 18 22 6 38 12;A p 4 74 18 78 6 62 12
    weather.scarf|A b 16 20 68 26 13;A b 52 40 22 46 6;B! b 52 58 22 8 0;B! b 52 72 22 8 0;B! b 28 22 9 22 0;B! b 44 22 9 22 0;B! b 62 22 9 22 0
    weather.mitten|A s M26 62 C20 30 28 10 46 10 C64 10 72 28 72 62 Z;A e 76 42 9 15 22;B b 22 62 54 26 8;k l 2.4 34 66 34 84;k l 2.4 50 66 50 84;k l 2.4 66 66 66 84
    weather.typhoon|A q 12 50 16 88 18 82 52;A q 12 50 84 12 82 18 48;A o 50 50 24;k o 50 50 8
    weather.wind|A l 8 10 34 58 34;A q 8 58 34 80 32 76 16;A l 8 10 54 72 54;A q 8 72 54 96 54 88 72;A l 8 18 74 44 74;A q 8 44 74 58 76 54 90
    weather.leaf|A s M12 50 C24 18 62 14 88 50 C62 86 24 82 12 50 Z;k l 3 12 50 80 50
    weather.gauge|A b 14 28 72 44 22
    """#

    static let seasonsParts = #"""
    seasons.cane.fullc|@seasons.cane A=w;red! l 5 57.5 82 66.5 76;red! l 5 57.5 64 66.5 58;red! l 5 57.5 46 66.5 40;red! l 5 55 21 60 15;red! l 5 42 8.5 42 15.5;red! l 5 28.5 13 33.5 18
    seasons.cane.fullm|@seasons.cane A=T;k l 4 57.5 82 66.5 76;k l 4 57.5 64 66.5 58;k l 4 57.5 46 66.5 40;k l 4 55 21 60 15;k l 4 42 8.5 42 15.5;k l 4 28.5 13 33.5 18
    seasons.blossom|A e 50 28 13 20;A e 71 43 13 20 72;A e 63 68 13 20 144;A e 37 68 13 20 216;A e 29 43 13 20 288;B! o 50 50 6;B! l 2 50 44 50 34;B! l 2 56 49 66 45;B! l 2 54 55 60 64;B! l 2 46 55 40 64;B! l 2 44 49 34 45
    seasons.maple|A p 2.5 50 8 60 28 74 22 70 40 90 42 74 58 80 68 56 66 54 92 46 92 44 66 20 68 26 58 10 42 30 40 26 22 40 28
    seasons.ginkgo|A s M50 62 C22 62 8 42 12 22 C26 28 36 22 48 12 L50 34 L52 12 C64 22 74 28 88 22 C92 42 78 62 50 62 Z;A b 46 60 8 32 4
    seasons.cake|A p 4 16 54 84 54 84 88 16 88;B s M16 56 L84 56 L84 66 C78 74 72 66 66 66 C60 66 56 76 50 76 C44 76 40 66 34 66 C28 66 22 74 16 66 Z;C b 45 30 10 24 4;D p 3 50 12 56 24 50 30 44 24
    seasons.gift|A b 14 44 72 44 6;A b 10 30 80 20 6;B! b 42 31 16 18 0;B! b 42 51 16 36 0;C e 36 22 15 9 25;C e 64 22 15 9 -25;C o 50 26 7
    seasons.balloon|k q 2.8 50 62 42 76 52 92;A s M46 66 L54 66 L58 72 L42 72 Z;A e 50 36 27 32
    seasons.cone|A p 4 50 8 82 84 18 84;B! q 6 36 50 50 56 64 50;B! q 6 26 68 50 76 74 68;C o 50 11 7
    seasons.pumpkin|B p 2 44 22 56 22 58 8 46 8;A e 28 56 20 30;A e 72 56 20 30;A e 50 56 22 32
    seasons.ghost|A s M18 88 L18 42 C18 4 82 4 82 42 L82 88 C76 80 70 80 66 88 C60 80 56 80 50 88 C44 80 40 80 34 88 C30 80 24 80 18 88 Z
    seasons.tree|B b 42 76 16 16 3;A p 4 50 8 72 38 62 38 80 58 66 58 86 82 14 82 34 58 20 58 38 38 28 38
    seasons.sock|A p 6 32 10 66 10 66 54 84 62 84 86 52 90 32 66;B b 28 8 42 18 6
    seasons.cane|A l 13 62 92 62 34;A q 13 62 34 62 12 42 12;A q 13 42 12 28 12 26 26
    seasons.santa|A s M14 72 C20 26 50 8 76 26 C72 40 80 52 84 66 L84 72 Z;B b 8 66 80 22 11;B o 84 58 10
    seasons.pouch|A s M28 40 C10 56 12 90 50 90 C88 90 90 56 72 40 Z;A s M34 34 L24 14 L40 22 L50 12 L60 22 L76 14 L66 34 Z;B b 30 34 40 8 4
    seasons.ring|A s M50 26 C22 26 18 50 18 58 C18 78 34 92 50 92 C66 92 82 78 82 58 C82 50 78 26 50 26 Z M50 40 C62 40 68 48 68 58 C68 70 60 78 50 78 C40 78 32 70 32 58 C32 48 38 40 50 40 Z
    seasons.bow|A s M50 42 C34 22 12 18 10 30 C8 44 28 54 50 52 Z;A s M50 42 C66 22 88 18 90 30 C92 44 72 54 50 52 Z;A p 3 44 50 22 92 36 86 44 92 52 54;A p 3 56 50 78 92 64 86 56 92 48 54;A o 50 46 9
    seasons.pinwheel|A p 2 50 50 50 12 76 26;B p 2 50 50 88 50 74 76;A p 2 50 50 50 88 24 74;B p 2 50 50 12 50 26 24;k o 50 50 4
    """#

    static let moodSource = #"""
    mood.happy.m|행복|Happy|m|@mood.round A=T;@mood.f.happy B=T
    mood.flutter.m|설렘|Flutter|m|@mood.round A=T;@mood.f.flutter A=T B=T
    mood.proud.m|뿌듯|Proud|m|@mood.round A=T;@mood.f.proud B=T
    mood.calm.m|평온|Calm|m|@mood.round A=T;@mood.f.calm B=T
    mood.thrill.m|신남|Thrilled|m|@mood.round A=T;@mood.f.thrill B=k C=T
    mood.love.m|사랑|Love|m|@mood.round A=T;@mood.f.love B=k
    mood.thanks.m|감사|Thankful|m|@mood.round A=T;@mood.f.thanks B=T C=T
    mood.laugh.m|웃음|Laugh|m|@mood.round A=T;@mood.f.laugh B=T C=T
    mood.tears.m|눈물|Tears|m|@mood.round A=T;@mood.f.tears B=T
    mood.sad.m|슬픔|Sad|m|@mood.round A=T;@mood.f.sad B=T
    mood.gloom.m|우울|Gloomy|m|@mood.round A=T;@mood.f.gloom B=k
    mood.angry.m|화남|Angry|m|@mood.round A=T;@mood.f.angry B=k
    mood.annoy.m|짜증|Annoyed|m|@mood.round A=T;@mood.f.annoy B=k
    mood.tired.m|피곤|Tired|m|@mood.round A=T;@mood.f.tired B=T
    mood.sleepy.m|졸림|Sleepy|m|@mood.round A=T;@mood.f.sleepy B=k C=T
    mood.sick.m|아픔|Sick|m|@mood.round A=T;@mood.f.sick B=T C=T D=k
    mood.wow.m|놀람|Surprised|m|@mood.round A=T;@mood.f.wow A=T B=T
    mood.flustered.m|당황|Flustered|m|@mood.round A=T;@mood.f.flustered A=T B=T
    mood.shy.m|부끄러움|Shy|m|@mood.round A=T;@mood.f.shy B=k
    mood.blank.m|멍|Blank|m|@mood.round A=T;@mood.f.blank B=k
    mood.hungry.m|배고픔|Hungry|m|@mood.round A=T;@mood.f.hungry A=T B=T C=T
    mood.full.m|배부름|Full|m|@mood.round A=T;@mood.f.full B=T C=T
    mood.nervous.m|긴장|Nervous|m|@mood.round A=T;@mood.f.nervous B=T C=T
    mood.bored.m|심심|Bored|m|@mood.round A=T;@mood.f.bored C=T
    mood.best.m|최고|The best|m|@mood.round A=T;@mood.f.best B=T C=T
    mood.meh.m|별로|Not great|m|@mood.round A=T;@mood.f.meh C=T
    mood.scale1.m|기분 1|Mood 1|m|@mood.round 50 38 .8 A=T;@mood.level.1 50 38 .8;@mood.meter A=k B=T C=T D=T E=T
    mood.scale2.m|기분 2|Mood 2|m|@mood.round 50 38 .8 A=T;@mood.level.2 50 38 .8;@mood.meter A=k B=k C=T D=T E=T
    mood.scale3.m|기분 3|Mood 3|m|@mood.round 50 38 .8 A=T;@mood.level.3 50 38 .8;@mood.meter A=k B=k C=k D=T E=T
    mood.scale4.m|기분 4|Mood 4|m|@mood.round 50 38 .8 A=T;@mood.level.4 50 38 .8;@mood.meter A=k B=k C=k D=k E=T
    mood.scale5.m|기분 5|Mood 5|m|@mood.round 50 38 .8 A=T;@mood.level.5 50 38 .8;@mood.meter A=k B=k C=k D=k E=k
    mood.happy.d|행복 춘향이|Happy Chunhyang|d|@cat.chunhyang;@mood.f.happy B=red
    mood.flutter.d|설렘 야옹|Flutter cat|d|@catbase A=pink B=rose;@mood.f.flutter A=w B=red
    mood.proud.d|뿌듯 야옹|Proud cat|d|@catbase A=butter B=peach;@mood.f.proud B=orange
    mood.calm.c|평온 야옹|Calm cat|c|@catbase A=mint B=w;@mood.f.calm B=leaf
    mood.thrill.d|신남 얼굴|Thrilled face|d|@mood.round A=yellow;@mood.cheek;@mood.f.thrill B=orange C=rose
    mood.love.d|사랑 화랑이|Love Hwarang|d|@cat.hwarang;@mood.f.love B=red
    mood.thanks.c|감사 야옹|Thankful cat|c|@catbase A=peach B=rose;@mood.f.thanks B=red C=peach
    mood.laugh.d|웃음 얼굴|Laugh face|d|@mood.round A=yellow;@mood.f.laugh B=sky C=rose
    mood.tears.d|눈물 윤복이|Tears Yunbok|d|@cat.yunbok;@mood.f.tears B=sky
    mood.sad.c|슬픔 야옹|Sad cat|c|@catbase A=sky B=w;@mood.f.sad B=blue
    mood.gloom.c|우울 야옹|Gloomy cat|c|@catbase A=lilac B=w;@mood.f.gloom B=purple
    mood.angry.d|화남 얼굴|Angry face|d|@mood.round A=red;@mood.f.angry B=choco
    mood.annoy.c|짜증 야옹|Annoyed cat|c|@catbase A=orange B=butter;@mood.f.annoy B=red
    mood.tired.c|피곤 얼굴|Tired face|c|@mood.round A=gray;@mood.f.tired B=sky
    mood.sleepy.d|졸림 야옹|Sleepy cat|d|@catbase A=lilac B=pink;@mood.f.sleepy B=navy C=sky
    mood.sick.c|아픔 야옹|Sick cat|c|@catbase A=#C9E4B4 B=w;@mood.f.sick B=w C=w D=red
    mood.wow.d|놀람 춘향이|Surprised Chunhyang|d|@cat.chunhyang;@mood.f.wow A=w B=red
    mood.flustered.c|당황 얼굴|Flustered face|c|@mood.round A=butter;@mood.f.flustered A=w B=sky
    mood.shy.d|부끄러움 화랑이|Shy Hwarang|d|@cat.hwarang;@mood.f.shy B=red
    mood.blank.c|멍 야옹|Blank cat|c|@catbase A=cream B=pink;@mood.f.blank B=dark
    mood.hungry.d|배고픔 윤복이|Hungry Yunbok|d|@cat.yunbok;@mood.f.hungry A=w B=rose C=sky
    mood.full.d|배부름 얼굴|Full face|d|@mood.round A=peach;@mood.cheek;@mood.f.full B=rose C=w
    mood.nervous.c|긴장 얼굴|Nervous face|c|@mood.round A=butter;@mood.f.nervous B=sky C=w
    mood.bored.c|심심 야옹|Bored cat|c|@catbase A=tan B=pink;@mood.f.bored C=w
    mood.best.d|최고 야옹|The best cat|d|@catbase A=butter B=peach;@mood.f.best B=yellow C=w
    mood.meh.c|별로 야옹|Not great cat|c|@catbase A=gray B=w;@mood.f.meh C=w
    mood.scale1.c|기분 1 얼굴|Mood 1 face|c|@mood.round 50 38 .8 A=red;@mood.level.1 50 38 .8;@mood.meter A=red B=w C=w D=w E=w
    mood.scale2.c|기분 2 얼굴|Mood 2 face|c|@mood.round 50 38 .8 A=orange;@mood.level.2 50 38 .8;@mood.meter A=orange B=orange C=w D=w E=w
    mood.scale3.c|기분 3 얼굴|Mood 3 face|c|@mood.round 50 38 .8 A=yellow;@mood.level.3 50 38 .8;@mood.meter A=yellow B=yellow C=yellow D=w E=w
    mood.scale4.c|기분 4 얼굴|Mood 4 face|c|@mood.round 50 38 .8 A=mint;@mood.level.4 50 38 .8;@mood.meter A=mint B=mint C=mint D=mint E=w
    mood.scale5.c|기분 5 얼굴|Mood 5 face|c|@mood.round 50 38 .8 A=green;@mood.level.5 50 38 .8;@mood.meter A=green B=green C=green D=green E=green
    mood.heartsun.m|마음의 해|Heart sun|m|T star 50 52 44 32 12;k heart 50 52 40
    mood.heartsun.d|마음의 해 입체|Heart sun puffy|d|orange star 50 52 44 32 12;red heart 50 52 42
    mood.heartrain.m|마음의 비구름|Heart rain cloud|m|@weather.cloud 50 36 .84 A=T;@weather.sadface 50 34 .84;T heart 28 80 18;T heart 50 86 18;T heart 72 80 18
    mood.heartrain.c|마음의 비구름 색|Heart rain cloud color|c|@weather.cloud 50 36 .84 A=gray;@weather.sadface 50 34 .84;sky heart 30 80 17;blue heart 50 86 17;sky heart 70 80 17
    mood.heartbolt.c|마음의 번개|Heart lightning|c|@weather.cloud 50 34 .84 A=dark;w! heart 50 34 22;@weather.bolt 50 72 .42 A=yellow
    mood.heartclear.d|마음 맑음|Clear heart|d|@weather.sun 50 50 1 A=yellow;@weather.face;pink! e 32 60 5 3.4;pink! e 68 60 5 3.4
    mood.heartfog.m|마음 흐림|Foggy heart|m|T heart 50 40 58;T l 5 12 74 88 74;T l 5 22 88 78 88
    mood.heartbow.c|마음 무지개|Heart rainbow|c|red q 8 12 74 50 -22 88 74;yellow q 8 23 74 50 2 77 74;sky q 8 34 74 50 26 66 74;rose heart 50 74 20
    """#

    static let weatherSource = #"""
    weather.sun.m|해|Sun|m|@weather.sun A=T;k o 50 50 7
    weather.sun.d|맑음|Sunny|d|@weather.sun A=yellow;@weather.face;pink! e 32 60 5 3.4;pink! e 68 60 5 3.4
    weather.suncat.d|고양이 해|Cat sun|d|@weather.sun A=yellow;orange p 3 22 34 20 8 40 24;orange p 3 78 34 80 8 60 24;k q 3 28 52 36 44 44 52;k q 3 56 52 64 44 72 52;k q 2.6 44 60 47 64 50 60;k q 2.6 50 60 53 64 56 60;pink! e 32 60 5 3.4;pink! e 68 60 5 3.4
    weather.suncloud.m|해와 구름|Sun and cloud|m|@weather.sun 34 34 .62 A=T;@weather.cloud 56 60 .82 A=T
    weather.suncloud.c|구름 낀 해|Partly cloudy|c|@weather.sun 34 34 .66 A=yellow;@weather.cloud 56 60 .82 A=w;@weather.face 56 58 .7
    weather.cloud.m|구름|Cloud|m|@weather.cloud 50 46 1 A=T
    weather.cloud.d|흐림|Cloudy|d|@weather.cloud 50 46 1 A=w;@weather.face 50 44 1
    weather.cloudcat.d|고양이 구름|Cat cloud|d|w p 4 18 52 16 18 44 36;w p 4 82 52 84 18 56 36;pink! p 3 24 40 23 26 35 35;pink! p 3 76 40 77 26 65 35;@weather.cloud 50 52 .96 A=w;k q 3 30 56 38 48 46 56;k q 3 54 56 62 48 70 56;k q 2.6 44 62 47 66 50 62;k q 2.6 50 62 53 66 56 62
    weather.dark.m|먹구름|Dark cloud|m|@weather.cloud 66 36 .62 A=T;@weather.cloud 44 54 .84 A=k;T! o 34 54 3.6;T! o 54 54 3.6;T! q 2.8 39 64 44 59 49 64
    weather.dark.c|먹구름 색|Storm cloud|c|@weather.cloud 50 46 1 A=dark;w! o 39 44 4;w! o 61 44 4;w! q 2.8 44 56 50 50 56 56
    weather.rain.m|비|Rain|m|@weather.cloud 50 36 .86 A=T;@weather.drop 28 82 .2 A=T;@weather.drop 50 86 .2 A=T;@weather.drop 72 82 .2 A=T
    weather.rain.c|비 구름|Rainy cloud|c|@weather.cloud 50 36 .86 A=gray;@weather.sadface 50 34 .84;@weather.drop 28 80 .22 A=sky;@weather.drop 50 86 .22 A=blue;@weather.drop 72 80 .22 A=sky
    weather.shower.m|소나기|Shower|m|@weather.cloud 50 32 .8 A=T;T l 5 28 64 20 84;T l 5 44 64 34 90;T l 5 60 64 50 90;T l 5 76 64 68 84
    weather.shower.c|소나기 색|Heavy shower|c|@weather.cloud 50 32 .8 A=dark;blue l 6 28 64 20 84;sky l 6 44 64 34 90;blue l 6 60 64 50 90;sky l 6 76 64 68 84
    weather.snow.m|눈|Snow|m|@weather.flake A=T
    weather.snow.c|눈 구름|Snow cloud|c|@weather.cloud 50 34 .84 A=w;@weather.face 50 32 .8;@weather.flake 26 80 .28 A=sky;@weather.flake 50 84 .28 A=blue;@weather.flake 74 80 .28 A=sky
    weather.sleet.m|진눈깨비|Sleet|m|@weather.cloud 50 34 .84 A=T;@weather.drop 26 82 .2 A=T;@weather.flake 50 80 .3 A=T;@weather.drop 74 82 .2 A=T
    weather.sleet.c|진눈깨비 색|Sleet color|c|@weather.cloud 50 34 .84 A=gray;@weather.drop 26 82 .22 A=blue;@weather.flake 50 80 .3 A=w;@weather.drop 74 82 .22 A=blue
    weather.bolt.m|번개|Lightning|m|@weather.bolt A=T
    weather.bolt.c|천둥 번개|Thunderstorm|c|@weather.cloud 50 34 .84 A=dark;@weather.bolt 50 68 .5 A=yellow
    weather.wind.m|바람|Wind|m|@weather.wind A=T
    weather.wind.c|바람 색|Breeze|c|@weather.wind A=sky
    weather.fog.m|안개|Fog|m|@weather.cloud 50 34 .78 A=T;T l 6 14 66 86 66;T l 6 24 82 76 82
    weather.fog.c|짙은 안개|Thick fog|c|@weather.cloud 50 34 .78 A=gray;w l 7 14 64 86 64;w l 7 24 78 76 78
    weather.rainbow.c|무지개|Rainbow|c|red q 8 12 80 50 -22 88 80;orange q 8 20 80 50 -4 80 80;yellow q 8 28 80 50 14 72 80;green q 8 36 80 50 32 64 80;@weather.cloud 18 78 .3 A=w;@weather.cloud 82 78 .3 A=w
    weather.rainbow.m|무지개 선|Rainbow line|m|T q 9 12 80 50 -22 88 80;T q 9 28 80 50 14 72 80;@weather.cloud 18 78 .3 A=T;@weather.cloud 82 78 .3 A=T
    weather.moon.d|달|Moon|d|butter o 50 50 40;#E6C275! o 34 36 7;#E6C275! o 66 66 9;#E6C275! o 64 30 5;k o 38 54 3.6;k o 58 54 3.6;k q 2.6 43 62 48 67 53 62
    weather.moon.m|달 얼굴|Moon face|m|T o 50 50 40;k o 38 50 4;k o 62 50 4;k q 2.8 44 62 50 68 56 62;k o 66 26 3.5;k o 30 28 2.6
    weather.crescent.m|초승달|Crescent|m|@weather.moon A=T
    weather.crescent.d|초승달 입체|Crescent puffy|d|@weather.moon A=yellow
    weather.night.m|별밤|Starry night|m|@weather.moon 42 54 .7 A=T;T star 72 26 15 6 5;T star 84 62 10 4 5;T star 28 16 8 3 5
    weather.night.c|별이 뜬 밤|Night sky|c|navy o 50 50 42;@weather.moon 42 54 .54 A=butter;yellow star 70 30 12 5 5;yellow star 72 66 8 3 5;w! o 28 24 2;w! o 50 80 2
    weather.umbrella.m|우산|Umbrella|m|@weather.umbrella A=T
    weather.umbrella.c|비 오는 날 우산|Rainy umbrella|c|@weather.umbrella A=rose;@weather.drop 14 72 .16 A=sky;@weather.drop 84 70 .16 A=sky;@weather.drop 28 86 .14 A=sky
    weather.boot.m|장화|Rain boot|m|@weather.boot A=T B=k
    weather.boot.d|노란 장화|Yellow boot|d|@weather.boot A=yellow B=orange;dark! b 28 84 60 6 3
    weather.snowman.d|눈사람|Snowman|d|w o 50 66 24;w o 50 34 19;orange! p 2 50 33 64 37 50 39;k o 43 30 2.8;k o 57 30 2.8;k o 50 58 2.6;k o 50 70 2.6;red b 30 48 40 8 4
    weather.snowman.m|눈사람 선|Snowman line|m|T o 50 66 24;T o 50 34 19;k o 43 30 3;k o 57 30 3;k l 3 44 40 56 40;k o 50 60 3;k o 50 72 3
    weather.hot.c|온도계 더움|Hot thermometer|c|w b 34 10 18 62 9;red o 43 74 15;red! b 39 34 8 36 4;k l 2.4 46 22 52 22;k l 2.4 46 32 52 32;@weather.sun 76 30 .36 A=orange
    weather.cold.c|온도계 추움|Cold thermometer|c|w b 34 10 18 62 9;blue o 43 74 15;blue! b 39 54 8 16 4;k l 2.4 46 22 52 22;k l 2.4 46 32 52 32;@weather.flake 76 30 .36 A=sky
    weather.hot.m|온도계 더움 선|Hot line|m|T b 34 10 18 62 9;T o 43 74 15;k b 40 34 6 40 3;k l 2.4 46 22 50 22;@weather.sun 76 30 .36 A=T
    weather.cold.m|온도계 추움 선|Cold line|m|T b 34 10 18 62 9;T o 43 74 15;k b 40 58 6 16 3;k l 2.4 46 22 50 22;@weather.flake 76 30 .4 A=T
    weather.airgood.c|미세먼지 좋음|Clean air|c|sky o 50 42 32;k q 3 34 42 41 34 48 42;k q 3 52 42 59 34 66 42;k q 2.8 44 52 50 58 56 52;w b 16 70 68 22 11;navy! t 50 81 15 좋음
    weather.airbad.c|미세먼지 나쁨|Bad air|c|gray o 50 42 32;k o 40 38 3.8;k o 60 38 3.8;k q 2.8 44 54 50 48 56 54;dark! o 20 16 3;dark! o 80 16 3;dark! o 12 40 2.4;dark! o 88 42 2.4;dark! o 50 8 2.4;red b 16 70 68 22 11;w! t 50 81 15 나쁨
    weather.airgood.m|공기 좋음|Clean air line|m|T o 50 40 32;k q 3 34 40 41 32 48 40;k q 3 52 40 59 32 66 40;k q 2.8 44 50 50 56 56 50;k! t 50 85 17 좋음
    weather.airbad.m|공기 나쁨|Bad air line|m|T o 50 40 32;k o 40 36 3.8;k o 60 36 3.8;k q 2.8 44 52 50 46 56 52;k! o 12 14 3;k! o 88 14 3;k! o 10 38 2.4;k! o 90 40 2.4;k! t 50 85 17 나쁨
    weather.mask.m|마스크|Mask|m|@weather.mask A=T
    weather.mask.c|마스크 고양이|Masked cat|c|@cat.hwarang;k o 36 50 4.5;k o 64 50 4.5;w b 28 56 44 26 9;k l 2.2 34 66 66 66;k l 2.2 34 73 66 73
    weather.shades.m|선글라스|Sunglasses|m|@weather.shades 50 50 1 A=T
    weather.shades.c|선글라스 색|Dark sunglasses|c|@weather.shades 50 50 1 A=dark;w! l 3.6 20 44 28 44;w! l 3.6 64 44 72 44;@weather.sun 80 16 .22 A=yellow
    weather.fan.m|손풍기|Handy fan|m|@weather.fan A=T B=T C=k
    weather.fan.c|손풍기 색|Mini fan|c|@weather.fan A=rose B=w C=sky
    weather.scarf.m|목도리|Scarf|m|@weather.scarf A=T B=k
    weather.scarf.c|줄무늬 목도리|Striped scarf|c|@weather.scarf A=red B=cream
    weather.mitten.m|장갑|Mitten|m|@weather.mitten A=T B=T
    weather.mitten.d|벙어리장갑|Warm mitten|d|@weather.mitten A=sky B=w;w! heart 48 36 20
    weather.typhoon.m|태풍|Typhoon|m|@weather.typhoon A=T
    weather.typhoon.c|태풍 색|Big typhoon|c|@weather.typhoon A=blue
    weather.drop.m|물방울|Water drop|m|@weather.drop A=T
    weather.drop.d|물방울 입체|Puffy drop|d|@weather.drop A=sky;k o 42 62 3.4;k o 58 62 3.4;k q 2.6 45 70 50 74 55 70
    weather.leafwind.c|낙엽 바람|Windy leaves|c|sky l 6 8 50 62 50;sky q 6 62 50 82 48 76 34;sky l 6 8 68 46 68;@weather.leaf 28 28 .34 -30 A=orange;@weather.leaf 80 72 .34 30 A=red;@weather.leaf 56 84 .24 10 A=butter
    """#

    static let seasonsSource = #"""
    seasons.blossom.m|벚꽃|Cherry blossom|m|@seasons.blossom A=T B=k
    seasons.blossom.c|벚꽃 색|Pink blossom|c|@seasons.blossom A=pink B=rose
    seasons.branch.c|벚꽃 가지|Blossom branch|c|choco l 6 10 88 86 18;@seasons.blossom 30 40 .5 A=pink B=rose;@seasons.blossom 66 66 .5 A=pink B=rose;@seasons.blossom 76 22 .36 A=w B=rose
    seasons.school.c|입학 책가방|School bag|c|k q 4.5 36 18 50 2 64 18;red b 20 16 60 74 16;#C94F4A! b 28 24 44 26 10;w o 50 62 8;yellow! o 50 62 3.6;k o 42 37 2.8;k o 58 37 2.8
    seasons.school.m|입학|School start|m|k q 4.5 36 18 50 2 64 18;T b 20 16 60 74 16;k b 30 26 40 4 2;T b 30 44 40 26 8;k t 50 58 15 입학
    seasons.pinwheel.c|어린이날 바람개비|Children's Day|c|k l 4.5 50 42 50 92;@seasons.pinwheel 50 40 .8 A=sky B=yellow
    seasons.carnation.c|어버이날 카네이션|Carnation|c|leaf l 6 50 56 50 90;leaf e 32 76 13 6 30;leaf e 68 76 13 6 -30;red star 50 34 28 21 14;rose! star 50 34 19 14 10;pink! star 50 34 10 7 8;leaf p 3 40 56 60 56 50 68
    seasons.butterfly.m|나비|Butterfly|m|T e 30 36 20 17 -20;T e 70 36 20 17 20;T e 34 66 14 13 20;T e 66 66 14 13 -20;k b 46 28 8 50 4;k q 2.6 48 30 42 18 36 14;k q 2.6 52 30 58 18 64 14
    seasons.tulip.c|튤립|Tulip|c|leaf l 6 50 56 50 90;leaf e 32 76 8 16 -30;leaf e 68 76 8 16 30;rose s M28 22 L40 34 L50 18 L60 34 L72 22 L72 44 C72 66 28 66 28 44 Z
    seasons.melon.d|수박|Watermelon|d|green e 50 52 40 36;leaf! q 4 28 22 22 52 28 84;leaf! q 4 50 16 50 52 50 90;leaf! q 4 72 22 78 52 72 84
    seasons.melonslice.d|수박 조각|Watermelon slice|d|green s M8 34 L92 34 C92 92 8 92 8 34 Z;w! s M14 34 L86 34 C86 82 14 82 14 34 Z;red! s M18 34 L82 34 C82 76 18 76 18 34 Z;k! e 38 46 2.4 3.4;k! e 62 46 2.4 3.4;k! e 50 58 2.4 3.4
    seasons.melon.m|수박 한입|Melon bite|m|T s M8 34 L92 34 C92 92 8 92 8 34 Z;k e 34 46 3 4;k e 50 56 3 4;k e 66 46 3 4
    seasons.tube.c|튜브|Swim ring|c|red o 50 50 42;w! s M10 42 L24 46 C22 52 22 56 24 58 L10 62 Z;w! s M90 42 L76 46 C78 52 78 56 76 58 L90 62 Z;w! s M42 10 L46 24 L54 24 L58 10 Z;w! s M42 90 L46 76 L54 76 L58 90 Z;sky o 50 50 18
    seasons.parasol.c|해변 파라솔|Beach|c|butter s M8 92 C20 78 80 78 92 92 Z;dark l 4 50 28 58 84;orange s M12 42 C18 4 82 4 88 42 Z;w! s M38 14 C32 22 30 32 30 42 L44 42 C44 32 44 22 46 12 Z;w! s M62 14 C68 22 70 32 70 42 L58 42 C58 32 58 22 56 12 Z
    seasons.bingsu.d|빙수|Shaved ice|d|w s M24 54 C18 18 82 18 76 54 Z;rose! s M30 42 C30 26 58 22 62 34 C66 42 54 42 44 40 C38 40 34 46 30 42 Z;red o 50 22 8;sky b 18 52 64 14 7;sky s M26 66 L74 66 L64 90 L36 90 Z
    seasons.fan.m|선풍기|Electric fan|m|T b 42 62 16 22 4;T b 26 80 48 12 6;T o 50 38 30;k e 50 24 7 11;k e 38 45 7 11 120;k e 62 45 7 11 240;k o 50 38 4
    seasons.handfan.m|부채|Paper fan|m|T s M50 56 L14 30 C24 8 76 8 86 30 Z;k l 2.6 50 56 32 16;k l 2.6 50 56 50 12;k l 2.6 50 56 68 16;T b 45 52 10 38 5
    seasons.icebar.c|아이스바|Ice pop|c|tan b 44 62 12 30 5;sky b 26 8 48 62 20;mint! s M26 44 L74 44 L74 50 C74 62 62 70 50 70 C38 70 26 62 26 50 Z;w! l 4 36 20 36 34;k o 42 40 2.8;k o 58 40 2.8
    seasons.shell.c|조개|Seashell|c|peach s M50 88 C14 66 8 40 18 22 C28 12 72 12 82 22 C92 40 86 66 50 88 Z;orange! l 3 50 84 30 20;orange! l 3 50 84 50 16;orange! l 3 50 84 70 20
    seasons.maple.m|단풍|Maple leaf|m|k l 5 50 66 50 92;@seasons.maple A=T
    seasons.maple.c|붉은 단풍|Red maple|c|choco l 5 50 66 50 92;@seasons.maple A=red
    seasons.ginkgo.c|은행잎|Ginkgo leaf|c|@seasons.ginkgo A=yellow
    seasons.ginkgo.m|은행잎 선|Ginkgo line|m|@seasons.ginkgo A=T
    seasons.acorn.d|도토리|Acorn|d|tan s M26 44 L74 44 C74 72 60 82 50 92 C40 82 26 72 26 44 Z;brown b 18 26 64 22 11;choco b 46 12 8 16 4
    seasons.songpyeon.d|추석 송편|Songpyeon|d|mint s M26 46 C30 14 76 10 92 46 C76 60 42 60 26 46 Z;pink s M8 68 C12 34 72 28 92 68 C72 86 28 86 8 68 Z;k o 40 64 3;k o 60 64 3;k q 2.6 45 70 50 74 55 70
    seasons.fullmoon.d|보름달|Full moon|d|yellow o 50 50 40;#E6B84C! o 30 34 6;#E6B84C! o 70 32 4;#E6B84C! p 3 37 62 36 42 47 53;#E6B84C! p 3 63 62 64 42 53 53;#E6B84C! e 50 66 16 15
    seasons.scarecrow.c|허수아비|Scarecrow|c|brown l 6 50 50 50 92;brown l 6 14 56 86 56;red b 32 46 36 34 8;butter! b 32 74 36 6 0;tan o 50 30 17;k o 44 28 2.6;k o 56 28 2.6;k l 2.4 44 37 56 37;butter s M26 20 L74 20 C70 2 30 2 26 20 Z
    seasons.sweetpotato.d|군고구마|Roasted sweet potato|d|purple e 50 58 42 25 -18;butter! e 56 53 27 14 -18;orange! q 3 40 58 54 50 70 47;gray q 3.5 34 30 28 20 34 10;gray q 3.5 54 24 48 16 54 8
    seasons.chestnut.c|밤|Chestnut|c|brown s M50 12 C32 26 14 44 14 62 C14 80 32 88 50 88 C68 88 86 80 86 62 C86 44 68 26 50 12 Z;tan! e 50 76 28 10;#C78C5F! q 3 34 36 30 48 28 56
    seasons.persimmon.d|감|Persimmon|d|orange e 50 56 38 34;leaf p 4 50 28 30 14 46 22 50 8 54 22 70 14
    seasons.snowman.c|눈사람 고양이|Snowman cat|c|w o 50 68 22;w p 4 30 34 28 12 44 20;w p 4 70 34 72 12 56 20;w o 50 36 21;k o 42 34 3;k o 58 34 3;k q 2.6 45 41 50 45 55 41;red b 30 52 40 8 4;red b 54 56 10 16 3
    seasons.tree.c|크리스마스 트리|Christmas tree|c|@seasons.tree A=leaf B=brown;red! o 42 46 3.6;yellow! o 58 56 3.6;red! o 38 72 3.6;sky! o 58 74 3.6;yellow star 50 14 11 4.5 5
    seasons.tree.m|트리|Tree|m|@seasons.tree A=T B=k;k star 50 14 11 4.5 5;k o 44 50 3;k o 58 62 3;k o 36 72 3
    seasons.sock.c|크리스마스 양말|Christmas sock|c|@seasons.sock A=red B=w;w! heart 48 48 18
    seasons.sock.m|양말|Sock|m|@seasons.sock A=T B=T;k l 3 34 36 62 36
    seasons.cane.c|지팡이 사탕|Candy cane|c|@seasons.cane.fullc 50 50 0.94
    seasons.cane.m|사탕 지팡이|Cane line|m|@seasons.cane.fullm 50 50 0.94
    seasons.santa.c|산타 모자|Santa hat|c|@seasons.santa A=red B=w
    seasons.santa.m|산타 모자 선|Santa hat line|m|@seasons.santa A=T B=T
    seasons.tteokguk.c|떡국|Rice cake soup|c|gray q 3.5 36 28 30 18 36 8;gray q 3.5 62 28 56 18 62 8;sky s M10 48 L90 48 C90 76 70 90 50 90 C30 90 10 76 10 48 Z;cream e 50 48 40 13;w e 34 47 9 5 -15;w e 62 44 9 5 15;w e 54 53 9 5 -10;leaf! b 42 42 10 3 1 30;yellow! b 70 50 8 3 1 -30
    seasons.pouch.c|복주머니|Lucky pouch|c|@seasons.pouch A=rose B=yellow;#C94F4A! t 50 68 24 福
    seasons.pouch.m|복주머니 선|Pouch line|m|@seasons.pouch A=T B=k;k t 50 68 24 福
    seasons.hoppang.d|호빵|Steamed bun|d|w s M10 70 C10 28 90 28 90 70 C90 82 10 82 10 70 Z;k o 40 58 3;k o 60 58 3;k q 2.6 45 66 50 70 55 66;gray! q 3 34 22 28 14 34 8;gray! q 3 66 22 60 14 66 8
    seasons.cake.d|생일 케이크|Birthday cake|d|@seasons.cake A=cream B=rose C=sky D=orange
    seasons.cake.c|케이크 조각|Cake slice|c|yellow p 3 14 44 86 30 86 84 14 84;w s M14 44 L86 30 L86 42 C80 50 74 42 68 42 C62 42 58 54 50 54 C44 54 40 46 34 46 C28 46 20 56 14 50 Z;red o 62 24 9;rose! b 14 62 72 6 0
    seasons.cake.m|케이크|Cake|m|@seasons.cake A=T B=T C=T D=k
    seasons.balloon.c|풍선|Balloon|c|@seasons.balloon A=rose;w! e 40 24 5 9 20
    seasons.balloon.m|풍선 선|Balloon line|m|@seasons.balloon A=T
    seasons.balloons.d|풍선 다발|Balloons|d|k q 2.6 26 54 46 72 50 92;k q 2.6 74 54 54 72 50 92;k q 2.6 50 42 48 66 50 92;sky e 26 36 18 22;yellow e 74 36 18 22;rose e 50 26 18 22
    seasons.cone.c|고깔모자|Party hat|c|@seasons.cone A=sky B=w C=yellow;red! o 44 62 3;orange! o 60 44 3
    seasons.cone.m|고깔|Party cone|m|@seasons.cone A=T B=k C=T
    seasons.firework.c|폭죽|Firework|c|red l 5 50 50 50 12;orange l 5 50 50 83 31;yellow l 5 50 50 83 69;green l 5 50 50 50 88;blue l 5 50 50 17 69;purple l 5 50 50 17 31;yellow! o 50 50 8
    seasons.firework.m|폭죽 선|Firework line|m|T l 6 50 50 50 14;T l 6 50 50 80 26;T l 6 50 50 86 56;T l 6 50 50 70 82;T l 6 50 50 30 82;T l 6 50 50 14 56;T l 6 50 50 20 26;k o 50 50 7;k! o 50 8 3;k! o 86 18 3;k! o 92 62 3;k! o 8 62 3;k! o 14 18 3
    seasons.popper.c|파티 폭죽|Party popper|c|yellow p 3 14 88 34 40 62 66;red! l 4 26 62 44 74;red! l 4 32 50 52 66;rose star 66 26 10 4 5;sky o 82 46 5;mint o 44 20 5;orange b 72 60 12 6 3 30;purple b 60 10 12 6 3 -30
    seasons.gift.d|선물상자|Gift box|d|@seasons.gift A=sky B=rose C=rose
    seasons.gift.c|고양이 선물|Cat gift|c|@seasons.gift A=mint B=yellow C=yellow;k o 30 66 3;k o 70 66 3;k q 2.6 24 76 30 80 36 76
    seasons.gift.m|선물|Gift|m|@seasons.gift A=T B=k C=T
    seasons.pumpkin.c|할로윈 호박|Halloween pumpkin|c|@seasons.pumpkin A=orange B=leaf;k p 2 30 46 44 46 37 34;k p 2 56 46 70 46 63 34;k s M28 60 L38 64 L44 60 L50 66 L56 60 L62 64 L72 60 C70 80 30 80 28 60 Z
    seasons.pumpkin.m|호박|Pumpkin|m|@seasons.pumpkin A=T B=k;k p 2 30 46 44 46 37 34;k p 2 56 46 70 46 63 34;k s M28 60 L38 64 L44 60 L50 66 L56 60 L62 64 L72 60 C70 80 30 80 28 60 Z
    seasons.ghost.m|유령|Ghost|m|@seasons.ghost A=T;k o 38 42 5;k o 62 42 5;k e 50 58 5 6
    seasons.ghost.d|고양이 유령|Cat ghost|d|w p 4 22 28 20 8 40 16;w p 4 78 28 80 8 60 16;@seasons.ghost A=w;k o 38 42 5;k o 62 42 5;k q 2.6 44 52 47 56 50 52;k q 2.6 50 52 53 56 56 52;pink! e 28 52 5 3;pink! e 72 52 5 3
    seasons.witch.c|마녀 모자|Witch hat|c|purple p 4 50 8 70 66 30 66;purple e 50 70 42 12;yellow! b 32 54 36 9 2
    seasons.choco.c|발렌타인 초콜릿|Valentine chocolate|c|choco heart 50 50 84;brown! heart 50 46 58;w! q 3 34 28 28 34 28 42
    seasons.choco.m|초콜릿|Chocolate|m|T b 16 12 68 76 8;k l 3 50 14 50 86;k l 3 18 37 82 37;k l 3 18 62 82 62
    seasons.bouquet.c|졸업 꽃다발|Graduation bouquet|c|leaf e 22 40 8 16 -30;leaf e 78 40 8 16 30;@seasons.blossom 34 26 .42 A=rose B=yellow;@seasons.blossom 66 26 .42 A=sky B=yellow;@seasons.blossom 50 36 .46 A=yellow B=orange;cream p 4 18 46 82 46 58 88 42 88;red o 50 70 6;red e 40 78 7 4 -30;red e 60 78 7 4 30
    seasons.gradcap.m|졸업 모자|Graduation cap|m|T s M26 48 L74 48 L74 70 C60 82 40 82 26 70 Z;T p 3 50 16 94 38 50 60 6 38;k l 3.4 80 44 80 70;k o 80 72 4
    seasons.gradcap.c|졸업 학사모|Graduation hat|c|dark s M26 48 L74 48 L74 70 C60 82 40 82 26 70 Z;dark p 3 50 16 94 38 50 60 6 38;yellow l 3.4 80 44 80 70;yellow o 80 72 4
    seasons.ring.c|결혼 반지|Wedding ring|c|@seasons.ring A=yellow;sky p 3 38 22 46 8 54 8 62 22 50 36;w! l 2.2 44 18 50 12
    seasons.ring.m|반지|Ring|m|@seasons.ring A=T;T p 3 38 22 46 8 54 8 62 22 50 36
    seasons.bow.c|기념일 리본|Anniversary ribbon|c|@seasons.bow A=rose
    seasons.bow.m|리본|Ribbon|m|@seasons.bow A=T
    seasons.sunrise.c|새해 해돋이|New Year sunrise|c|orange star 50 46 38 27 12;red o 50 46 22;sky b 6 58 88 32 10;w! l 3.4 18 70 42 70;w! l 3.4 56 80 82 80
    seasons.sunrise.m|해돋이|Sunrise|m|T star 50 46 38 27 12;T o 50 46 22;T b 6 58 88 32 10;k! l 3.4 18 70 42 70;k! l 3.4 56 80 82 80
    """#
}
