import Foundation

extension StickerCatalog {
    static let phrasesParts = #"""
    phrases.round.l|A s M30 14 L70 14 C84 14 92 26 92 42 C92 58 84 70 70 70 L46 70 L24 90 L28 70 C16 70 8 58 8 42 C8 26 16 14 30 14 Z
    phrases.round.r|A s M70 14 L30 14 C16 14 8 26 8 42 C8 58 16 70 30 70 L54 70 L76 90 L72 70 C84 70 92 58 92 42 C92 26 84 14 70 14 Z
    phrases.side.l|A s M38 20 L74 20 C86 20 94 32 94 46 C94 60 86 72 74 72 L38 72 C28 72 22 66 20 58 L5 64 L19 42 C21 30 28 20 38 20 Z
    phrases.side.r|A s M62 20 L26 20 C14 20 6 32 6 46 C6 60 14 72 26 72 L62 72 C72 72 78 66 80 58 L95 64 L81 42 C79 30 72 20 62 20 Z
    phrases.rect.l|A s M18 14 L82 14 Q92 14 92 24 L92 60 Q92 70 82 70 L46 70 L26 90 L28 70 L18 70 Q8 70 8 60 L8 24 Q8 14 18 14 Z
    phrases.rect.r|A s M82 14 L18 14 Q8 14 8 24 L8 60 Q8 70 18 70 L54 70 L74 90 L72 70 L82 70 Q92 70 92 60 L92 24 Q92 14 82 14 Z
    phrases.oval.l|A s M50 14 C76 14 94 26 94 43 C94 60 76 72 52 72 L30 90 L36 70 C18 67 6 57 6 43 C6 26 24 14 50 14 Z
    phrases.oval.r|A s M50 14 C24 14 6 26 6 43 C6 60 24 72 48 72 L70 90 L64 70 C82 67 94 57 94 43 C94 26 76 14 50 14 Z
    phrases.cloud.l|A s M26 70 C10 70 4 56 14 46 C8 30 26 18 38 24 C46 10 68 12 72 26 C88 24 98 44 86 56 C92 66 82 72 72 70 L46 70 L28 90 L32 70 Z
    phrases.cloud.r|A s M74 70 C90 70 96 56 86 46 C92 30 74 18 62 24 C54 10 32 12 28 26 C12 24 2 44 14 56 C8 66 18 72 28 70 L54 70 L72 90 L68 70 Z
    phrases.think.l|A s M26 68 C10 68 4 54 14 44 C8 28 26 16 38 22 C46 8 68 10 72 24 C88 22 98 42 86 54 C92 64 82 70 72 68 Z;A o 30 78 6;A o 18 88 3.5
    phrases.think.r|A s M74 68 C90 68 96 54 86 44 C92 28 74 16 62 22 C54 8 32 10 28 24 C12 22 2 42 14 54 C8 64 18 70 28 68 Z;A o 70 78 6;A o 82 88 3.5
    phrases.shout|A p 3 8 22 28 28 42 8 56 26 76 10 78 30 94 42 80 54 90 72 68 68 52 74 34 92 34 70 14 74 20 54 6 42 18 34
    phrases.burst|A star 50 50 46 35 14
    phrases.cat.l|A s M18 32 L14 12 Q13 6 19 9 L38 20 L62 20 L81 9 Q87 6 86 12 L82 32 C90 40 94 46 92 54 C92 68 82 76 70 76 L46 76 L28 92 L32 76 C18 76 8 68 8 54 C6 46 10 40 18 32 Z
    phrases.cat.r|A s M82 32 L86 12 Q87 6 81 9 L62 20 L38 20 L19 9 Q13 6 14 12 L18 32 C10 40 6 46 8 54 C8 68 18 76 30 76 L54 76 L72 92 L68 76 C82 76 92 68 92 54 C94 46 90 40 82 32 Z
    phrases.banner|A p 3 4 38 24 38 24 74 4 74 13 56;A p 3 96 38 76 38 76 74 96 74 87 56;A b 13 26 74 38 6
    phrases.board|k! l 3 28 34 48 14;k! l 3 72 34 52 14;A o 50 12 4;A b 6 32 88 56 8
    phrases.tag|A p 4 5 50 24 24 92 24 92 76 24 76;k! o 22 50 4
    phrases.pill|A b 6 28 88 44 22
    phrases.badge|A star 50 50 44 38 18
    phrases.heart|A heart 50 50 88
    phrases.note|A p 3 12 12 88 12 88 66 66 88 12 88;A p 3 88 66 66 66 66 88
    phrases.stamp|A o 50 50 42;k! o 50 50 36;A! o 50 50 33.5
    """#

    static let decoParts = #"""
    deco.cloud|A s M26 72 C10 72 4 56 14 46 C8 30 26 18 38 24 C46 10 68 12 72 26 C88 24 98 44 86 56 C92 66 82 74 72 72 Z
    deco.bow|A p 3 46 52 26 86 40 84 48 92 54 54;A p 3 54 52 74 86 60 84 52 92 46 54;A s M50 46 C38 24 12 18 10 38 C8 60 36 64 50 50 Z;A s M50 46 C62 24 88 18 90 38 C92 60 64 64 50 50 Z;A b 42 38 16 20 7
    deco.rosette|A p 3 34 56 22 90 40 80 48 62;A p 3 66 56 78 90 60 80 52 62;A star 50 40 32 27 14;A o 50 40 17
    deco.crown|A p 4 14 34 32 52 50 22 68 52 86 34 80 78 20 78;A o 14 30 5;A o 50 18 6;A o 86 30 5
    deco.gem|A p 3 28 20 72 20 92 42 50 88 8 42;k! l 2.5 8 42 92 42;k! l 2.5 34 42 50 88;k! l 2.5 66 42 50 88;k! l 2.5 28 20 34 42;k! l 2.5 72 20 66 42;k! l 2.5 50 20 34 42;k! l 2.5 50 20 66 42
    deco.tape|A p 3 8 34 92 34 88 39 92 44 88 50 92 56 88 61 92 66 8 66 12 61 8 56 12 50 8 44 12 39
    deco.tape.stripe|@deco.tape A=A;k! l 3 28 38 22 62;k! l 3 42 38 36 62;k! l 3 56 38 50 62;k! l 3 70 38 64 62;k! l 3 84 38 78 62
    deco.tape.dot|@deco.tape A=A;k! o 24 44 3;k! o 40 56 3;k! o 56 44 3;k! o 72 56 3;k! o 80 42 2
    deco.arrow|A l 10 14 50 80 50;A l 10 58 26 84 50 58 74
    deco.block|A p 3 10 36 54 36 54 16 90 50 54 84 54 64 10 64
    """#

    static let phrasesSource: String = {
        // 그림, 글자 가운데 x·y, 글자 칸 폭·높이
        let shapes: [String: (art: String, x: Double, y: Double, width: Double, height: Double)] = [
            "roundL": ("@phrases.round.l", 50, 42, 70, 44), "roundR": ("@phrases.round.r", 50, 42, 70, 44),
            "topL": ("@phrases.round.r 50 50 1 180", 50, 58, 70, 44), "topR": ("@phrases.round.l 50 50 1 180", 50, 58, 70, 44),
            "sideL": ("@phrases.side.l", 57, 46, 60, 40), "sideR": ("@phrases.side.r", 43, 46, 60, 40),
            "rectL": ("@phrases.rect.l", 50, 42, 72, 44), "rectR": ("@phrases.rect.r", 50, 42, 72, 44),
            "ovalL": ("@phrases.oval.l", 50, 43, 70, 40), "ovalR": ("@phrases.oval.r", 50, 43, 70, 40),
            "cloudL": ("@phrases.cloud.l", 50, 45, 58, 36), "cloudR": ("@phrases.cloud.r", 50, 45, 58, 36),
            "thinkL": ("@phrases.think.l", 50, 42, 58, 36), "thinkR": ("@phrases.think.r", 50, 42, 58, 36),
            "shout": ("@phrases.shout", 50, 44, 44, 30), "burst": ("@phrases.burst", 50, 50, 54, 40),
            "catL": ("@phrases.cat.l", 50, 49, 64, 38), "catR": ("@phrases.cat.r", 50, 49, 64, 38),
            "banner": ("@phrases.banner", 50, 45, 62, 30), "board": ("@phrases.board", 50, 60, 76, 44),
            "tag": ("@phrases.tag", 58, 50, 56, 38), "pill": ("@phrases.pill", 50, 50, 74, 32),
            "badge": ("@phrases.badge", 50, 50, 58, 46), "heart": ("@phrases.heart", 50, 47, 52, 36),
            "note": ("@phrases.note", 48, 40, 62, 44), "stamp": ("@phrases.stamp", 50, 50, 52, 40)
        ]
        let empty = [
            ("round.l", "둥근 말풍선 왼쪽", "Round left", "roundL"), ("round.r", "둥근 말풍선 오른쪽", "Round right", "roundR"),
            ("top.l", "둥근 말풍선 위 왼쪽", "Round top left", "topL"), ("top.r", "둥근 말풍선 위 오른쪽", "Round top right", "topR"),
            ("side.l", "옆 말풍선 왼쪽", "Side left", "sideL"), ("side.r", "옆 말풍선 오른쪽", "Side right", "sideR"),
            ("rect.l", "네모 말풍선 왼쪽", "Square left", "rectL"), ("rect.r", "네모 말풍선 오른쪽", "Square right", "rectR"),
            ("oval.l", "타원 말풍선 왼쪽", "Oval left", "ovalL"), ("oval.r", "타원 말풍선 오른쪽", "Oval right", "ovalR"),
            ("cloud.l", "구름 말풍선 왼쪽", "Cloud left", "cloudL"), ("cloud.r", "구름 말풍선 오른쪽", "Cloud right", "cloudR"),
            ("think.l", "생각 말풍선 왼쪽", "Thought left", "thinkL"), ("think.r", "생각 말풍선 오른쪽", "Thought right", "thinkR"),
            ("shout", "뾰족 말풍선", "Shout", "shout"), ("burst", "터짐 말풍선", "Burst", "burst"),
            ("cat.l", "고양이 말풍선 왼쪽", "Cat left", "catL"), ("cat.r", "고양이 말풍선 오른쪽", "Cat right", "catR")
        ]
        // id, 글귀(`/`는 줄바꿈), 그림, 다색일 때 바탕색
        let words: [(String, String, String, String?)] = [
            ("fighting", "오늘도/파이팅", "cloudL", nil), ("best", "최고", "burst", nil), ("goodjob", "수고했어", "roundL", nil),
            ("thankyou", "고마워", "roundR", nil), ("loveyou", "사랑해", "heart", nil), ("itsok", "괜찮아", "cloudR", nil),
            ("welldone", "잘했어", "badge", nil), ("cheer", "힘내", "ovalL", nil), ("awesome", "대박", "shout", nil),
            ("congrats", "축하해", "banner", nil), ("happy.ko", "행복해", "ovalR", nil), ("yummy", "맛있다", "roundL", nil),
            ("sleepy", "졸려", "thinkL", nil), ("hungry", "배고파", "thinkR", nil), ("offwork", "퇴근", "tag", nil),
            ("towork", "출근", "tag", nil), ("monday", "월요병", "cloudL", nil), ("dayend", "오늘 끝", "pill", nil),
            ("tomorrow", "내일 또", "pill", nil), ("dontforget", "잊지 마", "note", nil), ("important", "중요", "stamp", nil),
            ("complete", "완료", "stamp", nil), ("postponed", "미룸", "stamp", nil), ("promise", "약속", "note", nil),
            ("birthday", "생일", "banner", nil), ("todo", "TODO", "tag", nil), ("done", "DONE", "stamp", nil),
            ("ok", "OK", "badge", nil), ("new", "NEW", "burst", nil), ("best.en", "BEST", "banner", nil),
            ("happy", "HAPPY", "banner", nil), ("thanks", "THANKS", "rectL", nil), ("good", "GOOD", "ovalL", nil),
            ("dday", "D-DAY", "board", nil), ("memo", "MEMO", "note", nil), ("wow", "WOW", "shout", nil),
            ("love", "LOVE", "heart", nil), ("plan", "PLAN", "board", nil), ("yes", "YES", "roundR", nil),
            ("no", "NO", "roundL", nil), ("soon", "SOON", "pill", nil), ("busy", "BUSY", "rectR", nil),
            ("meow", "야옹", "catL", nil), ("nyang", "냥", "catR", nil), ("nyangnyang", "냥냥", "catL", nil),
            ("cat.towork", "출근했냥", "catR", nil), ("cat.offwork", "퇴근하냥", "catL", nil), ("cat.good", "좋다냥", "catR", nil),
            ("cat.hungry", "배고프냥", "catL", nil), ("cat.sleepy", "졸리냥", "catR", nil), ("cat.thanks", "고맙다냥", "catL", nil),
            ("cat.cheer", "힘내냥", "catR", nil), ("cat.goodjob", "수고했냥", "catL", nil), ("cat.love", "사랑한다/냥", "catR", nil),
            ("like", "좋아", "roundR", nil), ("dislike", "싫어", "rectL", nil), ("dunno", "몰라", "thinkL", nil),
            ("whattodo", "어쩌지", "thinkR", nil), ("yay", "아싸", "burst", nil), ("oops", "헉", "shout", nil),
            ("gosh", "앗", "shout", nil), ("great", "짱", "badge", nil), ("sorry", "미안해", "cloudR", nil),
            ("missyou", "보고/싶어", "heart", nil), ("thankful", "감사/합니다", "rectR", nil), ("today.plan", "오늘의/일정", "board", nil),
            ("today.mood", "오늘의/기분", "board", nil), ("mustdo", "할 일", "tag", nil), ("nexttime", "다음에", "sideL", nil),
            ("hurry", "급해", "shout", nil), ("deadline", "마감", "stamp", nil), ("wait", "잠깐", "sideR", nil),
            ("rest", "쉬자", "pill", nil), ("play", "놀자", "pill", nil), ("gohome", "집에/갈래", "cloudL", nil),
            ("check", "체크", "tag", nil), ("color.best", "최고", "burst", "yellow"), ("color.love", "사랑해", "heart", "pink"),
            ("color.done", "완료", "stamp", "mint"), ("color.important", "중요", "stamp", "red"), ("color.fighting", "파이팅", "banner", "orange"),
            ("color.meow", "야옹", "catL", "butter"), ("color.thanks", "THANKS", "cloudR", "sky"), ("color.new", "NEW", "shout", "peach")
        ]
        let emptyLines = empty.map { item -> String in
            let art = shapes[item.3]!.art
            return "phrases.empty.\(item.0)|\(item.1)|\(item.2)|m|\(art) A=T"
        }
        let wordLines = words.map { item -> String in
            let shape = shapes[item.2]!
            let text = phraseLayers(item.1, x: shape.x, y: shape.y, width: shape.width, height: shape.height)
            let name = item.1.replacingOccurrences(of: "/", with: " ")
            return "phrases.\(item.0)|\(name)|\(name)|\(item.3 == nil ? "m" : "c")|\(shape.art) A=\(item.3 ?? "T");\(text)"
        }
        return (emptyLines + wordLines).joined(separator: "\n")
    }()

    static let datesSource: String = {
        func line(_ id: String, _ ko: String, _ en: String, _ art: String, _ text: String, x: Double = 50, y: Double = 50, width: Double, height: Double) -> String {
            "dates.\(id)|\(ko)|\(en)|m|\(art);\(phraseLayers(text, x: x, y: y, width: width, height: height))"
        }
        let circle = "T o 50 50 42"
        let square = "T b 10 10 80 80 20"
        let pill = "T b 6 28 88 44 22"
        let tag = "T p 4 5 50 24 24 92 24 92 76 24 76;k! o 22 50 4"
        let sheet = "k l 6 32 10 32 22;k l 6 68 10 68 22;T b 10 16 80 74 12;k! l 3 10 34 90 34"
        let catHead = "@catbase A=T B=T"
        let flag = "k l 5 18 10 18 90;T p 3 18 14 90 14 76 38 90 62 18 62"
        var lines = (1...31).map { line("n\($0)", "\($0)", "\($0)", circle, "\($0)", width: 60, height: 44) }
        let weekdays = [("mon", "월", "MON"), ("tue", "화", "TUE"), ("wed", "수", "WED"), ("thu", "목", "THU"), ("fri", "금", "FRI"), ("sat", "토", "SAT"), ("sun", "일", "SUN")]
        lines += weekdays.map { line("day.\($0.0)", "\($0.1)", $0.2, square, $0.1, width: 56, height: 46) }
        lines += weekdays.map { line("en.\($0.0)", "\($0.2)", $0.2, pill, $0.2, width: 70, height: 30) }
        lines += weekdays.map { line("full.\($0.0)", "\($0.1)요일", $0.2, tag, "\($0.1)요일", x: 58, width: 58, height: 34) }
        lines += (1...12).map { line("m\($0)", "\($0)월", "Month \($0)", sheet, "\($0)월", y: 62, width: 66, height: 40) }
        lines += (1...4).map { line("q\($0)", "\($0)분기", "Q\($0)", square, "\($0)/분기", width: 62, height: 60) }
        lines += (1...4).map { line("q\($0).en", "Q\($0)", "Q\($0)", circle, "Q\($0)", width: 58, height: 40) }
        lines += [
            line("am", "오전", "AM", pill, "오전", width: 66, height: 30),
            line("pm", "오후", "PM", pill, "오후", width: 66, height: 30),
            line("am.en", "AM", "AM", circle, "AM", width: 58, height: 40),
            line("pm.en", "PM", "PM", circle, "PM", width: 58, height: 40),
            line("today", "오늘", "Today", catHead, "오늘", y: 58, width: 52, height: 30),
            line("tomorrow", "내일", "Tomorrow", catHead, "내일", y: 58, width: 52, height: 30),
            line("yesterday", "어제", "Yesterday", catHead, "어제", y: 58, width: 52, height: 30),
            line("thisweek", "이번 주", "This week", flag, "이번 주", x: 45, y: 38, width: 46, height: 26),
            line("nextweek", "다음 주", "Next week", flag, "다음 주", x: 45, y: 38, width: 46, height: 26),
            line("weekend", "주말", "Weekend", "T star 50 50 46 35 14", "주말", width: 54, height: 36),
            line("weekday", "평일", "Weekday", pill, "평일", width: 66, height: 30)
        ]
        lines += (1...4).map { line("w\($0)", "\($0)주", "Week \($0)", tag, "\($0)주", x: 58, width: 54, height: 36) }
        lines += [1, 3, 7, 30, 100].map { line("d\($0)", "D-\($0)", "D-\($0)", square, "D-\($0)", width: 68, height: 40) }
        return lines.joined(separator: "\n")
    }()

    static let decoSource: String = {
        let fixed = #"""
        deco.bow|리본|Bow|m|@deco.bow A=T
        deco.bow.pink|분홍 리본|Pink bow|c|@deco.bow A=pink
        deco.bow.red|빨강 리본|Red bow|c|@deco.bow A=red
        deco.bow.sky|하늘 리본|Blue bow|c|@deco.bow A=sky
        deco.rosette|장미 리본|Rosette|m|@deco.rosette A=T
        deco.rosette.gold|금메달 리본|Gold rosette|c|@deco.rosette A=yellow;orange! star 50 40 12 5 5
        deco.crown|왕관|Crown|m|@deco.crown A=T
        deco.crown.gold|금 왕관|Gold crown|d|@deco.crown A=yellow;red o 50 62 6;sky o 30 64 4;sky o 70 64 4
        deco.gem|다이아|Diamond|m|@deco.gem A=T
        deco.gem.blue|파란 다이아|Blue diamond|c|@deco.gem A=sky
        deco.gem.pink|분홍 다이아|Pink diamond|c|@deco.gem A=pink
        deco.bead|구슬|Bead|m|T o 50 50 36;k! q 3 32 42 36 30 48 26
        deco.bead.red|빨간 구슬|Red bead|d|red o 50 50 36
        deco.bead.blue|파란 구슬|Blue bead|d|blue o 50 50 36
        deco.bead.mint|민트 구슬|Mint bead|d|mint o 50 50 36
        deco.bead.lilac|보라 구슬|Lilac bead|d|lilac o 50 50 36
        deco.frame.square|네모 프레임|Square frame|m|T b 8 8 84 84 14;T b 21 21 58 58 6
        deco.frame.round|원 프레임|Round frame|m|T o 50 50 42;T o 50 50 29
        deco.frame.heart|하트 프레임|Heart frame|m|T heart 50 50 90;T heart 50 50 54
        deco.frame.cloud|구름 프레임|Cloud frame|m|@deco.cloud A=T;@deco.cloud 50 47 0.6 A=T
        deco.frame.oval|타원 프레임|Oval frame|m|T e 50 50 43 33;T e 50 50 31 22
        deco.frame.wide|긴 프레임|Wide frame|m|T b 6 26 88 48 12;T b 15 35 70 30 6
        deco.frame.star|별 프레임|Star frame|m|T star 50 53 46 24 5;T star 50 53 26 13 5
        deco.frame.cat|고양이 프레임|Cat frame|m|@catbase A=T B=T;T e 50 57 26 20
        deco.frame.double|겹 프레임|Double frame|m|T b 8 8 84 84 10;k! b 14 14 72 72 7;T! b 16.5 16.5 67 67 5
        deco.frame.stamp|우표 프레임|Stamp frame|m|T star 50 50 46 41 24;T b 26 26 48 48 4
        deco.label|라벨|Label|m|T b 8 30 84 40 8;k! l 2.5 16 38 84 38;k! l 2.5 16 62 84 62
        deco.label.tag|꼬리표|Tag|m|T p 4 5 50 24 24 92 24 92 76 24 76;k! o 22 50 4
        deco.label.ticket|티켓|Ticket|m|T s M12 26 L88 26 Q90 38 96 40 L96 60 Q90 62 88 74 L12 74 Q10 62 4 60 L4 40 Q10 38 12 26 Z;k! l 2.5 68 32 68 40;k! l 2.5 68 46 68 54;k! l 2.5 68 60 68 68
        deco.label.banner|빈 현수막|Banner|m|@phrases.banner 50 56 1 A=T
        deco.line.plain|줄|Line|m|T l 6 8 50 92 50
        deco.line.double|두 줄|Double line|m|T l 4 8 42 92 42;T l 4 8 58 92 58
        deco.line.wave|물결 줄|Wavy line|m|T q 6 8 50 22 28 36 50;T q 6 36 50 50 72 64 50;T q 6 64 50 78 28 92 50
        deco.line.dash|점선|Dashed line|m|T l 7 8 50 20 50;T l 7 32 50 44 50;T l 7 56 50 68 50;T l 7 80 50 92 50
        deco.line.dot|동글 줄|Dotted line|m|T o 12 50 6;T o 31 50 6;T o 50 50 6;T o 69 50 6;T o 88 50 6
        deco.line.star|별 줄|Star line|m|T star 16 50 13 6 5;T star 50 50 13 6 5;T star 84 50 13 6 5;T l 3 28 50 38 50;T l 3 62 50 72 50
        deco.line.heart|하트 줄|Heart line|m|T heart 16 50 24;T heart 50 50 24;T heart 84 50 24
        deco.line.paw|발바닥 줄|Paw line|m|@paw 18 50 0.34 A=T;@paw 50 50 0.34 A=T;@paw 82 50 0.34 A=T
        deco.tape.plain|마스킹테이프|Masking tape|m|@deco.tape 50 50 1 -14 A=T
        deco.tape.stripe|줄무늬 테이프|Striped tape|m|@deco.tape.stripe 50 50 1 -14 A=T
        deco.tape.dot|물방울 테이프|Dotted tape|m|@deco.tape.dot 50 50 1 14 A=T
        deco.tape.pink|분홍 테이프|Pink tape|c|@deco.tape 50 50 1 14 A=pink
        deco.tape.mint|민트 테이프|Mint tape|c|@deco.tape.dot 50 50 1 -14 A=mint
        deco.tape.butter|노랑 테이프|Yellow tape|c|@deco.tape.stripe 50 50 1 8 A=butter
        deco.corner.tl|코너 왼쪽 위|Corner top left|m|T p 4 10 10 76 10 10 76
        deco.corner.tr|코너 오른쪽 위|Corner top right|m|T p 4 90 10 24 10 90 76
        deco.corner.bl|코너 왼쪽 아래|Corner bottom left|m|T p 4 10 90 76 90 10 24
        deco.corner.br|코너 오른쪽 아래|Corner bottom right|m|T p 4 90 90 24 90 90 24
        deco.corner.paw|발바닥 코너|Paw corner|m|T p 4 10 10 84 10 10 84;@paw 28 28 0.34 A=k
        deco.sparkle|반짝|Sparkle|m|T star 50 50 46 14 4
        deco.sparkle.two|두 반짝|Two sparkles|m|T star 38 58 36 11 4;T star 74 26 22 7 4
        deco.sparkle.gold|금 반짝|Gold sparkle|c|yellow star 42 56 36 11 4;butter star 76 24 20 6 4;orange star 78 76 14 4 4
        deco.dust|별가루|Star dust|m|T star 24 26 13 5 5;T star 66 18 10 4 5;T star 80 52 14 6 5;T star 40 58 16 7 5;T star 18 80 9 4 5;T star 66 82 11 5 5
        deco.dust.color|알록달록 별가루|Color dust|c|yellow star 24 26 13 5 5;pink star 66 18 10 4 5;sky star 80 52 14 6 5;mint star 40 58 16 7 5;lilac star 18 80 9 4 5;orange star 66 82 11 5 5
        deco.note|음표|Note|m|T e 36 74 15 11 -20;T l 7 49 72 49 18;T q 8 49 18 58 34 74 34
        deco.note.two|두 음표|Two notes|m|T e 24 76 12 9 -20;T e 70 66 12 9 -20;T l 6 34 74 34 26;T l 6 80 64 80 16;T p 3 34 16 80 8 80 22 34 30
        deco.note.color|음표 셋|Note set|c|pink e 26 66 10 8 -20;pink l 5 34 64 34 26;pink q 6 34 26 42 34 50 34;sky e 66 80 10 8 -20;sky l 5 74 78 74 40;sky q 6 74 40 82 48 90 48
        deco.rainbow|무지개|Rainbow|c|red s M6 76 C6 14 94 14 94 76 Z;orange! s M14 76 C14 24 86 24 86 76 Z;yellow! s M22 76 C22 34 78 34 78 76 Z;green! s M30 76 C30 44 70 44 70 76 Z;blue! s M38 76 C38 54 62 54 62 76 Z;@deco.cloud 18 76 0.3 A=w;@deco.cloud 82 76 0.3 A=w
        deco.rainbow.mono|한 색 무지개|Mono rainbow|m|T s M6 76 C6 14 94 14 94 76 Z;T s M20 76 C20 32 80 32 80 76 Z;T s M34 76 C34 50 66 50 66 76 Z
        deco.cloud|구름 조각|Cloud piece|m|@deco.cloud A=T
        deco.cloud.white|흰 구름|White cloud|d|@deco.cloud A=w
        deco.cloud.two|구름 둘|Two clouds|m|@deco.cloud 64 38 0.62 A=T;@deco.cloud 36 62 0.74 A=T
        deco.check|체크|Check|m|T l 13 16 52 40 76 86 24
        deco.check.box|체크 상자|Checkbox|m|T b 12 12 76 76 14;k l 9 28 50 44 66 72 34
        deco.check.round|동그라미 체크|Round check|m|T o 50 50 42;k l 9 28 52 44 66 72 36
        deco.check.green|초록 체크|Green check|c|green l 13 16 52 40 76 86 24
        deco.arrow.r|오른쪽 화살표|Arrow right|m|@deco.arrow A=T
        deco.arrow.l|왼쪽 화살표|Arrow left|m|@deco.arrow 50 50 1 180 A=T
        deco.arrow.u|위 화살표|Arrow up|m|@deco.arrow 50 50 1 -90 A=T
        deco.arrow.d|아래 화살표|Arrow down|m|@deco.arrow 50 50 1 90 A=T
        deco.arrow.block|굵은 화살표|Block arrow|m|@deco.block A=T
        deco.arrow.curve|굽은 화살표|Curved arrow|m|T q 9 14 76 22 22 78 30;T l 9 58 12 80 30 62 50
        deco.under.curve|밑줄 곡선|Curved underline|m|T q 9 10 40 50 72 90 40
        deco.under.double|두 줄 곡선|Double underline|m|T q 7 10 32 50 56 90 32;T q 7 16 58 50 76 84 58
        deco.under.scribble|낙서 밑줄|Scribble|m|T l 6 10 40 88 34 16 52 86 48 22 66 80 62
        deco.under.swoosh|휙 곡선|Swoosh|m|T s M8 64 C30 34 70 30 92 40 C70 42 40 50 8 64 Z
        deco.confetti|컨페티|Confetti|m|T b 14 18 16 8 3 30;T b 62 12 16 8 3 -35;T o 42 34 5;T b 74 42 16 8 3 60;T b 20 54 16 8 3 -20;T o 56 58 6;T b 38 76 16 8 3 40;T o 82 76 5;T o 16 84 4
        deco.confetti.color|알록달록 컨페티|Color confetti|c|pink b 14 18 16 8 3 30;sky b 62 12 16 8 3 -35;yellow o 42 34 5;mint b 74 42 16 8 3 60;orange b 20 54 16 8 3 -20;lilac o 56 58 6;red b 38 76 16 8 3 40;green o 82 76 5;blue o 16 84 4
        deco.confetti.ribbon|리본 조각|Paper curls|m|T q 6 16 24 30 8 36 28;T q 6 62 14 80 20 72 38;T q 6 18 62 36 50 42 70;T q 6 64 58 84 58 78 80;T o 46 44 4;T o 28 86 4
        """#
        func checker(_ id: String, _ ko: String, _ en: String, _ style: String, _ base: String, _ mark: String) -> String {
            let cells = (0..<5).flatMap { row in (0..<5).compactMap { column -> String? in
                (row + column).isMultiple(of: 2) ? nil : "\(mark)! b \(10 + column * 16) \(10 + row * 16) 16 16 1"
            } }
            return "deco.checker\(id)|\(ko)|\(en)|\(style)|\(base) b 10 10 80 80 12;" + cells.joined(separator: ";")
        }
        func polka(_ id: String, _ ko: String, _ en: String, _ style: String, _ base: String, _ mark: String) -> String {
            let dots = [(26, 26), (50, 26), (74, 26), (38, 50), (62, 50), (26, 74), (50, 74), (74, 74), (18, 50), (82, 50)]
            return "deco.polka\(id)|\(ko)|\(en)|\(style)|\(base) b 10 10 80 80 16;" + dots.map { "\(mark)! o \($0.0) \($0.1) 4.5" }.joined(separator: ";")
        }
        func garland(_ id: String, _ ko: String, _ en: String, _ style: String, _ colors: [String], flag: (Int, Int, String) -> String) -> String {
            // 아래로 처진 줄에 깃발 네 개.
            let flags = [(20, 30), (40, 35), (60, 35), (80, 30)].enumerated().map { flag($1.0, $1.1, colors[$0 % colors.count]) }
            return "deco.garland\(id)|\(ko)|\(en)|\(style)|k! l 3.5 6 24 20 30 40 35 60 35 80 30 94 24;" + flags.joined(separator: ";")
        }
        func pennant(x: Int, y: Int, color: String) -> String { "\(color) p 3 \(x - 9) \(y) \(x + 9) \(y) \(x) \(y + 36)" }
        let laceRound = (0..<16).map { index -> String in
            let angle = Double(index) * .pi / 8
            let x = 50 + 36 * cos(angle), y = 50 + 36 * sin(angle)
            return "T o \(Int(x.rounded())) \(Int(y.rounded())) 9"
        }.joined(separator: ";")
        let edge = stride(from: 18, through: 82, by: 16)
        let laceSquare = (edge.map { "T o \($0) 16 8;T o \($0) 84 8;T o 16 \($0) 8;T o 84 \($0) 8" }).joined(separator: ";")
        let colorDots = [("red", "빨강", "Red"), ("orange", "주황", "Orange"), ("yellow", "노랑", "Yellow"), ("green", "초록", "Green"), ("blue", "파랑", "Blue"), ("purple", "보라", "Purple"), ("pink", "분홍", "Pink"), ("gray", "회색", "Gray")]
        let lines = [
            fixed,
            checker("", "체크 무늬", "Checker", "m", "T", "k"),
            checker(".pink", "분홍 체크", "Pink checker", "c", "w", "pink"),
            checker(".mint", "민트 체크", "Mint checker", "c", "w", "mint"),
            polka("", "물방울 무늬", "Polka dots", "m", "T", "k"),
            polka(".sky", "하늘 물방울", "Sky polka", "c", "sky", "w"),
            polka(".pink", "분홍 물방울", "Pink polka", "c", "pink", "w"),
            "deco.lace.round|둥근 레이스|Round lace|m|\(laceRound);T! o 50 50 36;T o 50 50 26",
            "deco.lace.square|네모 레이스|Square lace|m|\(laceSquare);T! b 16 16 68 68 4;T b 26 26 48 48 4",
            garland("", "깃발 줄", "Garland", "m", ["T"]) { pennant(x: $0, y: $1, color: $2) },
            garland(".color", "알록달록 깃발 줄", "Color garland", "c", ["red", "yellow", "mint", "sky", "pink"]) { pennant(x: $0, y: $1, color: $2) },
            garland(".heart", "하트 줄 장식", "Heart garland", "m", ["T"]) { "\($2) heart \($0) \($1 + 14) 19" },
            garland(".star", "별 줄 장식", "Star garland", "m", ["T"]) { "\($2) star \($0) \($1 + 13) 11 5 5" },
            garland(".round", "동글 깃발 줄", "Round garland", "c", ["pink", "butter", "sky", "mint", "lilac"]) { "\($2) o \($0) \($1 + 11) 9" },
            "deco.dot|점 스티커|Dot|m|T o 50 50 30"
        ] + colorDots.map { "deco.dot.\($0.0)|\($0.1) 점|\($0.2) dot|c|\($0.0) o 50 50 30" }
        return lines.joined(separator: "\n")
    }()

    static let basicMoreSource = #"""
    basic.circle|원|Circle|m|T o 50 50 40
    basic.square|네모|Square|m|T b 12 12 76 76 12
    basic.triangle|세모|Triangle|m|T p 7 50 12 90 84 10 84
    basic.diamond|다이아|Diamond|m|T p 6 50 8 86 50 50 92 14 50
    basic.pentagon|오각형|Pentagon|m|T p 6 50 10 90 40 75 86 25 86 10 40
    basic.hexagon|육각형|Hexagon|m|T p 6 50 8 86 29 86 71 50 92 14 71 14 29
    basic.oval|타원|Oval|m|T e 50 50 42 30
    basic.pill|알약 모양|Pill shape|m|T b 8 30 84 40 20
    basic.half|반원|Half circle|m|T s M8 70 C8 16 92 16 92 70 Q92 74 88 74 L12 74 Q8 74 8 70 Z
    basic.ring|고리|Ring|m|T o 50 50 42;T o 50 50 22
    basic.star4|네 꼭지 별|Four-point star|m|T star 50 50 42 14 4
    basic.star6|여섯 꼭지 별|Six-point star|m|T star 50 50 42 24 6
    basic.star8|여덟 꼭지 별|Eight-point star|m|T star 50 50 42 26 8
    basic.heart.small|작은 하트|Small heart|m|T heart 50 50 50
    basic.heart.two|하트 둘|Two hearts|m|T heart 38 58 50;T heart 70 32 32
    basic.drop|물방울|Drop|m|T s M50 10 C50 10 20 44 20 62 C20 78 33 90 50 90 C67 90 80 78 80 62 C80 44 50 10 50 10 Z
    basic.moon|달|Moon|m|T o 50 50 40;k! o 38 38 6;k! o 62 56 8;k! o 38 68 4
    basic.crescent|초승달|Crescent|m|T s M62 12 C36 14 16 32 16 54 C16 76 38 90 60 88 C72 86 82 80 86 72 C60 78 44 62 46 42 C46 30 52 18 62 12 Z
    basic.cloud|구름|Cloud|m|@deco.cloud 50 54 1 A=T
    basic.cross|십자|Cross|m|T p 5 38 12 62 12 62 38 88 38 88 62 62 62 62 88 38 88 38 62 12 62 12 38 38 38
    basic.cathead|고양이 머리|Cat head|m|@catbase A=T B=T
    basic.paw|발바닥|Paw|m|@paw 50 50 1 A=T
    basic.snow|눈꽃|Snowflake|m|T l 6 50 12 50 88;T l 6 17 31 83 69;T l 6 17 69 83 31;T l 5 40 20 50 30 60 20;T l 5 40 80 50 70 60 80;T l 5 16 44 28 37 24 24;T l 5 84 56 72 63 76 76;T l 5 16 56 28 63 24 76;T l 5 84 44 72 37 76 24
    basic.flower|꽃|Flower|m|T o 50 26 16;T o 73 42 16;T o 64 70 16;T o 36 70 16;T o 27 42 16;T! o 50 50 18;k! o 50 50 8
    basic.clover|네잎|Clover|m|T o 36 36 17;T o 64 36 17;T o 36 64 17;T o 64 64 17;T! o 50 50 14;T l 6 56 60 72 88
    basic.bolt|번개|Bolt|m|T p 3 64 6 16 56 44 56 34 94 86 40 56 40
    basic.arrow|화살표|Arrow|m|@deco.block A=T
    """#

    /// 글자 칸에 들어가는 크기를 어림해 층을 만든다. `/`로 줄을 나눈다.
    private static func phraseLayers(_ text: String, x: Double, y: Double, width: Double, height: Double) -> String {
        let lines = text.split(separator: "/").map(String.init)
        let widest = lines.map { line in
            line.reduce(0.0) { sum, character in
                if character == " " { return sum + 0.3 }
                if character == "-" { return sum + 0.45 }
                return sum + (character.isASCII ? (character.isNumber ? 0.62 : 0.72) : 0.98)
            }
        }.max() ?? 1
        let lineGap = 1.12
        let size = min(width / widest, height / (Double(lines.count) * lineGap)).rounded(.down)
        return lines.enumerated().map { index, line in
            let offset = (Double(index) - Double(lines.count - 1) / 2) * size * lineGap
            return "k t \(x) \(y + offset) \(size) \(line)"
        }.joined(separator: ";")
    }
}
