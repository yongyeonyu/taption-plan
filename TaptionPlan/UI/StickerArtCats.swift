extension StickerCatalog {
    static let catsParts = #"""
    amber.two|#F2A32C! o 36 54 7.5;#F2A32C! o 64 54 7.5
    amber.left|#F2A32C! o 36 54 7.5
    amber.angry|#F2A32C! o 37 57 7;#F2A32C! o 63 57 7
    catface.yum|k q 3 29 56 36 47 43 56;k q 3 57 56 64 47 71 56;k q 2.6 44 64 47 68 50 64;k q 2.6 50 64 53 68 56 64;red! s M46 68 C46 78 54 78 54 68 Z
    catface.shy|k o 36 56 4.5;k o 64 56 4.5;rose! e 26 66 8 5;rose! e 74 66 8 5;k q 2.6 45 66 50 70 55 66;k l 2.2 22 64 25 68;k l 2.2 29 64 32 68;k l 2.2 68 64 71 68;k l 2.2 75 64 78 68
    catface.cool|k b 23 44 25 16 6;k b 52 44 25 16 6;k l 3.4 46 50 54 50;w! l 2.6 30 49 35 49;w! l 2.6 59 49 64 49;k q 2.8 42 68 52 72 60 65
    catface.star|yellow star 36 54 11 4.5 4;yellow star 64 54 11 4.5 4;k q 2.6 44 66 47 70 50 66;k q 2.6 50 66 53 70 56 66
    catface.tongue|k l 3 30 50 42 56;k l 3 30 62 42 56;k o 64 54 4.5;k q 2.6 42 66 50 70 58 66;red! s M46 68 C44 82 56 82 54 68 Z
    catface.dizzy|k l 3 30 48 42 60;k l 3 42 48 30 60;k l 3 58 48 70 60;k l 3 70 48 58 60;k q 2.6 42 70 46 66 50 70;k q 2.6 50 70 54 74 58 70
    catglasses|k q 2.6 25 54 36 34 47 54;k q 2.6 25 54 36 74 47 54;k q 2.6 53 54 64 34 75 54;k q 2.6 53 54 64 74 75 54;k l 2.6 47 52 53 52
    flowerhead|A e 50 27 13 17;A e 71.9 42.9 13 17 72;A e 63.5 68.6 13 17 144;A e 36.5 68.6 13 17 216;A e 28.1 42.9 13 17 288;B o 50 50 12
    pawflat|A! e 50 62 15 12;A! o 28 44 7;A! o 42 32 7;A! o 58 32 7;A! o 72 44 7
    """#

    private struct CatCoat {
        let id: String, ko: String, en: String
        let coat: String, tail: String, sock: String
        var part: String { "cat.\(id)" }
    }

    private static let catCoats = [
        CatCoat(id: "hwarang", ko: "화랑이", en: "Hwarang", coat: "w", tail: "w", sock: "w"),
        CatCoat(id: "chunhyang", ko: "춘향이", en: "Chunhyang", coat: "w", tail: "orange", sock: "w"),
        CatCoat(id: "yunbok", ko: "윤복이", en: "Yunbok", coat: "tan", tail: "tan", sock: "w")
    ]

    /// 춘향이는 호박색 눈이라 검은 눈동자 밑에 홍채를 깐다.
    private static func catHead(_ coat: CatCoat?, expression: String, at place: String) -> String {
        guard let coat else {
            let safe = ["wow": "smile", "wink": "happy", "love": "smile"][expression] ?? expression
            return "@catbase \(place) A=T B=T;@face.\(safe) \(place)"
        }
        var layers = ["@\(coat.part) \(place)"]
        if coat.id == "chunhyang" {
            switch expression {
            case "smile", "cry", "wow": layers.append("@amber.two \(place)")
            case "wink": layers.append("@amber.left \(place)")
            case "angry": layers.append("@amber.angry \(place)")
            default: break
            }
        }
        layers.append("@\(expression.contains(".") ? expression : "face.\(expression)") \(place)")
        return layers.joined(separator: ";")
    }

    /// 자세 문구: `%A` 털, `%T` 꼬리, `%C` 양말, `H 표정 x y 배율 [각도]` 머리, `1:` 춘향이 무늬, `2:` 윤복이 무늬.
    private static func catPose(_ pose: String, coat: CatCoat?) -> String {
        pose.split(separator: ";").compactMap { raw -> String? in
            var layer = String(raw)
            if layer.hasPrefix("1:") || layer.hasPrefix("2:") {
                let owner = layer.hasPrefix("1:") ? "chunhyang" : "yunbok"
                guard coat?.id == owner else { return nil }
                layer = String(layer.dropFirst(2))
            }
            if layer.hasPrefix("H ") {
                let tokens = layer.split(separator: " ").map(String.init)
                return catHead(coat, expression: tokens[1], at: tokens[2...].joined(separator: " "))
            }
            return layer
                .replacingOccurrences(of: "%A", with: coat?.coat ?? "T")
                .replacingOccurrences(of: "%T", with: coat?.tail ?? "T")
                .replacingOccurrences(of: "%C", with: coat?.sock ?? "T")
        }.joined(separator: ";")
    }

    private static let catSeat = "%T q 8 67 84 90 84 80 60;2:brown! l 3 77 66 85 66;2:brown! l 3 78 76 85 80;%A e 50 73 20 19;1:orange! e 39 70 7 8;1:choco! e 62 78 6 7;2:w! e 50 72 11 14;2:brown! l 3 33 70 38 71;2:brown! l 3 33 79 38 79;2:brown! l 3 67 70 62 71;2:brown! l 3 67 79 62 79"
    private static let catLegs = "%C b 39 74 9 18 4.5;%C b 52 74 9 18 4.5"

    private static let catPoses: [(id: String, ko: String, en: String, art: String)] = [
        ("sit", "앉기", "sitting", "\(catSeat);\(catLegs);H smile 50 34 .6"),
        ("nap", "누워 자기", "napping", "%T q 8 80 82 92 80 86 62;%A e 56 68 30 20;1:orange! e 50 62 9 7;1:choco! e 72 70 8 8;2:brown! l 3 52 50 52 58;2:brown! l 3 62 49 62 57;2:brown! l 3 72 52 71 60;%C e 28 84 11 5;H sleep 30 60 .56 -8;navy t 62 30 18 Z;navy t 76 18 13 Z"),
        ("stretch", "기지개", "stretching", "%T q 8 82 46 94 30 84 14;2:brown! l 3 84 24 92 26;%A s M26 78 C40 66 56 38 76 38 C90 38 92 56 84 64 C72 74 52 84 36 84 Z;1:orange! e 70 50 9 8;1:choco! e 55 68 7 6;2:brown! l 3 58 52 64 58;2:brown! l 3 68 44 74 50;%C b 74 56 10 34 5;%C b 10 80 34 10 5;H happy 28 60 .56"),
        ("loaf", "식빵 자세", "loafing", "%A b 16 46 68 44 22;1:orange! e 28 68 8 9;1:choco! e 72 72 8 9;2:w! e 50 78 14 10;2:brown! l 3 20 66 27 67;2:brown! l 3 20 76 27 76;2:brown! l 3 80 66 73 67;2:brown! l 3 80 76 73 76;%C e 40 87 8 4.5;%C e 60 87 8 4.5;H smile 50 36 .6"),
        ("coffee", "커피 마시기", "coffee", "\(catSeat);gray q 2.5 74 44 80 38 74 30;gray q 2.5 84 46 90 40 84 32;sky q 4 62 67 73 73 62 79;sky b 38 62 24 22 5;choco! e 50 65 9 2.5;rose! heart 50 75 9;%C e 37 73 6 5;%C e 63 73 6 5;H smile 50 30 .58"),
        ("book", "책 읽기", "reading", "\(catSeat);blue b 22 66 56 22 4;cream s M50 66 C42 60 30 60 25 63 L25 84 C30 81 42 81 50 86 Z;cream s M50 66 C58 60 70 60 75 63 L75 84 C70 81 58 81 50 86 Z;gray! l 2 31 69 44 71;gray! l 2 31 75 44 77;gray! l 2 56 71 69 69;gray! l 2 56 77 69 75;%C e 22 74 6 6;%C e 78 74 6 6;H smile 50 32 .6"),
        ("study", "공부", "studying", "%A e 50 64 20 16;H smile 50 32 .6;@catglasses 50 32 .6;brown b 8 72 84 18 5;red b 11 62 18 5 2;blue b 13 56 15 6 2;w b 34 64 38 11 3;gray! l 2 40 68 62 68;gray! l 2 40 71 56 71;yellow l 5 80 44 66 62;pink! l 5 80 44 79 45;%C o 66 63 6"),
        ("run", "달리기", "running", "%T q 8 24 52 8 46 12 30;2:brown! l 3 7 38 16 38;%C b 20 60 9 26 4.5 45;%C b 34 62 9 24 4.5 30;%A e 48 56 26 16 -6;1:orange! e 34 56 7 7;1:choco! e 54 62 7 6;2:w! e 52 65 10 5 -6;2:brown! l 3 34 44 36 52;2:brown! l 3 44 42 46 50;%C b 62 60 9 26 4.5 -45;%C b 50 62 9 24 4.5 -25;H happy 72 36 .52;sky! l 3 8 60 14 60;sky! l 3 10 70 18 70"),
        ("cook", "요리", "cooking", "\(catSeat);\(catLegs);H smile 46 40 .56;w b 36 16 20 12 3;w o 38 14 6.5;w o 54 14 6.5;w o 46 11 7.5;w! b 37 18 18 8 2;dark l 5 48 77 60 75;dark e 74 73 16 7;w! e 74 71 10 4;yellow! o 74 71 3.5;%C o 50 77 6"),
        ("clean", "청소", "cleaning", "\(catSeat);\(catLegs);brown l 5 80 14 72 68;butter p 3 62 68 82 68 88 90 56 90;choco! l 2 68 74 65 88;choco! l 2 76 74 78 88;%C e 72 50 7 6;H happy 44 34 .58;sky s M28 24 C34 12 54 12 60 24 L44 28 Z"),
        ("gift", "선물 들기", "with a gift", "\(catSeat);red b 32 60 36 30 5;yellow! b 46 60 8 30 0;yellow! b 32 71 36 7 0;yellow e 43 58 8 4.5 -20;yellow e 57 58 8 4.5 20;%C e 30 74 6 7;%C e 70 74 6 7;H happy 50 30 .58"),
        ("box", "상자 속", "in a box", "#C4935E p 3 14 58 8 46 30 46 34 58;#C4935E p 3 86 58 92 46 70 46 66 58;H wow 50 38 .62;tan b 14 56 72 36 5;brown! b 44 56 12 11 1;@pawflat 50 78 .32 A=brown;%C e 36 56 7 5;%C e 64 56 7 5"),
        ("window", "창문", "at a window", "w b 12 10 76 72 8;sky b 18 16 64 62 4;w! o 68 28 6;H smile 50 52 .6;pink s M18 16 L36 16 C34 32 26 42 18 48 Z;pink s M82 16 L64 16 C66 32 74 42 82 48 Z;brown b 6 74 88 14 5;%C e 38 74 7 5;%C e 62 74 7 5"),
        ("flower", "꽃 들기", "with a flower", "\(catSeat);\(catLegs);leaf l 3.5 72 72 74 38;leaf e 66 54 7 3.5 30;@flowerhead 74 26 .42 A=pink B=yellow;%C e 69 66 6 6;H happy 42 34 .58"),
        ("fishing", "낚시", "fishing", "%T q 7 18 82 8 78 10 62;%A e 30 72 17 18;1:orange! e 22 72 6 8;1:choco! e 38 80 5 6;2:w! e 30 74 9 11;%C b 21 76 8 15 4;%C b 32 76 8 15 4;blue b 46 78 46 14 7;sky! l 3 54 84 62 84;sky! l 3 70 86 80 86;brown l 4 42 64 88 16;k l 1.6 88 16 88 54;orange p 3 72 62 64 56 64 70;orange e 80 62 11 6.5;k o 86 61 1.6;%C o 44 64 6;H smile 30 38 .54")
    ]

    /// 색을 고를 수 있는 고양이 소품. 다색판 일부는 `monoVariants`로 단색도 낸다.
    private static let catItems = #"""
    cat.paw.pink|분홍 발바닥|Pink paw|d|w o 50 52 40;pink e 50 62 15 12;pink o 28 44 7;pink o 42 32 7;pink o 58 32 7;pink o 72 44 7
    cat.fish|생선|Fish|c|blue p 3 66 50 90 30 86 50 90 70;sky s M10 50 C24 26 52 26 72 50 C52 74 24 74 10 50 Z;w! o 28 46 5;k o 28 46 3;blue! q 3 42 36 48 50 42 64;blue! q 3 52 40 56 50 52 60
    cat.fishbone|생선 뼈|Fish bone|c|w l 5 30 50 76 50;w l 4 42 36 42 64;w l 4 54 38 54 62;w l 4 66 40 66 60;w p 4 10 50 30 32 34 50 30 68;w p 3 72 50 90 36 90 64;k o 22 47 2.6
    cat.yarn|털실|Yarn ball|c|rose q 4 66 80 86 90 90 72;rose o 46 48 34;#C4607F! q 3 18 34 46 44 66 22;#C4607F! q 3 13 50 46 62 78 38;#C4607F! q 3 20 66 48 78 80 52;#C4607F! q 3 40 16 28 48 44 80
    cat.yarn.blue|파란 털실|Blue yarn|d|sky q 4 66 80 86 90 90 72;sky o 46 48 34;#7FAFD9! q 3 18 34 46 44 66 22;#7FAFD9! q 3 13 50 46 62 78 38;#7FAFD9! q 3 20 66 48 78 80 52;#7FAFD9! q 3 40 16 28 48 44 80
    cat.snack|간식 봉지|Snack bag|c|sky p 3 22 14 78 14 74 88 26 88;w b 32 30 36 26 8;orange p 3 58 43 66 36 66 50;orange e 50 43 11 6.5;k o 44 42 1.6;navy! t 50 72 17 간식;navy! l 3 24 21 76 21
    cat.bell|방울|Bell|c|red b 12 22 76 16 8;yellow o 50 58 26;#D9A92E! l 3 26 52 74 52;k o 50 66 5;k l 3 50 68 50 80;w! o 40 46 4
    cat.feather|깃털 장난감|Feather toy|c|brown l 4 14 88 56 44;k l 1.8 56 44 62 38;purple s M60 40 C56 22 72 10 88 10 C90 26 80 42 60 40 Z;pink s M58 42 C46 40 40 28 44 16 C54 20 62 28 58 42 Z;sky s M62 42 C72 44 82 52 84 62 C72 62 62 54 62 42 Z;#7E62B8! l 2 62 38 80 18
    cat.tower|캣타워|Cat tree|c|tan b 22 30 12 58 2;tan b 62 48 12 40 2;choco! l 2 22 42 34 44;choco! l 2 22 54 34 56;choco! l 2 22 66 34 68;choco! l 2 62 60 74 62;choco! l 2 62 72 74 74;rose b 10 82 80 10 5;rose b 48 44 42 10 5;rose b 12 30 40 10 5;k l 1.6 80 54 80 66;yellow o 80 70 5;@cat.hwarang 32 20 .32;@face.happy 32 20 .32
    cat.ears|고양이 귀 머리띠|Cat ear band|c|dark q 6 14 80 50 12 86 80;dark p 4 16 54 14 18 42 28;dark p 4 84 54 86 18 58 28;pink! p 3 22 44 21 28 34 32;pink! p 3 78 44 79 28 66 32;rose e 40 28 7 4 -20;rose e 56 26 7 4 20;red o 48 27 3.5
    cat.ears.w|흰 귀 머리띠|White ear band|c|rose q 6 14 80 50 12 86 80;w p 4 16 54 14 18 42 28;w p 4 84 54 86 18 58 28;pink! p 3 22 44 21 28 34 32;pink! p 3 78 44 79 28 66 32
    cat.bowl|밥그릇|Food bowl|c|tan e 50 42 30 9;brown! e 50 42 26 6;tan o 38 38 5;tan o 50 36 5;tan o 62 38 5;tan o 44 42 4;tan o 56 42 4;rose p 8 14 44 86 44 74 84 26 84;@pawflat 50 64 .34 A=w
    cat.can|통조림|Cat food can|c|gray e 50 36 30 11;sky s M20 36 L20 72 C20 88 80 88 80 72 L80 36 C80 48 20 48 20 36 Z;orange p 3 64 66 72 60 72 72;orange e 54 66 12 6.5;k o 48 65 1.6;gray! e 50 36 22 7;dark! o 66 36 2.5
    cat.mouse|쥐 인형|Toy mouse|c|k q 3.5 18 66 6 48 14 36;gray o 62 32 11;pink! o 62 32 6;gray s M14 72 C20 46 52 36 84 70 C72 80 28 82 14 72 Z;pink o 84 70 3.5;k o 70 58 2.8;gray o 50 42 10;pink! o 50 42 5.5
    cat.back|뒷모습|Cat from behind|c|w q 8 70 82 92 78 82 54;w e 50 68 25 24;w p 4 34 28 32 8 46 18;w p 4 66 28 68 8 54 18;w e 50 34 21 18;orange! e 42 58 9 8;choco! e 62 74 8 8;orange! e 40 30 7 6
    cat.cushion|방석|Cushion|c|peach p 14 12 44 88 44 92 80 8 80;k o 40 60 2.8;k o 60 60 2.8;k q 2.4 45 66 50 70 55 66;rose! e 30 66 5 3;rose! e 70 66 5 3;butter o 12 44 4;butter o 88 44 4;butter o 10 80 4;butter o 90 80 4
    """#

    private static let catMonoExtras = #"""
    cat.paw|발바닥|Paw|m|T e 50 64 20 16;T o 22 42 9;T o 40 26 9;T o 60 26 9;T o 78 42 9
    cat.paws|발자국|Paw prints|m|@paw 30 72 .55 -18 A=T;@paw 54 46 .55 12 A=T;@paw 76 20 .45 -10 A=T
    cat.paw.heart|하트 발바닥|Heart paw|m|T heart 50 66 38;T o 22 42 9;T o 40 26 9;T o 60 26 9;T o 78 42 9
    cat.yarn.m|털실 단색|Yarn mono|m|T q 4 66 80 86 90 90 72;T o 46 48 34;k q 2.4 18 34 46 44 66 22;k q 2.4 13 50 46 62 78 38;k q 2.4 20 66 48 78 80 52;k q 2.4 40 16 28 48 44 80
    cat.tower.m|캣타워 단색|Cat tree mono|m|T b 22 30 12 58 2;T b 62 48 12 40 2;T b 10 82 80 10 5;T b 48 44 42 10 5;T b 12 30 40 10 5;k l 1.6 80 54 80 66;T o 80 70 5;@catbase 32 20 .32 A=T B=T;@face.happy 32 20 .32
    cat.m.heart|하트 고양이|Cat with heart|m|@catbase 46 54 .9 A=T B=T;@face.happy 46 54 .9;T heart 80 22 26
    """#

    static let catsSource: String = {
        let faces = [("smile", "방긋", "smile"), ("happy", "행복", "happy"), ("love", "사랑", "love"), ("sleep", "쿨쿨", "sleepy"),
                     ("cry", "눈물", "crying"), ("angry", "화남", "angry"), ("wow", "놀람", "wow"), ("wink", "윙크", "wink")]
        let moreFaces = [("yum", "냠냠", "yum"), ("shy", "부끄", "shy"), ("cool", "멋짐", "cool"),
                         ("star", "반짝", "starry"), ("tongue", "메롱", "tongue out"), ("dizzy", "어질어질", "dizzy")]
        var lines: [String] = []
        for coat in catCoats {
            for face in faces {
                lines.append("cat.\(coat.id).\(face.0)|\(coat.ko) \(face.1)|\(coat.en) \(face.2)|d|\(catHead(coat, expression: face.0, at: "50 50 1"))")
            }
        }
        for coat in catCoats {
            for face in moreFaces {
                lines.append("cat.\(coat.id).\(face.0)|\(coat.ko) \(face.1)|\(coat.en) \(face.2)|d|\(catHead(coat, expression: "catface.\(face.0)", at: "50 50 1"))")
            }
        }
        for coat in catCoats {
            for pose in catPoses {
                lines.append("cat.\(coat.id).body.\(pose.id)|\(coat.ko) \(pose.ko)|\(coat.en) \(pose.en)|d|\(catPose(pose.art, coat: coat))")
            }
        }
        lines.append(catItems)
        lines.append(catMonoExtras)
        for (id, ko, en) in [("smile", "방긋", "smile"), ("happy", "행복", "happy"), ("sleep", "쿨쿨", "sleepy"), ("angry", "화남", "angry")] {
            lines.append("cat.m.face.\(id)|고양이 \(ko)|Cat \(en)|m|\(catHead(nil, expression: id, at: "50 50 1"))")
        }
        for pose in catPoses {
            lines.append("cat.m.\(pose.id)|고양이 \(pose.ko)|Cat \(pose.en)|m|\(monoLayers(catPose(pose.art, coat: nil)))")
        }
        lines.append(monoVariants(of: ["cat.fish", "cat.fishbone", "cat.snack", "cat.bell", "cat.feather", "cat.ears", "cat.bowl", "cat.can", "cat.mouse", "cat.back", "cat.cushion"], in: catItems))
        return lines.joined(separator: "\n")
    }()
}
