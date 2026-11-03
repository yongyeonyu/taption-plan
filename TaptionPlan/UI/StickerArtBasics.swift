extension StickerCatalog {
    /// 분류 탭 순서. 저장 값은 스티커 id라 순서를 바꿔도 기록에 영향이 없다.
    static let sources: [(id: String, ko: String, en: String, source: String)] = [
        ("basic", "기본", "Basic", basicSource + "\n" + basicMoreSource),
        ("cats", "고양이", "Cats", catsSource),
        ("mood", "기분", "Mood", moodSource),
        ("weather", "날씨", "Weather", weatherSource),
        ("todo", "일정·할 일", "Plans", todoSource),
        ("food", "음식", "Food", foodSource),
        ("cafe", "카페·간식", "Cafe", cafeSource),
        ("study", "공부", "Study", studySource),
        ("stationery", "문구", "Stationery", stationerySource),
        ("fitness", "운동·건강", "Fitness", fitnessSource),
        ("travel", "여행·교통", "Travel", travelSource),
        ("chores", "집안일", "Chores", choresSource),
        ("money", "돈·가계부", "Money", moneySource),
        ("hobby", "취미", "Hobbies", hobbySource),
        ("places", "장소 기록", "Places", placesSource),
        ("seasons", "계절·행사", "Seasons", seasonsSource),
        ("animals", "동물", "Animals", animalsSource),
        ("plants", "꽃·식물", "Plants", plantsSource),
        ("phrases", "말풍선·글귀", "Phrases", phrasesSource),
        ("dates", "날짜·숫자", "Dates", datesSource),
        ("deco", "장식·테두리", "Decor", decoSource)
    ]

    /// 파츠는 (50,50)을 가운데로 둔다. `A`·`B`·`C`는 쓰는 쪽에서 색을 넘긴다.
    static var partsSource: String {
        [coreParts, catsParts, animalsParts, moodParts, weatherParts, seasonsParts, foodParts, choresParts, todoParts, studyParts, travelParts, fitnessParts, phrasesParts, decoParts].joined(separator: "\n")
    }

    private static let coreParts = #"""
    paw|A e 50 62 15 12;A o 28 44 7;A o 42 32 7;A o 58 32 7;A o 72 44 7
    catbase|A p 4 14 52 16 12 42 26;A p 4 86 52 84 12 58 26;B! p 3 22 34 22 19 34 28;B! p 3 78 34 78 19 66 28;A e 50 56 38 32
    cat.hwarang|@catbase A=w B=pink;pink! e 26 66 6 4;pink! e 74 66 6 4
    cat.chunhyang|@catbase A=w B=pink;orange! s M18 44 C20 28 36 22 46 26 C46 38 36 50 18 44 Z;choco! s M84 46 C82 32 68 22 56 26 C56 38 66 50 84 46 Z;pink! e 26 66 6 4;pink! e 74 66 6 4
    cat.yunbok|@catbase A=tan B=pink;brown! l 4 50 26 50 38;brown! l 4 38 28 40 38;brown! l 4 62 28 60 38;brown! l 4 15 56 23 57;brown! l 4 85 56 77 57;w! e 50 70 15 13
    face.smile|k o 36 54 4.5;k o 64 54 4.5;k q 2.6 44 64 47 68 50 64;k q 2.6 50 64 53 68 56 64
    face.happy|k q 3 29 56 36 47 43 56;k q 3 57 56 64 47 71 56;k q 2.6 44 64 47 68 50 64;k q 2.6 50 64 53 68 56 64
    face.love|red heart 36 53 15;red heart 64 53 15;k q 2.6 44 65 47 69 50 65;k q 2.6 50 65 53 69 56 65
    face.sleep|k q 3 29 53 36 60 43 53;k q 3 57 53 64 60 71 53;k e 50 67 3 2.6
    face.cry|k o 36 54 4.5;k o 64 54 4.5;blue! s M33 60 C28 70 40 72 37 60 Z;blue! s M61 60 C56 70 68 72 65 60 Z;k q 2.6 44 70 50 64 56 70
    face.angry|k l 3 28 46 42 52;k l 3 72 46 58 52;k o 37 57 4;k o 63 57 4;k q 2.6 44 70 50 64 56 70
    face.wow|k o 36 54 5.5;k o 64 54 5.5;w! o 38 52 1.8;w! o 66 52 1.8;k e 50 68 4.5 5.5
    face.wink|k o 36 54 4.5;k q 3 57 56 64 49 71 56;k q 2.6 44 64 47 68 50 64;k q 2.6 50 64 53 68 56 64;red! e 50 69 3.4 4.4
    """#

    /// 앞 6개는 옛 메모에 저장된 SF Symbols 이름을 id로 그대로 쓴다. 바꾸면 옛 기록이 대체 그림으로 바뀐다.
    static let basicSource = #"""
    star.fill|별|Star|m|T star 50 52 42 20 5
    heart.fill|하트|Heart|m|T heart 50 50 80
    flag.fill|깃발|Flag|m|T p 3 32 14 80 30 32 50;k l 6 26 10 26 90
    pin.fill|핀|Pin|m|T o 50 34 24;T p 3 42 54 58 54 50 90;k o 42 26 5
    sparkles|반짝이|Sparkles|m|T star 42 54 36 10 4;T star 76 24 16 5 4;T star 78 76 12 4 4
    basic.memo|메모|Memo|m|T b 20 12 60 76 10;k! l 3.5 32 34 68 34;k! l 3.5 32 50 68 50;k! l 3.5 32 66 54 66
    leaf.fill|나뭇잎|Leaf|m|T s M16 84 C8 40 40 12 86 14 C88 60 60 92 16 84 Z;k l 3 16 84 60 40
    """#
}
