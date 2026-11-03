extension StickerCatalog {
    static let foodParts = #"""
    food.bowl|A b 38 78 24 9 3;A s M14 46 L86 46 C86 70 70 84 50 84 C30 84 14 70 14 46 Z
    food.bread|A s M24 88 L24 48 C8 42 10 14 34 14 L66 14 C90 14 92 42 76 48 L76 88 Z
    food.ears|A p 4 22 36 18 12 42 22;A p 4 78 36 82 12 58 22
    food.ring|A s M50 10 C72 10 90 28 90 50 C90 72 72 90 50 90 C28 90 10 72 10 50 C10 28 28 10 50 10 Z M50 37 C43 37 37 43 37 50 C37 57 43 63 50 63 C57 63 63 57 63 50 C63 43 57 37 50 37 Z
    food.clearcup|A p 5 24 30 76 30 68 90 32 90
    food.steam|A q 5 40 66 32 58 40 50;A q 5 40 50 48 42 40 34;A q 5 60 66 52 58 60 50;A q 5 60 50 68 42 60 34
    food.onigiri|w p 14 50 12 92 84 8 84;dark b 34 62 32 22 3
    """#

    static let choresParts = #"""
    chores.tb|sky b 6 54 88 12 6;w b 12 32 36 22 3;mint! b 12 32 36 11 3;k l 2 21 34 21 54;k l 2 30 34 30 54;k l 2 39 34 39 54
    chores.hammerart|T b 40 34 15 60 7;T s M18 8 L60 8 C74 8 86 20 92 34 C80 30 70 34 60 38 L18 38 Z;k b 12 4 12 38 4
    chores.arrow|A l 12 54 13 69 39;A p 3 80 58 82 30 56 45
    chores.bucketbody|A p 5 20 36 80 36 72 88 28 88
    chores.potbody|A b 20 38 60 46 10;A b 8 46 14 8 4;A b 78 46 14 8 4
    """#

    static let foodSource = #"""
    food.rice|밥|Rice|d|w s M20 48 C20 12 80 12 80 48 Z;@food.bowl A=sky;w! b 26 56 10 4 2;w! b 40 56 10 4 2
    food.soup|국|Soup|d|@food.bowl 50 56 1 A=brown;butter e 50 52 34 9;w! b 36 49 9 6 1;leaf! e 60 53 6 2.5;@food.steam 50 26 0.75 A=w
    food.gimbap|김밥|Gimbap|d|dark o 66 36 24;w o 66 36 18;yellow! b 60 28 12 6 2;orange! b 58 37 7 7 2;leaf! b 67 37 7 7 2;dark o 38 60 30;w o 38 60 23;yellow! b 30 46 16 8 2;orange! b 25 58 11 10 3;leaf! b 39 58 11 10 3;pink! b 31 70 14 7 2
    food.tteokbokki|떡볶이|Tteokbokki|d|w e 50 62 42 26;red! e 50 60 34 19;cream b 22 46 28 12 6 -18;cream b 52 42 28 12 6 14;cream b 30 62 28 12 6 8;orange p 4 58 60 78 58 72 76;leaf! e 44 56 5 2 20;leaf! e 50 50 5 2 -30
    food.ramen|라면|Ramen|d|yellow s M20 48 C22 18 78 18 80 48 Z;k q 2.4 28 46 36 26 44 46;k q 2.4 42 46 50 26 58 46;k q 2.4 56 46 64 26 72 46;choco l 4 58 38 88 8;choco l 4 66 40 92 14;@food.bowl A=red;w! b 28 58 44 5 2;w! o 50 70 5
    food.bibimbap|비빔밥|Bibimbap|d|dark o 50 50 42;w! o 50 50 35;orange! e 32 36 10 7 30;leaf! e 68 36 10 7 -30;red! e 70 62 10 7 30;brown! e 30 62 10 7 -30;mint! e 50 78 10 5;w o 50 48 14;yellow! o 50 48 7
    food.kimchi|김치|Kimchi|c|w e 50 74 42 15;red s M14 68 C8 44 24 34 34 40 C34 20 58 14 64 30 C76 26 92 44 86 68 C70 78 30 78 14 68 Z;cream! b 24 50 11 20 5 12;cream! b 45 38 11 32 5;cream! b 65 48 11 22 5 -12;#B53A36! o 38 56 2;#B53A36! o 60 44 2;#B53A36! o 62 66 2;leaf! e 34 34 6 3 -30;leaf! e 66 24 6 3 30
    food.samgyeopsal|삼겹살|Pork belly|c|#E98F8F b 10 16 80 20 6 -5;cream! b 14 22 72 4 2 -5;#E98F8F b 10 40 80 20 6 -5;cream! b 14 46 72 4 2 -5;#E98F8F b 10 64 80 20 6 -5;cream! b 14 70 72 4 2 -5
    food.chicken|치킨|Fried chicken|d|cream l 10 56 58 76 78;cream o 82 76 7;cream o 76 84 7;orange s M14 40 C14 16 44 8 58 20 C72 32 68 54 56 62 C42 70 14 66 14 40 Z;brown! o 30 34 3;brown! o 46 26 3;brown! o 50 46 3;brown! o 30 52 3
    food.pizza|피자|Pizza|d|yellow p 5 16 26 84 26 50 92;tan b 10 12 80 18 9;red! o 38 44 8;red! o 60 42 8;red! o 49 66 7;leaf! e 62 58 4 2 30
    food.burger|햄버거|Burger|d|tan b 14 64 72 22 9;choco b 12 50 76 16 8;yellow p 3 14 48 86 48 74 60 58 52 42 60 26 52;leaf b 10 42 80 9 4;tan s M14 42 C14 8 86 8 86 42 Z;cream! e 34 26 3 2 -20;cream! e 50 20 3 2;cream! e 66 26 3 2 20
    food.fries|감자튀김|Fries|c|yellow b 26 12 11 50 3 -12;yellow b 44 8 11 50 3 -2;yellow b 60 12 11 50 3 10;yellow b 36 18 11 44 3 -4;yellow b 52 18 11 44 3 5;red s M18 44 Q50 58 82 44 L74 90 L26 90 Z;w! heart 50 72 22
    food.sandwich|샌드위치|Sandwich|d|cream p 6 12 56 88 56 50 12;leaf b 9 54 82 9 4;#F2A0A0 b 12 62 76 8 3;yellow b 12 69 76 7 3;cream b 12 75 76 13 5
    food.pasta|파스타|Pasta|d|tan l 5 72 14 62 44;w e 50 72 42 18;butter e 50 54 30 22;k q 2.4 30 56 40 42 52 52;k q 2.4 42 66 56 52 70 60;red e 50 38 15 8;leaf! e 54 31 5 2.5 -20
    food.sushi|초밥|Sushi|d|w b 18 50 64 32 13;orange s M10 48 C18 24 82 24 90 48 C90 62 10 62 10 48 Z;cream! q 3 28 34 26 44 28 54;cream! q 3 44 30 42 44 44 56;cream! q 3 60 30 58 44 60 56;cream! q 3 74 36 72 44 74 54
    food.mandu|만두|Dumpling|d|cream s M10 70 C10 30 90 30 90 70 C90 84 10 84 10 70 Z;k q 2.6 24 44 28 36 34 42;k q 2.6 36 38 42 30 48 38;k q 2.6 52 38 58 30 64 38;k q 2.6 66 42 72 36 76 44;@face.smile 50 62 0.6
    food.donkatsu|돈까스|Pork cutlet|c|w e 50 66 42 24;green o 76 60 11;green o 70 72 9;orange b 16 34 56 38 12 -8;k l 2.6 30 34 34 68;k l 2.6 44 32 48 68;k l 2.6 58 30 62 66;choco! q 4 20 50 44 42 66 42
    food.curry|카레|Curry|c|sky e 50 54 44 34;w s M14 54 C14 36 34 28 50 30 C54 42 50 64 44 78 C28 78 14 70 14 54 Z;orange s M50 28 C72 28 86 40 86 54 C86 70 66 80 44 78 C52 62 56 42 50 28 Z;brown o 64 44 6;peach o 72 62 6;green o 56 62 5
    food.friedegg|달걀프라이|Fried egg|d|w s M20 22 C38 6 70 10 82 28 C96 48 84 62 78 74 C68 92 40 92 26 78 C8 66 4 36 20 22 Z;yellow o 48 48 19;w! e 42 41 5 3 -30
    food.lunchbox|도시락|Lunch box|c|red b 8 18 84 68 12;cream b 15 25 70 54 7;k l 2.6 50 25 50 79;k l 2.6 50 52 85 52;w! b 18 28 29 48 5;dark! b 25 58 15 15 2;red! o 32 42 6;yellow b 56 30 22 16 4;green o 60 66 8;#E98F8F b 68 58 14 14 5
    food.salad|샐러드|Salad|d|green o 28 40 14;leaf o 50 30 18;green o 72 40 14;red o 38 38 7;yellow o 62 34 6;@food.bowl A=mint;w! b 26 58 10 4 2
    food.toast|토스트|Toast|d|@food.bread A=tan;cream s M30 80 L30 44 C18 40 18 22 36 22 L64 22 C82 22 82 40 70 44 L70 80 Z;butter b 40 38 20 16 3 -10;@face.smile 50 68 0.5
    food.hotdog|핫도그|Hot dog|d|tan b 6 44 88 34 16 -18;red b 4 34 92 22 11 -18;yellow! q 4 18 54 30 34 42 48;yellow! q 4 42 48 54 28 66 38;yellow! q 4 66 38 74 24 84 26;tan b 12 56 76 26 12 -18
    food.taco|타코|Taco|d|leaf o 26 44 12;red o 42 32 11;green o 60 30 12;choco o 76 42 10;yellow s M10 74 C10 18 90 18 90 74 Z;orange! o 34 54 3;orange! o 50 44 3;orange! o 66 54 3;orange! o 50 62 3
    food.apple|사과|Apple|d|choco l 5 50 30 54 12;leaf s M54 22 C60 8 78 8 84 14 C78 28 62 28 54 22 Z;red s M50 30 C30 14 10 30 12 56 C14 82 36 96 50 86 C64 96 86 82 88 56 C90 30 70 14 50 30 Z
    food.banana|바나나|Banana|d|yellow s M18 16 C14 50 40 90 86 80 C92 78 90 70 86 68 C62 68 42 46 32 14 C30 8 20 10 18 16 Z;choco b 16 8 15 10 3;choco! o 87 75 3.5
    food.strawberry|딸기|Strawberry|d|red s M50 92 C20 72 8 46 20 28 C34 18 66 18 80 28 C92 46 80 72 50 92 Z;butter! e 34 42 2 3;butter! e 50 40 2 3;butter! e 66 42 2 3;butter! e 42 56 2 3;butter! e 58 56 2 3;butter! e 50 72 2 3;leaf star 50 24 24 9 5 36
    food.grape|포도|Grapes|d|choco l 5 50 24 54 10;leaf s M54 18 C62 6 80 8 84 14 C78 26 62 26 54 18 Z;purple o 28 34 13;purple o 50 34 13;purple o 72 34 13;purple o 38 54 13;purple o 62 54 13;purple o 50 74 13;w! o 24 30 3;w! o 46 30 3;w! o 68 30 3;w! o 34 50 3;w! o 58 50 3;w! o 46 70 3
    food.tangerine|귤|Tangerine|d|orange o 50 54 37;choco! o 50 22 4;leaf s M52 20 C60 8 76 8 82 14 C76 26 60 26 52 20 Z;#D97F30! o 34 50 1.8;#D97F30! o 50 66 1.8;#D97F30! o 66 50 1.8;#D97F30! o 42 72 1.8;#D97F30! o 62 72 1.8
    food.watermelon|수박|Watermelon|c|leaf s M8 30 L92 30 C92 98 8 98 8 30 Z;w! s M15 30 L85 30 C85 88 15 88 15 30 Z;red! s M20 30 L80 30 C80 80 20 80 20 30 Z;k e 36 44 2.4 3.4;k e 50 56 2.4 3.4;k e 64 44 2.4 3.4;k e 42 64 2.4 3.4;k e 58 66 2.4 3.4
    food.peach|복숭아|Peach|d|leaf s M50 22 C40 6 22 8 18 14 C24 28 42 30 50 22 Z;pink s M50 24 C24 12 8 34 12 56 C16 80 38 92 50 88 C62 92 84 80 88 56 C92 34 76 12 50 24 Z;rose! q 3 50 26 42 56 50 86;rose! e 26 62 8 6;rose! e 74 62 8 6
    food.cherry|체리|Cherry|d|leaf q 3 34 54 42 26 66 12;leaf q 3 68 58 70 32 66 12;leaf s M66 12 C74 4 88 8 90 16 C82 24 72 22 66 12 Z;red o 32 66 22;red o 68 70 22;w! e 26 58 5 3 -30;w! e 62 62 5 3 -30
    food.lemon|레몬|Lemon|d|yellow o 14 62 6;yellow o 86 38 6;yellow e 50 50 38 28 -18;leaf s M60 24 C64 10 80 8 88 12 C84 26 70 30 60 24 Z;w! e 36 40 7 4 -30
    food.carrot|당근|Carrot|d|leaf s M50 34 C36 28 28 14 32 8 C42 8 50 18 50 34 Z;leaf s M50 34 C64 28 72 14 68 8 C58 8 50 18 50 34 Z;green s M50 34 C44 22 44 12 50 6 C56 12 56 22 50 34 Z;orange p 10 24 30 76 30 50 94;#D97F30! l 3 32 46 50 46;#D97F30! l 3 54 58 66 58;#D97F30! l 3 40 68 52 68
    food.broccoli|브로콜리|Broccoli|d|#A8D98F p 5 40 50 60 50 66 90 34 90;green o 28 42 18;green o 72 42 18;green o 50 28 20;green o 50 50 17;leaf! o 28 40 3;leaf! o 48 24 3;leaf! o 70 40 3;leaf! o 54 50 3
    food.tomato|토마토|Tomato|d|red o 50 54 38;leaf star 50 24 22 7 5 36;choco! o 50 24 3;w! e 28 46 5 8 20
    food.corn|옥수수|Corn|d|yellow e 50 40 23 34;orange! o 42 22 2.2;orange! o 58 22 2.2;orange! o 38 36 2.2;orange! o 50 34 2.2;orange! o 62 36 2.2;orange! o 42 48 2.2;orange! o 58 48 2.2;green s M50 90 C22 88 12 62 22 44 C34 52 46 66 50 90 Z;leaf s M50 90 C78 88 88 62 78 44 C66 52 54 66 50 90 Z
    food.sweetpotato|고구마|Sweet potato|d|#A0527C e 46 56 38 24 -25;butter e 76 36 12 15 -25;orange! e 76 36 6 8 -25;#7D3D60! l 3 26 54 40 64;#7D3D60! l 3 40 42 54 52;@food.steam 36 20 0.55 A=w
    food.milk|우유|Milk|c|sky b 34 8 32 10 2;sky p 3 24 40 76 40 66 16 34 16;w b 24 38 52 54 5;sky! b 24 72 52 14 0;k t 50 58 18 우유
    food.beer|맥주|Beer|c|butter q 8 66 44 92 58 66 76;orange b 18 30 50 60 8;butter! b 26 40 6 42 3;butter! b 40 40 6 42 3;butter! b 54 40 6 42 3;w o 24 28 11;w o 42 22 13;w o 60 28 11
    food.wine|와인|Wine|c|w s M26 10 L74 10 C76 40 64 54 50 54 C36 54 24 40 26 10 Z;red! s M29 26 L71 26 C71 42 61 51 50 51 C39 51 29 42 29 26 Z;gray l 6 50 54 50 84;gray b 30 82 40 8 4
    food.sojuglass|소주잔|Soju glass|c|w p 5 24 22 76 22 68 88 32 88;sky! p 4 29 44 71 44 64 83 36 83;w! b 36 50 5 26 2
    food.sojubottle|소주병|Soju bottle|c|green b 38 8 24 12 3;green s M41 16 L59 16 L59 30 C70 36 72 44 72 50 L72 86 Q72 92 66 92 L34 92 Q28 92 28 86 L28 50 C28 44 30 36 41 30 Z;w! b 32 54 36 24 3;#A8D98F! b 34 28 5 20 2
    food.catonigiri|고양이 주먹밥|Cat rice ball|d|w p 4 36 32 28 8 50 18;w p 4 64 32 72 8 50 18;w p 14 50 14 92 86 8 86;pink! e 30 62 5 3;pink! e 70 62 5 3;@face.smile 50 54 0.7;dark b 34 70 32 16 3
    food.onigiri|주먹밥|Rice ball|d|@food.onigiri;w! e 40 30 4 6 30
    food.boiledegg|삶은 달걀|Boiled egg|d|w s M50 10 C72 10 86 44 86 60 C86 80 70 90 50 90 C30 90 14 80 14 60 C14 44 28 10 50 10 Z;yellow o 50 60 19;orange! o 50 60 7
    food.tofu|두부|Tofu|d|w p 4 10 38 34 18 90 18 66 38;cream p 4 66 38 90 18 90 62 66 84;w b 10 36 56 48 5;@face.happy 38 62 0.6
    food.fish|생선구이|Grilled fish|c|w e 50 70 42 18;sky s M12 50 C24 24 58 24 70 48 L88 34 L86 66 L70 54 C58 76 24 76 12 50 Z;k o 28 46 3.5;k q 2.6 44 34 48 50 44 64;k q 2.6 56 38 60 50 56 60
    food.shrimp|새우|Shrimp|d|orange s M72 18 C40 12 14 34 16 58 C18 80 44 92 62 82 L86 92 L80 72 C72 72 58 74 46 66 C38 58 44 42 70 40 C78 38 82 22 72 18 Z;k o 68 28 3;k l 2.4 32 28 42 44;k l 2.4 18 50 36 54;k l 2.4 26 74 42 62
    food.tempura|새우튀김|Shrimp tempura|d|red p 4 70 30 72 8 92 28;butter o 26 74 12;butter o 42 62 12;butter o 56 50 12;butter o 68 38 11;butter o 36 78 10;butter o 18 62 10;butter o 30 50 10;butter o 46 38 10;butter o 62 26 9;butter! b 14 42 66 26 13 -42;tan! o 34 64 3;tan! o 48 52 3;tan! o 60 40 3;tan! o 40 46 2.4;tan! o 54 62 2.4
    food.mushroom|버섯|Mushroom|d|cream b 36 48 28 42 12;brown s M10 54 C10 8 90 8 90 54 Q90 60 82 60 L18 60 Q10 60 10 54 Z;w! o 34 34 6;w! o 60 28 5;w! o 70 46 4
    food.lettuce|상추|Lettuce|d|green s M50 92 C24 84 6 62 12 40 C8 22 28 16 34 18 C40 6 60 6 66 18 C76 16 92 24 88 40 C94 62 76 84 50 92 Z;w! q 3 50 88 50 60 50 30;w! q 3 50 66 36 56 28 40;w! q 3 50 66 64 56 72 40
    food.cucumber|오이|Cucumber|d|leaf b 8 34 84 32 16 -30;#A8D98F e 72 34 11 15 -30;#D5EEC0! e 72 34 6 9 -30
    food.onion|양파|Onion|d|tan q 4 50 26 46 14 40 8;tan q 4 50 26 54 14 60 8;butter s M50 20 C70 34 88 44 86 62 C84 82 66 88 50 88 C34 88 16 82 14 62 C12 44 30 34 50 20 Z;tan! q 2.6 40 40 26 60 38 82;tan! q 2.6 60 40 74 60 62 82;tan! l 2.6 50 34 50 84
    food.garlic|마늘|Garlic|d|cream s M50 8 C54 18 56 22 62 28 C80 40 86 54 84 68 C80 86 60 90 50 88 C40 90 20 86 16 68 C14 54 20 40 38 28 C44 22 46 18 50 8 Z;tan! q 2.6 40 34 28 62 42 84;tan! q 2.6 60 34 72 62 58 84
    food.chili|고추|Chili pepper|d|leaf s M20 16 C28 8 42 12 44 24 C38 32 26 30 20 16 Z;red s M28 22 C44 16 54 28 62 44 C70 60 80 76 90 88 C62 86 28 60 28 22 Z
    food.eggplant|가지|Eggplant|d|purple s M60 26 C80 36 88 60 78 78 C66 96 36 92 22 76 C14 64 22 54 36 48 C46 44 50 34 60 26 Z;leaf p 5 52 32 72 12 82 22 74 38 62 40;#C2B4E9! e 38 68 6 10 50
    food.avocado|아보카도|Avocado|d|leaf s M50 8 C62 8 66 28 74 42 C86 62 80 92 50 92 C20 92 14 62 26 42 C34 28 38 8 50 8 Z;#D5EE9A! s M50 16 C58 16 60 32 68 44 C78 60 74 84 50 84 C26 84 22 60 32 44 C40 32 42 16 50 16 Z;brown o 50 62 14;w! e 46 58 3 2 -30
    food.pear|배|Pear|d|choco l 5 50 24 54 8;yellow s M50 20 C64 20 62 38 72 50 C88 68 76 92 50 92 C24 92 12 68 28 50 C38 38 36 20 50 20 Z;w! e 36 62 5 8 20;tan! o 44 76 1.6;tan! o 60 66 1.6;tan! o 58 80 1.6
    food.pineapple|파인애플|Pineapple|d|leaf e 34 24 6 16 -35;leaf e 66 24 6 16 35;green e 50 20 8 17;yellow e 50 62 29 30;orange! l 2.4 30 44 66 88;orange! l 2.4 50 34 78 70;orange! l 2.4 70 44 34 88;orange! l 2.4 50 34 22 70
    food.kiwi|키위|Kiwi|d|brown o 50 50 40;#A8D98F! o 50 50 33;cream! o 50 50 10;k! e 50 30 2 3;k! e 50 70 2 3;k! e 30 50 3 2;k! e 70 50 3 2;k! e 36 36 2.4 2.4;k! e 64 36 2.4 2.4;k! e 36 64 2.4 2.4;k! e 64 64 2.4 2.4
    food.cheese|치즈|Cheese|d|yellow p 5 10 50 72 18 90 50 90 82 10 82;orange! o 30 64 7;orange! o 58 70 5;orange! o 70 50 6;orange! o 46 50 3
    food.bacon|베이컨|Bacon|c|#C9565A s M20 12 C36 22 28 34 36 48 C44 62 30 74 36 90 L60 90 C54 74 68 62 60 48 C52 34 60 22 44 12 Z;cream! q 4 32 18 42 32 40 48;cream! q 4 40 48 50 62 44 84
    food.steak|스테이크|Steak|c|w e 50 70 42 20;#A85040 s M16 44 C14 22 44 18 62 22 C82 26 88 42 84 56 C78 74 60 70 44 68 C30 66 18 62 16 44 Z;cream! q 4 22 44 42 28 74 34;k l 2.4 34 44 46 58;k l 2.4 48 40 60 54;k l 2.4 62 40 72 52
    food.eomuk|어묵꼬치|Fish cake skewer|d|tan l 5 50 8 50 92;butter b 22 14 56 18 8;butter b 28 32 44 18 8;butter b 22 50 56 18 8;tan! e 50 22 10 3;tan! e 50 40 8 3;tan! e 50 58 10 3
    food.sausage|소시지|Sausage|d|red b 14 34 72 32 16 -30;w! q 3 34 52 46 38 62 30;k l 3 18 72 8 84;k l 3 82 28 92 16
    food.jajangmyeon|짜장면|Black bean noodles|c|@food.bowl A=w;yellow s M18 46 C18 26 82 26 82 46 Z;choco s M28 42 C24 14 76 14 72 42 Z;leaf! b 44 18 12 4 2;cream! e 56 28 4 3;peach! e 40 32 4 3
    food.tteokguk|떡국|Rice cake soup|d|@food.bowl A=sky;cream e 50 46 36 10;w e 36 45 8 5;w e 52 42 8 5;w e 64 47 8 5;yellow! b 42 47 10 3 1;leaf! b 28 42 6 2 1
    food.jjigae|찌개|Stew pot|d|choco b 4 42 14 8 4;choco b 82 42 14 8 4;dark s M14 38 L86 38 L82 80 Q80 88 72 88 L28 88 Q20 88 18 80 Z;red e 50 38 36 9;w! b 34 34 10 7 1;leaf! e 58 38 7 2.5;@food.steam 50 16 0.6 A=w
    food.jeon|전|Korean pancake|d|butter o 50 52 40;leaf! l 5 30 34 44 60;leaf! l 5 50 28 62 54;leaf! l 5 36 58 44 72;red! e 62 66 7 3 -30;tan! o 28 54 3;tan! o 72 42 3
    food.loaf|식빵|Loaf|d|@food.bread A=tan;cream s M30 80 L30 44 C18 40 18 22 36 22 L64 22 C82 22 82 40 70 44 L70 80 Z
    food.catbread|고양이 식빵|Cat loaf|d|tan p 4 24 34 22 10 42 20;tan p 4 76 34 78 10 58 20;tan s M14 88 L14 50 C14 16 86 16 86 50 L86 88 Z;cream! s M22 82 L22 50 C22 26 78 26 78 50 L78 82 Z;pink! e 34 66 5 3;pink! e 66 66 5 3;@face.smile 50 58 0.7
    food.catbox|고양이 도시락|Cat lunch box|c|navy p 4 20 36 18 16 36 24;navy p 4 80 36 82 16 64 24;navy b 8 22 84 66 14;cream b 15 29 70 52 8;w p 6 32 34 50 58 14 58;dark! b 26 48 12 10 1;yellow o 64 44 10;orange! o 64 44 4;green o 40 70 8;red o 62 70 8
    food.honey|꿀단지|Honey pot|d|choco! q 4 62 8 70 16 76 8;butter e 50 60 34 32;orange b 28 22 44 14 5;orange! s M26 36 L74 36 C74 54 66 50 62 44 C58 54 50 58 46 46 C42 54 34 50 26 36 Z;w! e 32 62 4 8
    food.m.bowl|밥그릇|Rice bowl|m|T s M20 48 C20 12 80 12 80 48 Z;@food.bowl A=T
    food.m.utensil|수저|Spoon and chopsticks|m|T e 32 24 13 16;T b 28 34 8 56 4;T b 58 8 8 84 4;T b 72 8 8 84 4
    food.m.fork|포크와 나이프|Fork and knife|m|T s M22 10 L22 34 L18 34 L18 10 Z;T b 18 10 6 30 3;T b 28 10 6 30 3;T b 38 10 6 30 3;T b 18 32 26 14 6;T b 26 40 10 50 5;T s M62 12 C78 18 80 44 74 54 L68 54 L68 88 Q68 90 64 90 Q60 90 60 88 L60 16 Q60 10 62 12 Z
    food.m.apple|사과 한 알|Apple solid|m|T s M50 30 C30 14 10 30 12 56 C14 82 36 96 50 86 C64 96 86 82 88 56 C90 30 70 14 50 30 Z;T s M54 22 C60 8 78 8 84 14 C78 28 62 28 54 22 Z;k q 3 50 30 50 20 54 12
    food.m.fish|생선|Fish solid|m|T s M10 50 C22 22 58 22 70 46 L90 30 L88 70 L70 54 C58 78 22 78 10 50 Z;k o 28 44 4;k q 3 44 34 50 50 44 66
    food.m.egg|달걀|Egg solid|m|T s M50 10 C72 10 86 44 86 60 C86 80 70 90 50 90 C30 90 14 80 14 60 C14 44 28 10 50 10 Z;@face.smile 50 58 0.7
    food.m.carrot|당근 한 개|Carrot solid|m|T s M50 34 C36 28 28 14 32 8 C42 8 50 18 50 34 Z;T s M50 34 C64 28 72 14 68 8 C58 8 50 18 50 34 Z;T p 10 24 30 76 30 50 94;k l 3 34 46 50 46;k l 3 52 60 64 60
    food.m.onigiri|삼각김밥|Triangle rice ball|m|T p 14 50 12 92 84 8 84;k b 36 60 28 24 3
    food.m.chef|요리 모자|Chef hat|m|T o 30 36 18;T o 70 36 18;T o 50 28 22;T b 26 36 48 34 3;T b 26 72 48 16 4;k l 3 26 72 74 72
    food.m.fridge|냉장고|Fridge|m|T b 24 8 52 84 10;k l 3 24 38 76 38;k b 32 22 5 12 2;k b 32 46 5 18 2
    food.m.pizza|피자 한 조각|Pizza solid|m|T p 5 16 26 84 26 50 92;T b 10 12 80 18 9;k o 38 44 6;k o 60 42 6;k o 49 66 5
    food.m.burger|버거|Burger solid|m|T s M14 42 C14 8 86 8 86 42 Z;T b 10 44 80 10 5;T b 14 56 72 10 5;T b 14 68 72 18 8
    food.m.cherry|체리 한 쌍|Cherry solid|m|k q 3 34 54 42 26 66 12;k q 3 68 58 70 32 66 12;T s M66 12 C74 4 88 8 90 16 C82 24 72 22 66 12 Z;T o 32 66 22;T o 68 70 22
    food.m.grocery|장 볼 것|Grocery list|m|T b 18 12 64 78 8;k l 4 30 34 70 34;k l 4 30 50 70 50;k l 4 30 66 56 66;@paw 72 76 0.36 A=k
    """#

    static let cafeSource = #"""
    cafe.icecoffee|아이스 커피|Iced coffee|c|gray l 6 56 30 66 6;@food.clearcup A=#EDE3D6;choco! p 4 28 42 72 42 66 86 34 86;w b 34 46 14 14 3 -12;w b 50 52 14 14 3 14;w b 38 64 12 12 3 8;w b 22 24 56 9 4
    cafe.hotcoffee|따뜻한 커피|Hot coffee|c|@food.steam 44 18 0.7 A=w;w q 9 70 44 92 58 70 74;w b 14 34 60 54 12;choco! e 44 40 26 4;brown! heart 44 66 24
    cafe.latte|라테아트|Latte art|c|w o 50 50 42;w b 84 44 12 12 5;tan! o 50 50 33;cream! heart 50 52 38;tan! heart 50 49 18
    cafe.teacup|찻잔|Teacup|c|sky e 46 82 38 8;w q 8 70 44 90 54 68 68;w s M14 36 L78 36 C78 62 66 78 46 78 C26 78 14 62 14 36 Z;peach! e 46 40 28 4;leaf! e 46 62 8 4 -20;@food.steam 46 18 0.55 A=w
    cafe.teapot|찻주전자|Teapot|d|w q 7 74 44 94 54 76 72;mint s M26 48 L8 32 L8 44 L26 66 Z;mint e 50 60 28 28;mint b 34 26 32 8 4;mint o 50 20 6;w! e 40 52 4 8 20
    cafe.tumbler|텀블러|Tumbler|c|gray b 30 8 40 16 5;lilac b 26 22 48 70 9;w! b 26 48 48 12 0;@paw 50 54 0.2 A=k;w! b 34 30 5 12 2
    cafe.bubbletea|버블티|Bubble tea|c|rose b 56 4 8 34 3 12;@food.clearcup A=#EFE3CF;tan! p 4 28 38 72 38 66 86 34 86;choco o 38 76 5;choco o 50 78 5;choco o 62 76 5;choco o 44 66 5;choco o 57 66 5;w s M20 30 C20 12 80 12 80 30 Z;w b 18 28 64 7 3
    cafe.smoothie|스무디|Smoothie|c|leaf l 6 56 28 65 10;@food.clearcup A=rose;w! b 32 42 5 34 2;w s M20 30 C20 12 80 12 80 30 Z;w b 18 28 64 7 3;red o 50 58 9;leaf! e 50 49 5 2
    cafe.juice|주스|Juice|c|rose l 5 40 34 30 8;@food.clearcup A=orange;w! b 32 36 5 34 2;yellow o 76 26 14;orange! o 76 26 9;k! l 1.4 76 18 76 34;k! l 1.4 68 26 84 26
    cafe.milkshake|밀크셰이크|Milkshake|c|red l 6 58 26 68 6;w o 36 28 13;w o 62 28 13;w o 50 18 12;red o 50 8 5;@food.clearcup A=pink;w b 20 32 60 7 3
    cafe.lemonade|레모네이드|Lemonade|c|@food.clearcup 46 50 1 A=#FFF3B8;yellow e 46 54 14 14;w! o 46 54 9;yellow! o 46 54 7;w b 30 66 12 12 3 12;w b 48 68 12 12 3 -12;green! e 76 22 8 4 -20;k l 3 62 30 72 8
    cafe.cake|케이크 조각|Cake slice|d|cream p 5 8 56 62 26 92 42 92 84 8 84;w p 4 8 56 62 26 92 42 40 60;rose! p 3 10 66 92 54 92 62 10 74;red o 62 30 9;leaf! e 64 20 4 2 20
    cafe.wholecake|홀케이크|Whole cake|d|cream e 50 80 40 12;pink b 12 42 76 38 12;w e 50 44 38 12;rose! q 4 14 52 22 64 30 52;rose! q 4 32 54 40 66 50 54;rose! q 4 50 54 60 66 68 54;rose! q 4 68 52 78 62 86 50;red o 34 42 5;red o 50 40 5;red o 66 42 5;yellow b 47 18 6 20 2;orange! e 50 12 4 6
    cafe.cupcake|컵케이크|Cupcake|d|sky p 5 22 54 78 54 68 90 32 90;navy! l 2.4 40 56 44 88;navy! l 2.4 60 56 56 88;w o 34 44 14;w o 66 44 14;w o 50 32 18;rose! o 38 38 2.2;yellow! o 60 40 2.2;mint! o 50 26 2.2;red o 50 14 7
    cafe.donut|도넛|Donut|d|@food.ring A=tan;@food.ring 50 50 0.86 A=rose;yellow! l 3 30 28 34 34;mint! l 3 56 22 62 24;w! l 3 72 38 70 44;sky! l 3 24 46 30 44;yellow! l 3 44 22 42 28;mint! l 3 30 66 34 62;w! l 3 62 72 66 76
    cafe.cookie|쿠키|Cookie|d|tan s M50 10 C72 10 90 28 90 50 C90 72 72 90 50 90 C28 90 10 72 10 50 C10 36 18 22 30 16 C30 26 40 28 44 22 C44 18 46 12 50 10 Z;choco o 36 44 6;choco o 62 36 6;choco o 66 62 6;choco o 42 68 6;choco! o 52 52 3
    cafe.pawcookie|발바닥 쿠키|Paw cookie|d|tan o 50 50 42;choco e 50 60 15 12;choco o 30 42 7;choco o 43 30 7;choco o 57 30 7;choco o 70 42 7
    cafe.macaron|마카롱|Macaron|d|pink s M12 42 C12 12 88 12 88 42 Z;cream b 16 42 68 12 5;pink s M12 54 L88 54 C88 86 12 86 12 54 Z;w! e 34 26 8 3 -15
    cafe.croissant|크루아상|Croissant|d|orange s M8 72 C6 30 44 12 50 12 C56 12 94 30 92 72 C90 80 80 80 76 72 C72 58 62 50 50 50 C38 50 28 58 24 72 C20 80 10 80 8 72 Z;brown! q 3 20 36 28 48 26 62;brown! q 3 36 20 40 36 38 52;brown! q 3 64 20 60 36 62 52;brown! q 3 80 36 72 48 74 62;butter! e 50 26 7 3
    cafe.waffle|와플|Waffle|d|butter b 10 14 80 72 14;tan b 16 20 68 60 9;k l 2.6 39 20 39 80;k l 2.6 61 20 61 80;k l 2.6 16 40 84 40;k l 2.6 16 60 84 60;yellow b 40 30 20 16 3 -10;w o 66 66 8
    cafe.pancake|팬케이크|Pancakes|d|w e 50 80 42 11;tan b 16 62 68 16 8;tan b 12 46 76 18 9;tan b 16 30 68 18 9;choco! s M22 34 L78 34 L78 44 C74 54 70 50 68 44 C64 40 60 60 54 44 C50 40 46 44 42 44 C36 56 30 50 28 44 C24 40 22 40 22 34 Z;yellow b 40 20 20 13 3
    cafe.pudding|푸딩|Pudding|d|w e 50 84 42 8;yellow p 8 30 28 70 28 80 84 20 84;choco s M30 24 L70 24 L72 38 C66 48 62 40 58 38 C54 48 46 48 42 38 C38 42 32 48 28 38 Z;red o 50 16 7;@face.smile 50 60 0.6
    cafe.icecream|아이스크림|Ice cream cup|d|pink o 50 36 24;w o 30 42 14;mint o 70 42 14;sky p 5 18 50 82 50 70 90 30 90;w! l 4 36 66 64 66;tan b 62 8 8 26 3 20
    cafe.softcone|소프트콘|Soft-serve cone|d|tan p 6 30 56 70 56 50 94;brown! l 2.4 38 60 54 82;brown! l 2.4 62 60 46 82;w e 50 50 26 11;w e 50 36 20 10;w e 50 24 13 8;w p 3 44 18 56 18 48 6
    cafe.bingsu|빙수|Shaved ice|d|sky p 5 14 56 86 56 72 88 28 88;w s M14 56 C14 28 34 14 50 14 C66 14 86 28 86 56 Z;rose! s M28 40 C34 20 66 20 72 40 C64 48 36 48 28 40 Z;red o 44 26 6;red o 60 30 6;choco! o 36 44 3;choco! o 50 46 3;choco! o 64 44 3
    cafe.bungeoppang|붕어빵|Fish bread|d|tan s M10 50 C20 22 56 20 72 44 L92 28 L88 72 L72 58 C56 80 20 78 10 50 Z;k o 26 44 3.5;brown! q 3 42 32 48 50 42 68;brown! q 3 54 36 60 50 54 64;brown! e 34 62 5 2.5
    cafe.hotteok|호떡|Sweet pancake|d|tan e 50 58 40 32;brown! e 50 58 30 23;tan! e 50 58 22 16;choco! o 42 54 3;choco! o 58 62 3;choco! o 52 48 3;@food.steam 50 12 0.42 A=w
    cafe.chocolate|초콜릿|Chocolate bar|d|red p 3 18 54 82 54 82 92 18 92;choco b 22 8 56 48 6;brown! b 28 14 19 16 3;brown! b 53 14 19 16 3;brown! b 28 34 19 16 3;brown! b 53 34 19 16 3;w! b 18 60 64 6 0
    cafe.candy|사탕|Candy|d|rose p 5 8 34 26 44 26 58 8 68;rose p 5 92 34 74 44 74 58 92 68;pink o 50 50 26;rose! q 5 32 42 50 34 66 48;rose! q 5 34 60 50 52 68 60
    cafe.lollipop|막대사탕|Lollipop|d|w b 46 54 8 40 4;yellow o 50 34 26;orange! q 5 30 38 34 16 50 16;orange! q 5 50 16 68 22 66 40;orange! q 5 66 40 54 48 42 40;orange! q 5 42 40 40 28 54 30
    cafe.jelly|젤리|Gummy|d|mint p 4 24 34 22 12 40 22;mint p 4 76 34 78 12 60 22;mint e 50 56 36 36;rose p 4 8 90 12 70 26 82;w! e 36 40 6 4 -20;@face.smile 50 54 0.7
    cafe.jellycube|과일 젤리|Fruit jelly|d|rose p 7 14 26 86 26 76 88 24 88;red! e 50 26 36 4;w! b 26 38 5 34 2;cream o 50 58 11;leaf! e 50 47 6 2.5
    cafe.chips|감자칩|Potato chips|c|yellow s M18 10 L82 10 L78 28 L80 72 L84 90 L16 90 L20 72 L22 28 Z;orange! b 20 12 60 10 0;orange! b 20 78 60 10 0;butter o 50 50 21;tan! o 42 44 2;tan! o 58 58 2;tan! o 54 40 2;@face.happy 50 53 0.42
    cafe.popcorn|팝콘|Popcorn|c|butter o 32 28 12;w o 50 18 13;butter o 68 28 12;w o 42 34 11;w o 60 36 11;w p 3 20 40 80 40 70 92 30 92;red! p 3 20 40 32 40 36 92 30 92;red! p 3 44 40 56 40 54 92 46 92;red! p 3 68 40 80 40 70 92 64 92
    cafe.catmug|고양이 귀 머그|Cat ear mug|c|w q 9 72 44 92 58 72 74;w p 4 18 28 16 12 36 22;w p 4 76 28 78 12 58 22;w b 14 22 64 66 14;pink! e 26 62 5 3;pink! e 66 62 5 3;@face.smile 46 54 0.75
    cafe.catlatte|고양이 라테|Cat latte|c|w o 50 50 42;tan! o 50 50 33;cream! p 4 30 40 28 22 44 32;cream! p 4 70 40 72 22 56 32;cream! e 50 54 22 19;@face.smile 50 54 0.6
    cafe.bean|커피콩|Coffee beans|d|brown e 34 62 22 16 -30;choco! q 3 16 72 34 60 52 52;choco e 64 36 22 16 -40;k! q 3 48 52 64 34 80 20
    cafe.rollcake|롤케이크|Roll cake|d|tan b 10 28 80 46 22;cream o 70 51 21;tan o 70 51 21;cream o 70 51 15;rose! q 4 60 50 68 40 78 50;rose! q 4 78 50 72 60 64 54
    cafe.tiramisu|티라미수|Tiramisu|d|cream b 14 26 72 60 8;choco! b 14 26 72 12 6;tan! b 14 46 72 8 0;tan! b 14 66 72 8 0;w o 50 22 6;leaf! e 54 16 4 2 20
    cafe.bagel|베이글|Bagel|d|@food.ring A=orange;cream! o 34 26 2.4;cream! o 58 22 2.4;cream! o 76 40 2.4;cream! o 24 54 2.4;cream! o 44 76 2.4;cream! o 72 68 2.4
    cafe.muffin|머핀|Muffin|d|w p 5 22 54 78 54 70 90 30 90;tan! l 2.4 40 56 44 88;tan! l 2.4 60 56 56 88;brown s M14 52 C10 16 90 16 86 52 C86 62 14 62 14 52 Z;choco! o 34 38 3.5;choco! o 54 30 3.5;choco! o 66 44 3.5;choco! o 44 48 3
    cafe.dango|경단 꼬치|Rice cake skewer|d|tan l 5 18 88 82 12;pink o 66 30 15;w o 48 50 15;leaf o 30 70 15
    cafe.m.coffee|커피 한 잔|Coffee solid|m|@food.steam 44 18 0.7 A=T;T q 9 70 46 92 60 70 76;T b 14 36 60 52 12;k heart 44 62 20
    cafe.m.togo|테이크아웃 컵|To-go cup|m|T p 5 24 28 76 28 68 92 32 92;T b 20 18 60 12 5;T b 30 8 40 12 4;k l 3 28 50 72 50;k l 3 30 72 70 72
    cafe.m.donut|도넛 한 개|Donut solid|m|@food.ring A=T;k l 3 28 28 32 32;k l 3 68 26 72 22;k l 3 74 54 78 58;k l 3 32 72 36 68;k l 3 56 76 60 80
    cafe.m.cookie|쿠키 한 개|Cookie solid|m|T s M50 10 C72 10 90 28 90 50 C90 72 72 90 50 90 C28 90 10 72 10 50 C10 36 18 22 30 16 C30 26 40 28 44 22 C44 18 46 12 50 10 Z;k o 36 44 5;k o 62 36 5;k o 66 62 5;k o 42 68 5
    cafe.m.cake|조각 케이크|Cake solid|m|T p 5 8 56 62 26 92 42 92 84 8 84;k l 3 10 68 92 56;T o 62 26 9
    cafe.m.softcone|콘 아이스크림|Cone solid|m|T p 6 30 56 70 56 50 94;T e 50 48 26 11;T e 50 34 20 10;T e 50 22 13 8;k l 2.4 40 62 54 80;k l 2.4 60 62 46 80
    cafe.m.candy|사탕 한 알|Candy solid|m|T p 5 8 34 26 44 26 58 8 68;T p 5 92 34 74 44 74 58 92 68;T o 50 50 26;k q 3 36 44 50 36 64 48
    cafe.m.pawmug|발바닥 머그|Paw mug|m|T q 9 70 46 92 60 70 76;T b 14 26 60 62 12;@paw 44 56 0.5 A=k
    """#

    static let choresSource = #"""
    chores.washer|세탁기|Washing machine|c|w b 14 8 72 84 10;gray! b 14 8 72 18 8;k o 26 17 3;k o 38 17 3;sky o 50 58 25;blue! s M28 60 C38 52 44 68 50 60 C56 52 64 68 72 60 C70 74 60 80 50 80 C40 80 30 74 28 60 Z;w! e 40 46 5 3 -30
    chores.laundry|빨래 바구니|Laundry basket|m|T b 22 12 26 26 8 -15;T b 50 10 28 28 8 15;T p 5 12 34 88 34 78 90 22 90;k l 3 36 46 38 80;k l 3 50 46 50 80;k l 3 64 46 62 80
    chores.rack|건조대|Drying rack|m|T b 10 18 80 8 4;k l 5 20 26 12 88;k l 5 80 26 88 88;T p 3 28 26 44 26 44 58 28 58;T p 3 54 26 74 26 74 50 54 50;k l 3 16 62 84 62
    chores.iron|다림질|Iron|m|T s M8 76 C10 48 30 32 58 32 L88 32 L88 76 Z;k q 6 40 32 50 14 80 16;k l 6 80 16 84 32;k o 28 62 3;k o 44 62 3;k o 60 62 3
    chores.vacuum|청소기|Vacuum cleaner|c|gray l 7 62 12 40 72;gray b 24 66 40 14 5;dark b 16 76 56 10 5;red e 72 52 20 26;dark o 74 76 7;w! e 66 42 4 8 20;dark l 7 62 12 74 8
    chores.broom|빗자루|Broom|m|T l 7 76 8 44 52;T p 5 36 44 54 60 40 90 10 76;k l 3 34 56 22 78;k l 3 42 62 30 84
    chores.mop|걸레|Mop|m|T l 7 50 8 50 56;T b 26 48 48 10 4;T b 24 58 11 32 5;T b 37 58 11 34 5;T b 52 58 11 34 5;T b 65 58 11 32 5
    chores.rag|손걸레|Cleaning rag|m|T s M16 30 C30 18 44 34 58 24 C70 16 84 24 88 34 L84 76 C70 86 58 70 44 80 C32 88 18 82 12 72 Z;k l 3 28 40 72 34;k l 3 26 56 72 50
    chores.bucket|양동이|Bucket|m|k q 4 18 38 50 4 82 38;@chores.bucketbody A=T;T b 16 32 68 9 4;k l 3 26 54 74 54
    chores.recycle|분리수거|Recycling|m|@chores.arrow 50 54 1 A=T;@chores.arrow 50 54 1 120 A=T;@chores.arrow 50 54 1 240 A=T
    chores.trashbag|쓰레기봉투|Trash bag|m|T p 4 40 10 60 10 56 26 44 26;T s M42 26 L58 26 C80 40 88 62 84 78 C80 92 20 92 16 78 C12 62 20 40 42 26 Z;k l 3 38 26 62 26;k q 2.6 34 50 28 62 32 74
    chores.trashcan|쓰레기통|Trash can|m|T p 5 20 30 80 30 72 90 28 90;T b 14 20 72 10 4;T b 40 10 20 12 4;k l 3.4 38 42 40 80;k l 3.4 50 42 50 80;k l 3.4 62 42 60 80
    chores.dishes|설거지|Dishes|c|w o 42 44 34;sky! o 42 44 24;w! o 42 44 16;blue o 74 74 14;w o 66 68 4;w o 78 62 4;w o 86 76 4;sky star 78 22 12 4 4
    chores.gloves|고무장갑|Rubber gloves|c|yellow b 36 58 28 34 6;yellow s M24 60 L24 26 Q24 20 29 20 Q34 20 34 26 L34 12 Q34 7 39 7 Q44 7 44 12 L44 10 Q44 5 49 5 Q54 5 54 10 L54 14 Q54 9 59 9 Q64 9 64 14 L64 40 L70 32 Q74 26 80 30 Q84 34 80 40 L66 64 Z;orange! b 36 74 28 5 2
    chores.sponge|수세미|Scrubber|c|green b 12 22 76 24 8;yellow b 12 42 76 34 9;orange! o 30 58 4;orange! o 50 66 3;orange! o 66 56 4;w o 76 22 8;w o 88 14 4
    chores.pot|냄비|Pot|m|T o 50 16 5;T s M16 36 C16 18 84 18 84 36 Z;@chores.potbody A=T;k l 3 28 54 72 54
    chores.pan|프라이팬|Frying pan|m|T o 38 56 30;T b 62 26 32 10 5 -30;k o 38 56 19
    chores.basket|장바구니|Shopping basket|m|k q 5 28 44 50 6 72 44;T p 5 12 44 88 44 78 90 22 90;k l 3 36 54 38 82;k l 3 50 54 50 82;k l 3 64 54 62 82
    chores.cart|쇼핑 카트|Shopping cart|m|k l 5 8 16 20 16 32 66 76 66;T p 4 24 26 90 26 80 56 32 56;k l 3 44 28 46 54;k l 3 62 28 62 54;k o 38 80 7;k o 70 80 7
    chores.receipt|영수증|Receipt|m|T p 3 20 8 80 8 80 90 70 82 60 90 50 82 40 90 30 82 20 90;k l 3.4 30 24 70 24;k l 3.4 30 38 70 38;k l 3.4 30 52 52 52;k l 4 30 66 70 66
    chores.bulb|전구 교체|Light bulb|c|yellow s M50 8 C72 8 84 26 80 42 C76 54 64 58 64 70 L36 70 C36 58 24 54 20 42 C16 26 28 8 50 8 Z;orange! q 3 38 34 50 24 62 34;gray b 36 68 28 10 3;gray b 38 77 24 9 3;dark b 44 85 12 6 2;w! e 34 26 4 7 30
    chores.watering|화분 물주기|Watering can|c|mint q 7 34 40 40 12 60 36;mint s M60 42 L88 22 L92 32 L66 62 Z;mint b 14 36 54 50 10;blue! o 88 46 3;blue! o 80 54 3;blue! o 90 60 3;w! b 22 44 5 26 2
    chores.plant|화분|Potted plant|c|leaf s M50 52 C26 46 18 28 24 14 C42 16 50 34 50 52 Z;green s M50 52 C74 46 82 28 76 14 C58 16 50 34 50 52 Z;orange p 4 26 54 74 54 66 92 34 92;brown! b 26 54 48 6 2;orange b 22 50 56 10 4
    chores.bed|이불 정리|Making the bed|c|w b 8 28 84 26 8;sky b 14 18 30 22 8;peach b 56 18 30 22 8;blue b 8 42 84 40 8;w! b 8 42 84 10 4;brown b 12 82 8 8 2;brown b 80 82 8 8 2;@paw 50 64 0.3 A=w
    chores.blanket|이불|Folded blanket|c|sky b 12 62 76 22 9;peach b 12 40 76 22 9;mint b 12 18 76 22 9;w! b 12 25 40 6 3;w! b 48 48 40 6 3;w! b 12 70 40 6 3
    chores.shower|샤워|Shower|c|gray q 7 76 88 76 12 42 16;gray s M18 34 C18 18 54 18 54 34 Z;gray b 16 32 40 6 3;sky! e 22 50 3 6;sky! e 36 50 3 6;sky! e 50 50 3 6;sky! e 28 66 3 6;sky! e 44 66 3 6;sky! e 36 82 3 6;sky! e 20 82 3 6;sky! e 52 82 3 6
    chores.toothbrush|칫솔|Toothbrush|c|@chores.tb 50 50 1 -30
    chores.toothpaste|치약|Toothpaste|c|w p 6 22 14 78 14 66 76 34 76;gray b 18 8 64 9 3;blue b 40 74 20 16 3;blue! b 26 34 48 20 0;w! l 3 32 44 68 44
    chores.towel|수건|Towel|c|gray b 8 12 84 6 3;peach b 22 14 56 74 6;w! b 22 68 56 6 0;w! b 22 76 56 3 0;k l 3 34 18 34 62
    chores.parcel|택배 상자|Parcel|c|tan p 4 50 8 90 28 50 48 10 28;#BF8F5F p 4 10 28 50 48 50 92 10 72;brown p 4 90 28 50 48 50 92 90 72;butter! p 3 30 18 40 13 78 33 68 38;w b 20 54 20 14 2 22;@paw 72 62 0.28 A=choco
    chores.toolbox|공구함|Toolbox|c|k q 6 34 34 34 14 50 14;k q 6 50 14 66 14 66 34;red b 8 32 84 54 8;dark! b 8 50 84 6 0;gray b 42 46 16 14 3
    chores.hammer|망치|Hammer|m|@chores.hammerart 50 50 0.8 35
    chores.driver|드라이버|Screwdriver|m|T b 32 8 36 40 12;k l 2.6 42 14 42 42;k l 2.6 50 14 50 42;k l 2.6 58 14 58 42;T b 45 48 10 30 2;T p 3 44 76 56 76 53 92 47 92
    chores.wrench|스패너|Wrench|m|T s M58 14 L58 30 L70 30 L70 14 C86 22 88 40 72 46 L46 84 C42 92 26 92 22 84 C18 76 22 70 30 66 L56 42 C42 34 42 22 58 14 Z;k o 32 78 4
    chores.bowl|반려동물 밥그릇|Pet bowl|c|choco o 40 28 6;choco o 54 22 6;choco o 62 32 6;choco o 48 36 6;sky p 5 18 40 82 40 92 84 8 84;@paw 50 62 0.4 A=w
    chores.scoop|모래 삽|Litter scoop|m|T b 44 6 12 40 6;T p 6 18 40 82 40 76 90 24 90;k o 36 56 3.2;k o 50 56 3.2;k o 64 56 3.2;k o 36 72 3.2;k o 50 72 3.2;k o 64 72 3.2
    chores.catcan|고양이 캔|Cat food can|c|gray b 16 22 68 62 8;gray e 50 26 34 11;w! e 50 26 26 7;k q 4 66 26 72 18 78 22;peach! b 16 44 68 26 0;@face.smile 50 56 0.46
    chores.litter|고양이 화장실|Litter box|c|sky p 5 8 40 92 40 84 84 16 84;butter! e 50 46 36 6;w! b 16 52 68 5 2;@paw 50 68 0.3 A=w
    chores.soap|비누|Soap|c|pink b 14 40 72 42 16;w! e 36 52 8 4 -15;@paw 58 62 0.3 A=rose;w o 26 28 9;w o 44 20 6;w o 70 26 11
    chores.detergent|세제|Detergent|c|sky b 40 8 22 16 3;sky s M30 22 L74 22 Q84 22 84 32 L84 82 Q84 92 74 92 L26 92 Q16 92 16 82 L16 36 Q16 22 30 22 Z;w! b 26 42 48 32 6;blue o 50 58 9;w! o 47 55 2.4
    chores.spray|분무기|Spray bottle|m|T s M26 10 L70 10 L80 22 L58 22 L58 34 L38 34 L38 24 L22 24 Z;T p 5 28 36 68 36 76 92 20 92;k l 3 26 62 72 62;k o 86 10 2.6;k o 90 22 2.6
    chores.dustpan|쓰레받기|Dustpan|m|T b 72 8 12 40 5;T s M8 88 L26 42 L82 42 Q88 42 88 48 L88 88 Z;k l 3 22 76 80 76;k l 3 34 54 28 76;k l 3 54 54 50 76;k l 3 74 54 72 76
    chores.tissue|티슈|Tissue box|c|sky b 12 44 76 44 8;navy! b 32 44 36 8 4;w s M34 46 C36 28 30 20 44 12 C50 20 60 16 64 24 C62 34 66 40 66 46 Z;@paw 50 70 0.3 A=w
    chores.toiletpaper|두루마리 휴지|Toilet paper|m|T e 30 52 16 36;T b 30 16 44 72 0;T s M74 16 L92 16 L92 88 L80 80 L74 88 Z;T e 30 52 16 36;k e 30 52 6 14
    chores.hanger|옷걸이|Hanger|m|k q 4 50 34 42 20 50 12;k q 4 50 12 58 10 58 20;T p 4 50 30 92 72 92 80 8 80 8 72;T! p 3 18 72 82 72 50 42
    chores.shirt|빨래 티셔츠|T-shirt|m|T p 4 34 12 66 12 90 34 76 50 70 42 70 90 30 90 30 42 24 50 10 34;k q 3 38 13 50 24 62 13
    chores.socks|양말|Socks|m|T s M28 8 L54 8 L54 54 L78 68 Q90 76 84 86 Q78 94 66 88 L34 72 Q28 68 28 60 Z;k l 3 28 22 54 22;k l 3 28 30 54 30
    chores.clothespin|빨래집게|Clothespin|m|T p 4 40 8 54 8 54 90 44 90;T p 4 60 8 72 8 58 90 54 90;k o 53 44 6
    chores.apron|앞치마|Apron|m|k q 3.4 34 22 50 2 66 22;T s M34 20 L66 20 L68 40 L84 44 L78 92 L22 92 L16 44 L32 40 Z;k b 36 60 28 18 4;@paw 50 44 0.2 A=k
    chores.key|열쇠|Key|m|T o 30 34 22;k o 30 34 8;T l 9 44 48 84 84;T l 8 66 66 74 58;T l 8 76 76 84 68
    chores.plunger|뚫어뻥|Plunger|m|T b 46 8 8 50 4;T s M22 86 C20 58 40 54 50 54 C60 54 80 58 78 86 Z;k l 3 22 78 78 78
    chores.candle|향초|Scented candle|c|butter b 24 34 52 54 8;w! b 24 54 52 18 0;k l 3 50 34 50 24;orange s M50 6 C58 16 58 24 50 28 C42 24 42 16 50 6 Z;@paw 50 63 0.24 A=rose
    chores.brushcat|고양이 빗|Pet brush|c|rose b 42 50 14 42 7;rose e 50 30 30 22;w! e 50 30 22 15;k! o 38 24 2;k! o 50 22 2;k! o 62 24 2;k! o 38 36 2;k! o 50 38 2;k! o 62 36 2
    chores.sparkling|반짝 청소 끝|All clean|m|T star 42 54 36 10 4;T star 78 24 16 5 4;@paw 76 74 0.34 A=T
    chores.checklist|집안일 목록|Chore list|m|T b 18 14 64 76 8;T b 36 8 28 12 4;k l 3.4 30 36 40 46;k l 3.4 40 46 46 34;k l 3.4 54 40 72 40;k l 3.4 30 56 40 66;k l 3.4 40 66 46 54;k l 3.4 54 60 72 60
    """#
}
