extension StickerCatalog {
    /// 다색 층을 단색으로 바꾼다. 안쪽 장식(`!`)은 검정만 남긴다.
    static func monoLayers(_ source: String) -> String {
        source.split(separator: ";").compactMap { raw -> String? in
            var tokens = raw.split(separator: " ").map(String.init)
            guard let head = tokens.first else { return nil }
            if head.hasPrefix("@") {
                return tokens.map { $0.contains("=") ? String($0.prefix(while: { $0 != "=" })) + "=T" : $0 }.joined(separator: " ")
            }
            if head == "k" || head == "k!" { return String(raw) }
            if head.hasSuffix("!") { return nil }
            tokens[0] = "T"
            return tokens.joined(separator: " ")
        }.joined(separator: ";")
    }

    /// 다색 그림의 단색판 줄을 만든다. id는 원본 id 뒤에 `.m`.
    static func monoVariants(of ids: [String], in source: String) -> String {
        let lines = source.split(separator: "\n").map { $0.split(separator: "|", maxSplits: 4).map(String.init) }
        return ids.compactMap { id -> String? in
            guard let line = lines.first(where: { $0.first == id }), line.count == 5 else { return nil }
            return "\(id).m|\(line[1]) 단색|\(line[2]) mono|m|\(monoLayers(line[4]))"
        }.joined(separator: "\n")
    }

    static let animalsParts = #"""
    eyes|k o 36 50 4.5;k o 64 50 4.5
    petal.notch|A s M50 52 C35 42 32 22 42 11 L50 20 L58 11 C68 22 65 42 50 52 Z
    petal.round|A e 50 28 19 21
    petal.long|A e 50 26 8.5 18
    cloverleaf|A heart 50 28 40
    lav|B l 4 50 92 50 44;A o 50 14 5.5;A o 44 22 5.5;A o 56 22 5.5;A o 44 31 5.5;A o 56 31 5.5;A o 44 40 5.5;A o 56 40 5.5;A o 50 26 5.5;A o 50 36 5.5
    """#

    private static let animalsColor = #"""
    animal.dog|강아지|Dog|d|tan e 50 54 34 32;brown! e 64 48 11 11;w! e 50 68 16 12;brown e 19 44 11 22 10;brown e 81 44 11 22 -10;@eyes;k e 50 62 5.5 4;k q 2.6 44 68 47 72 50 68;k q 2.6 50 68 53 72 56 68;red! s M46 71 C46 80 54 80 54 71 Z
    animal.rabbit|토끼|Rabbit|d|w b 28 8 16 44 8 -6;w b 56 8 16 44 8 6;pink! b 32 14 8 30 4 -6;pink! b 60 14 8 30 4 6;w e 50 62 32 28;@eyes 50 58;pink! e 28 72 6 4;pink! e 72 72 6 4;k e 50 66 3.5 2.6;k q 2.6 44 72 47 75 50 71;k q 2.6 50 71 53 75 56 72
    animal.bear|곰|Bear|d|brown o 22 28 12;brown o 78 28 12;tan! o 22 28 6;tan! o 78 28 6;brown e 50 56 36 33;tan! e 50 68 16 13;@eyes;k e 50 63 5 4;k q 2.6 44 71 47 74 50 70;k q 2.6 50 70 53 74 56 71
    animal.hamster|햄스터|Hamster|d|butter o 24 26 10;butter o 76 26 10;pink! o 24 26 5;pink! o 76 26 5;butter e 50 56 38 34;w! e 50 68 24 19;pink! e 22 62 7 5;pink! e 78 62 7 5;@eyes;pink! e 50 60 3 2.2;k q 2.4 45 66 48 68 50 65;k q 2.4 50 65 52 68 55 66
    animal.chick|병아리|Chick|d|orange e 40 88 7 3.5;orange e 60 88 7 3.5;yellow q 5 50 26 46 16 52 12;yellow e 50 56 32 32;yellow e 20 62 6 12 20;yellow e 80 62 6 12 -20;@eyes;orange p 3 43 56 57 56 50 66;pink! e 28 62 6 4;pink! e 72 62 6 4
    animal.duck|오리|Duck|c|orange e 40 88 8 3.5;orange e 58 88 8 3.5;w e 44 64 30 22;w s M12 52 C8 44 12 38 18 46 Z;w o 64 34 18;orange e 84 38 9 5;k o 68 30 3.6;gray s M26 60 C34 54 50 56 54 66 C46 76 32 74 26 60 Z;pink! e 62 42 5 3.5
    animal.pig|돼지|Pig|d|pink p 4 22 34 18 12 38 22;pink p 4 78 34 82 12 62 22;pink e 50 54 36 32;@eyes 50 46;rose e 50 62 14 10;k o 45 62 2.4;k o 55 62 2.4;rose! e 24 62 6 4;rose! e 76 62 6 4
    animal.fox|여우|Fox|c|orange p 5 10 14 36 34 64 34 90 14 82 62 50 90 18 62;w! s M22 58 C34 56 44 66 50 86 C56 66 66 56 78 58 C72 72 60 84 50 88 C40 84 28 72 22 58 Z;dark! p 2 12 16 22 25 15 32;dark! p 2 88 16 78 25 85 32;@eyes 50 50;k e 50 80 4.5 3.5
    animal.frog|개구리|Frog|d|green o 30 30 14;green o 70 30 14;green e 50 60 40 28;w! o 30 30 9;w! o 70 30 9;k o 30 30 4.5;k o 70 30 4.5;k q 3 28 62 50 80 72 62;pink! e 18 62 6 4;pink! e 82 62 6 4
    animal.penguin|펭귄|Penguin|d|orange e 40 88 8 4;orange e 60 88 8 4;navy e 18 56 7 18 20;navy e 82 56 7 18 -20;navy e 50 52 30 38;w! e 50 62 21 26;w! o 38 38 9;w! o 62 38 9;k o 39 38 3.8;k o 61 38 3.8;orange p 3 43 44 57 44 50 53;pink! e 30 52 5 3;pink! e 70 52 5 3
    animal.fish|물고기|Fish|d|orange p 4 70 50 92 30 92 70;orange e 46 50 32 22;orange p 3 40 30 56 16 58 32;w! b 36 29 10 42 5;w! b 56 31 8 38 4;k o 24 46 3.6;k q 2.4 14 56 18 60 22 56
    animal.butterfly|나비|Butterfly|c|rose e 30 36 21 19 -20;rose e 70 36 21 19 20;lilac e 34 68 15 15;lilac e 66 68 15 15;w! o 28 34 6;w! o 72 34 6;butter! o 34 68 5;butter! o 66 68 5;k e 50 52 4.5 22;k q 2.4 48 32 44 18 36 16;k q 2.4 52 32 56 18 64 16
    animal.bee|벌|Bee|c|sky e 36 26 11 17 -25;sky e 60 24 11 17 25;k p 3 76 52 92 58 76 64;yellow e 48 58 32 24;k! b 44 35 9 46 3;k! b 62 38 8 40 3;k o 26 54 3.2;k q 2.4 22 64 27 68 32 64;k q 2.2 26 38 20 24 12 22
    animal.ladybug|무당벌레|Ladybug|c|k q 2.6 44 20 40 12 32 12;k q 2.6 56 20 60 12 68 12;k o 50 26 14;red o 50 58 32;k l 3 50 28 50 90;k! o 34 46 6;k! o 66 46 6;k! o 30 66 6;k! o 70 66 6;k! o 42 78 4;k! o 58 78 4;w! o 45 22 3;w! o 55 22 3
    animal.snail|달팽이|Snail|c|k l 2.6 18 46 12 32;k l 2.6 26 46 28 32;k o 12 30 3;k o 28 30 3;butter s M8 78 C6 62 10 44 22 44 C32 44 34 58 40 66 L82 72 C92 74 92 84 82 84 L18 84 C12 84 8 82 8 78 Z;orange o 58 48 25;choco! q 3.4 76 52 72 30 54 34;choco! q 3.4 54 34 40 42 50 56;choco! q 3.4 50 56 60 64 64 52;k o 18 54 2.8;k q 2.4 14 66 18 70 24 66
    animal.squirrel|다람쥐|Squirrel|c|brown s M58 84 C92 88 98 40 80 22 C64 8 48 26 60 38 C72 50 56 62 58 84 Z;choco! q 3 72 26 84 44 72 72;tan e 42 68 19 21;cream! e 40 72 11 14;tan p 3 22 26 22 12 34 20;tan p 3 48 26 50 12 38 20;tan o 36 36 17;cream! e 36 44 9 6;k o 29 34 3.2;k o 43 34 3.2;k e 36 41 2.2 1.7;brown o 28 70 8;choco! e 28 65 8 3;tan e 36 88 9 4
    animal.koala|코알라|Koala|d|gray o 21 38 16;gray o 79 38 16;pink! o 21 38 8;pink! o 79 38 8;gray e 50 56 32 30;@eyes 50 46;dark e 50 58 7.5 11;w! e 28 70 3 2;k q 2.4 44 74 50 78 56 74
    animal.panda|판다|Panda|d|k o 22 28 12;k o 78 28 12;w e 50 56 36 33;k! e 33 52 9 11 20;k! e 67 52 9 11 -20;w! o 34 50 3.4;w! o 66 50 3.4;k e 50 63 4.5 3.2;k q 2.6 44 70 47 73 50 69;k q 2.6 50 69 53 73 56 70;pink! e 22 68 5 3;pink! e 78 68 5 3
    animal.lion|사자|Lion|d|orange star 50 52 42 32 12;butter o 28 32 7;butter o 72 32 7;butter o 50 52 27;@eyes 50 44 .8;w! e 50 60 11 8;choco e 50 56 4.5 3.2;k q 2.4 44 63 47 66 50 62;k q 2.4 50 62 53 66 56 63
    animal.tiger|호랑이|Tiger|d|orange o 22 28 11;orange o 78 28 11;w! o 22 28 5;w! o 78 28 5;orange e 50 56 36 32;k! l 3.6 50 26 50 36;k! l 3.4 40 28 42 35;k! l 3.4 60 28 58 35;k! l 3.6 15 50 25 52;k! l 3.6 16 62 26 62;k! l 3.6 85 50 75 52;k! l 3.6 84 62 74 62;w! e 50 70 16 12;@eyes;pink e 50 63 4.5 3.2;k q 2.6 44 71 47 74 50 70;k q 2.6 50 70 53 74 56 71
    animal.sheep|양|Sheep|d|choco e 18 58 10 6 15;choco e 82 58 10 6 -15;w o 30 28 13;w o 50 22 14;w o 70 28 13;w o 20 44 13;w o 80 44 13;w o 26 66 13;w o 74 66 13;w o 50 76 14;w o 50 50 28;cream e 50 56 17 19;k o 42 52 3.6;k o 58 52 3.6;k q 2.4 45 64 50 68 55 64;pink! e 36 60 4 2.6;pink! e 64 60 4 2.6
    animal.cow|소|Cow|d|butter p 3 28 28 22 10 40 22;butter p 3 72 28 78 10 60 22;w e 16 42 10 6 15;w e 84 42 10 6 -15;w e 50 52 34 30;choco! e 33 38 11 11;choco! e 70 56 9 8;@eyes 50 46;pink e 50 70 22 14;k o 43 70 2.8;k o 57 70 2.8
    animal.horse|말|Horse|c|tan p 3 34 28 30 8 46 20;tan p 3 66 28 70 8 54 20;tan b 30 16 40 74 20;choco s M42 12 C38 22 40 34 50 40 C60 34 62 22 58 12 C54 8 46 8 42 12 Z;cream e 50 74 19 15;k o 37 48 3.8;k o 63 48 3.8;k o 44 74 2.4;k o 56 74 2.4;k q 2.4 42 82 50 86 58 82
    animal.owl|부엉이|Owl|d|orange e 40 90 7 3;orange e 60 90 7 3;brown p 4 20 30 18 8 42 22;brown p 4 80 30 82 8 58 22;brown e 50 54 34 36;tan! e 50 70 20 18;w o 35 42 13;w o 65 42 13;k o 36 42 5.5;k o 64 42 5.5;orange p 3 44 50 56 50 50 60;choco! q 2.4 42 70 46 74 50 70;choco! q 2.4 50 70 54 74 58 70;choco! q 2.4 46 78 50 82 54 78
    animal.parrot|앵무새|Parrot|c|blue p 4 32 72 42 72 34 92 24 92;brown b 14 72 72 8 4;red e 46 54 19 26 15;yellow s M38 44 C26 50 22 64 30 74 C40 72 46 58 38 44 Z;blue s M30 74 C32 64 34 60 40 58 C42 66 38 74 30 74 Z;red o 54 28 18;w! e 62 28 8 9;dark s M66 18 C82 18 88 36 76 46 C74 38 70 36 62 36 Z;k o 60 26 3
    animal.turtle|거북이|Turtle|c|green o 82 56 11;green e 26 78 10 7;green e 68 78 10 7;green p 3 14 66 4 72 14 74;leaf s M12 72 C12 32 74 26 76 72 Z;#3F8A50! p 3 34 46 54 46 60 60 44 70 28 60;#3F8A50! l 2.4 34 46 26 36;#3F8A50! l 2.4 54 46 60 36;k o 86 53 2.8;k q 2.4 84 62 88 64 91 60
    animal.whale|고래|Whale|c|sky q 3 40 22 34 12 26 12;sky q 3 40 22 46 12 54 12;blue e 80 22 9 4.5 -25;blue e 90 26 6 4 25;blue s M10 52 C10 28 46 24 64 42 C72 48 80 44 84 26 C90 28 92 36 88 46 C84 62 70 78 42 78 C22 78 10 68 10 52 Z;w! s M12 58 C24 62 50 62 70 68 C60 76 50 78 42 78 C24 78 14 70 12 58 Z;k o 26 46 3.4;pink! e 34 54 5 3;k l 2 40 68 40 74;k l 2 48 68 48 75;k l 2 56 69 56 74
    animal.octopus|문어|Octopus|d|rose q 9 26 58 8 70 14 86;rose q 9 38 62 26 78 32 90;rose q 9 62 62 74 78 68 90;rose q 9 74 58 92 70 86 86;rose q 9 50 62 50 78 50 90;rose e 50 38 30 30;@eyes 50 42;k e 50 56 4 3.4;#D66F8B! o 36 22 4;#D66F8B! o 60 18 3;w! o 26 42 2.6
    animal.elephant|코끼리|Elephant|d|gray e 18 46 15 22;gray e 82 46 15 22;pink! e 18 46 8 14;pink! e 82 46 8 14;gray e 50 46 28 30;gray q 12 50 62 50 78 62 86;k o 38 44 4;k o 62 44 4;pink! e 30 54 4.5 3;pink! e 70 54 4.5 3
    animal.giraffe|기린|Giraffe|c|butter o 30 14 4;butter o 56 14 4;butter l 3 32 18 34 30;butter l 3 54 18 52 30;butter e 22 36 8 4 -15;butter e 66 36 8 4 15;butter b 34 44 22 50 8;brown! o 40 66 4;brown! o 50 78 4;brown! o 42 86 3;butter e 44 40 21 16;cream e 44 48 15 8;brown! o 56 30 3;k o 36 37 3;k o 52 37 3;k o 40 48 1.8;k o 48 48 1.8
    animal.monkey|원숭이|Monkey|d|brown o 16 50 11;brown o 84 50 11;peach! o 16 50 6;peach! o 84 50 6;brown e 50 52 32 34;peach! e 39 44 11 12;peach! e 61 44 11 12;peach! e 50 62 20 15;@eyes 50 46;k o 46 58 1.8;k o 54 58 1.8;k q 2.6 38 66 50 74 62 66
    animal.hedgehog|고슴도치|Hedgehog|c|choco star 56 54 38 26 14;tan e 34 66 24 18;k o 28 62 3.2;k o 14 68 3.4;pink! e 34 72 5 3;k q 2.4 18 76 22 79 26 76;tan e 40 86 7 3.5;tan e 60 88 7 3.5
    animal.raccoon|너구리|Raccoon|d|gray o 24 28 11;gray o 76 28 11;gray e 50 56 36 32;w! e 50 42 18 10;dark! e 33 54 12 9 15;dark! e 67 54 12 9 -15;w! o 34 53 4;w! o 66 53 4;k o 34 53 2.6;k o 66 53 2.6;w! e 50 70 15 11;k e 50 65 4.5 3.2;k q 2.4 45 73 50 76 55 73
    animal.dolphin|돌고래|Dolphin|c|blue p 3 40 32 36 12 56 28;blue p 3 18 62 8 76 30 72;blue p 4 68 74 92 68 88 90 74 84;blue s M6 50 L18 44 C30 26 58 24 72 50 C76 60 76 68 72 76 C56 70 36 66 22 58 L10 56 C6 54 6 52 6 50 Z;w! s M20 54 C34 56 54 62 70 72 C50 68 34 62 20 54 Z;k o 24 44 2.8
    animal.jellyfish|해파리|Jellyfish|c|lilac q 5 28 54 22 68 30 84;lilac q 5 42 56 36 72 44 90;lilac q 5 58 56 64 72 56 90;lilac q 5 72 54 78 68 70 84;lilac s M14 56 C14 8 86 8 86 56 C74 62 62 54 50 60 C38 54 26 62 14 56 Z;@eyes 50 36 .9;pink! e 28 44 5 3;pink! e 72 44 5 3
    animal.crab|게|Crab|c|red l 5 18 62 8 72;red l 5 24 72 16 84;red l 5 82 62 92 72;red l 5 76 72 84 84;red p 3 26 40 12 40 8 18 18 28 24 16;red p 3 74 40 88 40 92 18 82 28 76 16;red e 50 58 30 22;k l 2.4 40 38 40 26;k l 2.4 60 38 60 26;k o 40 24 4;k o 60 24 4;k q 2.6 42 62 50 68 58 62
    animal.seal|물범|Seal|c|gray e 24 82 14 6 20;gray e 76 82 14 6 -20;gray e 50 56 30 34;w! e 50 66 18 18;@eyes 50 38 .9;k e 50 50 4.5 3.2;k l 1.8 36 50 24 48;k l 1.8 36 54 24 56;k l 1.8 64 50 76 48;k l 1.8 64 54 76 56;pink! e 30 50 4 2.6;pink! e 70 50 4 2.6
    """#

    private static let animalsMono = #"""
    animal.pawprint|강아지 발자국|Dog paw|m|T e 50 64 22 17;T o 24 42 9;T o 42 26 9;T o 58 26 9;T o 76 42 9
    animal.pawtrail|발자국 길|Paw trail|m|@paw 28 76 .5 -20 A=T;@paw 58 58 .5 15 A=T;@paw 36 30 .45 -15 A=T;@paw 72 20 .4 15 A=T
    animal.birdprint|새 발자국|Bird print|m|T l 5 50 86 50 40;T l 5 50 44 28 16;T l 5 50 44 50 10;T l 5 50 44 72 16
    animal.bone|뼈다귀|Bone|m|T o 22 30 12;T o 34 18 12;T o 66 82 12;T o 78 70 12;T l 14 30 26 70 74
    """#

    static let animalsSource = [
        animalsColor,
        animalsMono,
        monoVariants(of: ["animal.dog", "animal.rabbit", "animal.bear", "animal.pig", "animal.fox", "animal.frog", "animal.elephant", "animal.fish", "animal.butterfly", "animal.whale", "animal.turtle", "animal.owl", "animal.panda", "animal.chick"], in: animalsColor)
    ].joined(separator: "\n")

    private static let plantsColor = #"""
    plant.sakura|벚꽃|Cherry blossom|c|@petal.notch 50 50 1 0.0 A=pink;@petal.notch 50 50 1 72.0 A=pink;@petal.notch 50 50 1 144.0 A=pink;@petal.notch 50 50 1 216.0 A=pink;@petal.notch 50 50 1 288.0 A=pink;rose! o 50 50 9;#D66F8B! l 2 50 50 50 34;#D66F8B! l 2 50 50 66 44;#D66F8B! l 2 50 50 34 44
    plant.tulip|튤립|Tulip|c|leaf l 5 50 58 50 88;leaf s M50 90 C30 86 18 68 24 52 C38 60 46 74 50 90 Z;leaf s M50 90 C70 86 82 68 76 52 C62 60 54 74 50 90 Z;red s M26 14 L38 28 L50 10 L62 28 L74 14 C80 40 68 58 50 58 C32 58 20 40 26 14 Z
    plant.sunflower|해바라기|Sunflower|d|yellow star 50 50 42 28 14;brown o 50 50 20;choco! o 44 44 2.2;choco! o 56 44 2.2;choco! o 50 54 2.2;choco! o 40 56 2.2;choco! o 60 56 2.2
    plant.rose|장미|Rose|c|leaf l 5 50 66 50 90;leaf e 32 78 13 6 -25;leaf e 68 78 13 6 25;red e 50 40 30 28;k q 2.4 30 34 50 16 68 32;k q 2.4 38 40 50 28 60 38;k q 2.4 44 44 50 38 56 44;k q 2.4 26 48 38 62 50 62;k q 2.4 74 48 66 60 54 62
    plant.daisy|데이지|Daisy|c|@petal.long 50 50 1 0.0 A=w;@petal.long 50 50 1 30.0 A=w;@petal.long 50 50 1 60.0 A=w;@petal.long 50 50 1 90.0 A=w;@petal.long 50 50 1 120.0 A=w;@petal.long 50 50 1 150.0 A=w;@petal.long 50 50 1 180.0 A=w;@petal.long 50 50 1 210.0 A=w;@petal.long 50 50 1 240.0 A=w;@petal.long 50 50 1 270.0 A=w;@petal.long 50 50 1 300.0 A=w;@petal.long 50 50 1 330.0 A=w;yellow o 50 50 13
    plant.carnation|카네이션|Carnation|c|leaf l 5 50 66 50 90;leaf e 34 80 12 5 -25;leaf e 66 80 12 5 25;rose p 3 18 40 14 22 28 26 32 12 44 22 50 8 56 22 68 12 72 26 86 22 82 40 66 58 34 58;#D66F8B! q 2.6 28 36 50 28 72 36;#D66F8B! q 2.6 34 46 50 38 66 46;green p 3 38 56 62 56 56 72 44 72
    plant.lavender|라벤더|Lavender|c|@lav 28 52 .84 -16 A=purple B=leaf;@lav 72 52 .84 16 A=purple B=leaf;@lav 50 50 1 0 A=purple B=leaf
    plant.mugunghwa|무궁화|Rose of Sharon|c|@petal.round 50 50 1 0.0 A=rose;@petal.round 50 50 1 72.0 A=rose;@petal.round 50 50 1 144.0 A=rose;@petal.round 50 50 1 216.0 A=rose;@petal.round 50 50 1 288.0 A=rose;red! o 50 50 15;yellow l 4 50 50 60 36
    plant.bouquet|꽃다발|Bouquet|c|leaf e 22 36 12 6 -40;leaf e 78 36 12 6 40;@flowerhead 32 28 .4 A=rose B=yellow;@flowerhead 68 28 .4 A=lilac B=yellow;@flowerhead 50 20 .42 A=w B=orange;@flowerhead 50 44 .36 A=peach B=yellow;sky p 4 24 46 76 46 56 92 44 92;pink p 3 50 64 36 56 36 74;pink p 3 50 64 64 56 64 74;red o 50 64 4
    plant.pot|화분|Flower pot|c|leaf l 5 50 54 50 30;leaf e 34 42 13 6 25;leaf e 66 42 13 6 -25;@flowerhead 50 22 .36 A=rose B=yellow;brown b 24 54 52 10 3;brown p 5 28 62 72 62 66 92 34 92
    plant.catpot|고양이 화분|Cat planter|d|green s M50 42 C40 34 34 20 36 10 C46 16 50 28 50 42 Z;green s M50 42 C60 34 66 20 64 10 C54 16 50 28 50 42 Z;green s M50 42 C50 28 48 16 50 8 C54 16 54 28 50 42 Z;w p 4 26 52 24 34 42 44;w p 4 74 52 76 34 58 44;w b 22 42 56 46 20;@face.smile 50 62 .8
    plant.cactus|선인장|Cactus|d|green b 14 34 14 32 7;green b 72 26 14 32 7;green b 18 54 24 12 6;green b 58 46 24 12 6;green b 36 14 28 66 14;rose o 50 12 5;orange b 26 76 48 16 4;k o 44 42 3;k o 56 42 3;k q 2.4 46 50 50 54 54 50
    plant.succulent|다육이|Succulent|d|mint star 50 40 36 20 8;green star 50 40 22 12 8 22;leaf o 50 40 6;rose p 4 24 58 76 58 68 92 32 92;#C4607F! l 3 28 66 72 66
    plant.monstera|몬스테라|Monstera|c|leaf s M50 10 C68 8 86 22 88 40 L66 46 L90 52 C88 62 84 70 76 76 L60 60 L66 82 C60 88 54 90 50 92 C46 90 40 88 34 82 L40 60 L24 76 C16 70 12 62 10 52 L34 46 L12 40 C14 22 32 8 50 10 Z;k l 2.6 50 16 50 86
    plant.clover|네잎클로버|Four-leaf clover|c|leaf q 4 50 50 56 74 70 90;@cloverleaf 50 50 1 0.0 A=green;@cloverleaf 50 50 1 90.0 A=green;@cloverleaf 50 50 1 180.0 A=green;@cloverleaf 50 50 1 270.0 A=green
    plant.maple|단풍잎|Maple leaf|c|red p 3 50 8 57 26 68 20 66 40 86 34 80 50 90 56 66 68 68 78 53 72 53 92 47 92 47 72 32 78 34 68 10 56 20 50 14 34 34 40 32 20 43 26;k l 2.4 50 26 50 72
    plant.maple2|주황 단풍|Orange maple|d|orange p 3 50 8 57 26 68 20 66 40 86 34 80 50 90 56 66 68 68 78 53 72 53 92 47 92 47 72 32 78 34 68 10 56 20 50 14 34 34 40 32 20 43 26
    plant.ginkgo|은행잎|Ginkgo leaf|c|yellow l 5 50 58 54 90;yellow s M50 62 C38 60 14 48 10 28 C24 12 40 12 48 26 L50 36 L52 26 C60 12 76 12 90 28 C86 48 62 60 50 62 Z;k l 2 50 58 34 28;k l 2 50 58 66 28
    plant.acorn|도토리|Acorn|d|tan s M24 40 C24 66 40 84 50 90 C60 84 76 66 76 40 Z;choco b 42 8 16 16 4 12;brown b 18 22 64 24 12;k o 40 58 3;k o 60 58 3;k q 2.4 46 66 50 70 54 66
    plant.mushroom|버섯|Mushroom|d|cream b 34 50 32 40 13;red s M10 56 C10 14 90 14 90 56 C90 64 10 64 10 56 Z;w! o 30 38 7;w! o 58 28 8;w! o 74 46 5;k o 42 72 3;k o 58 72 3
    plant.tree|나무|Tree|c|brown b 42 58 16 34 3;green o 28 48 18;green o 72 48 18;green o 50 30 22;green o 50 54 20;red! o 34 42 3.5;red! o 62 30 3.5;red! o 68 52 3.5
    plant.pine|소나무|Pine tree|c|brown b 43 74 14 18 3;leaf p 4 50 44 86 80 14 80;leaf p 4 50 26 78 60 22 60;leaf p 4 50 8 70 40 30 40;butter! star 50 12 6 2.6 5
    plant.sprout|새싹|Sprout|c|choco e 50 84 28 8;green l 5 50 82 50 50;green s M50 54 C30 54 14 42 14 22 C34 22 50 34 50 54 Z;green s M50 46 C54 28 68 18 86 18 C86 36 70 48 50 46 Z
    plant.grass|풀|Grass|c|leaf s M14 88 C14 66 12 50 8 38 C22 50 30 68 32 88 Z;green s M30 88 C32 62 40 36 44 18 C54 38 56 64 58 88 Z;leaf s M54 88 C56 68 64 50 74 34 C76 54 74 72 72 88 Z;green s M70 88 C72 74 80 62 92 54 C90 68 90 78 88 88 Z
    plant.dandelion|민들레|Dandelion|c|leaf l 4 50 50 50 90;leaf s M50 88 C36 86 18 76 12 60 L26 66 L24 54 C38 62 46 74 50 88 Z;leaf s M50 88 C64 86 82 76 88 60 L74 66 L76 54 C62 62 54 74 50 88 Z;yellow star 50 30 24 16 16;orange! o 50 30 7
    plant.cosmos|코스모스|Cosmos|c|@petal.long 50 50 1 0.0 A=lilac;@petal.long 50 50 1 45.0 A=lilac;@petal.long 50 50 1 90.0 A=lilac;@petal.long 50 50 1 135.0 A=lilac;@petal.long 50 50 1 180.0 A=lilac;@petal.long 50 50 1 225.0 A=lilac;@petal.long 50 50 1 270.0 A=lilac;@petal.long 50 50 1 315.0 A=lilac;yellow o 50 50 10
    plant.camellia|동백꽃|Camellia|d|@petal.round 50 50 1 0.0 A=red;@petal.round 50 50 1 72.0 A=red;@petal.round 50 50 1 144.0 A=red;@petal.round 50 50 1 216.0 A=red;@petal.round 50 50 1 288.0 A=red;yellow o 50 50 13;orange! o 50 50 5
    plant.hydrangea|수국|Hydrangea|c|leaf e 22 74 16 8 -30;leaf e 78 74 16 8 30;sky o 34 34 12;lilac o 50 26 12;sky o 66 34 12;lilac o 28 52 12;sky o 50 46 12;lilac o 72 52 12;sky o 40 66 12;lilac o 60 66 12
    plant.morning|나팔꽃|Morning glory|c|green q 4 56 66 84 72 78 90;leaf e 28 80 14 7 -25;blue s M50 72 C24 66 10 44 14 18 C34 8 66 8 86 18 C90 44 76 66 50 72 Z;sky! s M50 66 C42 52 34 40 30 22 C42 18 58 18 70 22 C66 40 58 52 50 66 Z;w! o 50 30 5
    plant.palm|야자수|Palm tree|c|brown s M46 40 C50 60 48 76 42 90 L58 90 C62 76 62 56 54 40 Z;leaf s M50 36 C36 16 18 18 8 34 C24 30 36 32 50 36 Z;leaf s M50 36 C64 16 82 18 92 34 C76 30 64 32 50 36 Z;green s M50 38 C34 34 20 44 18 60 C28 48 38 42 50 38 Z;green s M50 38 C66 34 80 44 82 60 C72 48 62 42 50 38 Z;orange o 44 42 5;orange o 56 42 5
    plant.bamboo|대나무|Bamboo|c|green b 28 8 14 84 4;leaf b 54 18 14 74 4;#3F8A50! l 3 28 36 42 36;#3F8A50! l 3 28 64 42 64;#2F7040! l 3 54 44 68 44;#2F7040! l 3 54 70 68 70;leaf e 78 22 12 5 -25;leaf e 20 52 10 4 25
    plant.branch|벚꽃 가지|Blossom branch|c|choco q 5 10 88 40 62 88 18;@flowerhead 34 58 .36 A=pink B=rose;@flowerhead 62 38 .38 A=pink B=rose;@flowerhead 74 66 .3 A=pink B=rose;@flowerhead 26 26 .28 A=pink B=rose
    plant.vase|꽃병|Flower vase|c|leaf l 4 50 50 34 24;leaf l 4 50 50 66 24;leaf l 4 50 50 50 18;@flowerhead 32 22 .3 A=rose B=yellow;@flowerhead 68 22 .3 A=butter B=orange;@flowerhead 50 16 .3 A=lilac B=yellow;sky s M40 46 L60 46 C60 56 72 62 72 76 C72 88 60 92 50 92 C40 92 28 88 28 76 C28 62 40 56 40 46 Z;w! q 3 36 72 50 78 64 72
    plant.can|물뿌리개|Watering can|c|sky q 5 60 40 84 34 74 62;sky l 7 28 66 12 40;sky p 3 4 40 18 32 20 46;sky b 26 42 48 44 8;@pawflat 50 66 .34 A=w
    """#

    private static let plantsMono = #"""
    plant.leaf|나뭇잎 한 장|Single leaf|m|T s M14 86 C8 40 40 14 86 14 C88 60 60 92 14 86 Z;k l 2.6 14 86 62 38;k l 2.2 34 66 34 46;k l 2.2 46 54 46 34;k l 2.2 34 66 54 66;k l 2.2 46 54 66 54
    plant.leaves|잎 두 장|Two leaves|m|T l 4 50 90 50 56;T s M50 58 C24 58 8 42 10 18 C36 18 50 34 50 58 Z;T s M50 58 C76 58 92 42 90 18 C64 18 50 34 50 58 Z;k l 2.4 50 56 26 30;k l 2.4 50 56 74 30
    plant.m.monstera|몬스테라 단색|Monstera mono|m|T s M50 10 C68 8 86 22 88 40 L66 46 L90 52 C88 62 84 70 76 76 L60 60 L66 82 C60 88 54 90 50 92 C46 90 40 88 34 82 L40 60 L24 76 C16 70 12 62 10 52 L34 46 L12 40 C14 22 32 8 50 10 Z;k l 2.6 50 16 50 86
    plant.m.clover4|네잎클로버 단색|Four-leaf mono|m|T q 4 50 50 56 74 70 90;@cloverleaf 50 50 1 0.0 A=T;@cloverleaf 50 50 1 90.0 A=T;@cloverleaf 50 50 1 180.0 A=T;@cloverleaf 50 50 1 270.0 A=T
    plant.m.clover3|세잎클로버|Three-leaf clover|m|T q 4 50 46 54 72 66 90;@cloverleaf 50 46 1 0 A=T;@cloverleaf 50 46 1 120 A=T;@cloverleaf 50 46 1 240 A=T
    plant.m.petals|꽃잎 날림|Falling petals|m|@petal.notch 30 28 .6 -30 A=T;@petal.notch 70 44 .5 40 A=T;@petal.notch 36 72 .48 110 A=T;@petal.notch 76 80 .32 200 A=T
    plant.m.fern|고사리|Fern|m|T q 4 26 90 52 60 62 14;T e 44 74 12 5 30;T e 62 72 12 5 -30;T e 48 54 10 4.5 25;T e 68 54 10 4.5 -25;T e 52 36 8 4 20;T e 70 36 8 4 -25
    plant.m.vine|덩굴|Vine|m|T q 4 10 84 50 88 88 14;T heart 26 66 20;T heart 54 82 20;T heart 56 50 20;T heart 80 44 18;T heart 72 16 18
    plant.m.dandelion|민들레 홀씨|Dandelion seeds|m|T l 4 50 58 50 90;T l 3 50 40 50 14;T l 3 50 40 72 18;T l 3 50 40 80 40;T l 3 50 40 72 62;T l 3 50 40 28 18;T l 3 50 40 20 40;T l 3 50 40 28 62;T o 50 12 5;T o 74 16 5;T o 82 40 5;T o 74 64 5;T o 26 16 5;T o 18 40 5;T o 26 64 5;T o 50 40 7
    plant.m.potsprout|새싹 화분|Sprout pot|m|T l 5 50 58 50 36;T s M50 40 C36 40 24 32 22 18 C38 18 50 26 50 40 Z;T s M50 36 C56 26 66 20 78 20 C78 32 66 38 50 36 Z;T b 24 56 52 10 3;T p 5 28 64 72 64 66 92 34 92;k o 42 76 3;k o 58 76 3;k q 2.4 46 82 50 85 54 82
    """#

    static let plantsSource = [
        plantsColor,
        plantsMono,
        monoVariants(of: ["plant.sakura", "plant.tulip", "plant.rose", "plant.daisy", "plant.sunflower", "plant.lavender", "plant.cactus", "plant.maple", "plant.ginkgo", "plant.acorn", "plant.mushroom", "plant.tree", "plant.pine", "plant.sprout", "plant.grass", "plant.mugunghwa", "plant.carnation"], in: plantsColor)
    ].joined(separator: "\n")
}
