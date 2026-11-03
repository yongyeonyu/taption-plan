extension StickerCatalog {
    static let travelParts = #"""
    travel.wheel|k o 50 50 40;A! o 50 50 17
    travel.pawbig|A e 50 66 19 15;A o 25 44 10;A o 42 28 10;A o 58 28 10;A o 75 44 10
    travel.pawflat|A! e 50 66 19 15;A! o 25 44 10;A! o 42 28 10;A! o 58 28 10;A! o 75 44 10
    travel.ears|A p 4 14 52 16 12 42 26;A p 4 86 52 84 12 58 26;B! p 3 22 34 22 19 34 28;B! p 3 78 34 78 19 66 28
    travel.plane|A p 3 50 28 92 56 92 66 50 56 8 66 8 56;A p 3 50 74 70 86 70 92 50 87 30 92 30 86;A b 41 8 18 84 9
    travel.plane.flat|A! p 3 50 28 92 56 92 66 50 56 8 66 8 56;A! p 3 50 74 70 86 70 92 50 87 30 92 30 86;A! b 41 8 18 84 9
    travel.pin|A s M50 92 C38 72 18 58 18 38 C18 20 32 8 50 8 C68 8 82 20 82 38 C82 58 62 72 50 92 Z
    travel.ticket|A s M12 26 L88 26 L88 41 Q79 50 88 59 L88 74 L12 74 L12 59 Q21 50 12 41 Z;k! l 3 66 32 66 38;k! l 3 66 44 66 50;k! l 3 66 56 66 62;k! l 3 66 68 66 69
    travel.car|A s M8 68 L8 58 Q8 50 18 48 L28 30 Q31 24 38 24 L64 24 Q70 24 73 30 L82 48 Q92 50 92 58 L92 68 Q92 72 88 72 L12 72 Q8 72 8 68 Z;B! s M34 31 L46 31 L46 46 L26 46 Z;B! s M52 31 L65 31 L74 46 L52 46 Z;k o 28 72 12;C! o 28 72 5;k o 72 72 12;C! o 72 72 5
    travel.die|w b 18 18 64 64 14;k! o 34 34 6;k! o 66 34 6;red! o 50 50 7;k! o 34 66 6;k! o 66 66 6
    travel.spade|k! s M50 20 C56 34 74 42 74 56 C74 68 60 70 53 62 L58 80 L42 80 L47 62 C40 70 26 68 26 56 C26 42 44 34 50 20 Z
    travel.bandage|A b 8 33 84 34 17;B! b 36 33 28 34 0;k! o 44 44 2.2;k! o 56 44 2.2;k! o 44 56 2.2;k! o 56 56 2.2;k! o 22 50 2.2;k! o 78 50 2.2
    travel.scope|k l 5 50 54 32 90;k l 5 50 54 68 90;k l 5 50 54 50 86;A b 8 30 26 18 4 -24;B b 30 18 52 28 7 -24;A b 76 4 12 34 4 -24
    """#

    static let fitnessParts = #"""
    fitness.dumbbell|A b 44 36 12 28 2 90;B b 8 34 12 32 5;A b 20 22 18 56 6;A b 62 22 18 56 6;B b 80 34 12 32 5
    fitness.racket|B b 45 60 10 32 5;A e 50 33 25 27;w! e 50 33 19 21;gray! l 1.6 42 15 42 51;gray! l 1.6 50 13 50 53;gray! l 1.6 58 15 58 51;gray! l 1.6 32 25 68 25;gray! l 1.6 31 33 69 33;gray! l 1.6 32 41 68 41
    fitness.capsule|A s M50 34 L32 34 Q16 34 16 50 Q16 66 32 66 L50 66 Z;B s M50 34 L68 34 Q84 34 84 50 Q84 66 68 66 L50 66 Z
    fitness.syringe|gray b 45 8 10 16 2;gray b 34 22 32 7 3;gray l 3.5 50 76 50 92;w b 38 28 24 48 4;sky! b 40 46 20 28 2;k! l 2.5 42 38 50 38;k! l 2.5 42 50 50 50;k! l 2.5 42 62 50 62
    fitness.brush|A b 44 38 12 54 5;C b 42 30 16 12 2;B s M42 30 C40 20 46 12 54 6 C58 14 60 22 58 30 Z
    fitness.skis|A s M42 90 L42 22 Q42 10 50 8 Q58 10 58 22 L58 90 Q50 95 42 90 Z;k! b 42 48 16 10 2
    """#

    static let travelSource = #"""
    travel.plane|비행기|Plane|m|@travel.plane 50 50 1 45 A=T
    travel.jet|여객기|Airliner|c|blue p 3 12 50 8 20 22 20 40 44;w b 8 38 84 28 14;sky! o 34 49 3.5;sky! o 46 49 3.5;sky! o 58 49 3.5;navy! s M78 41 Q90 44 92 52 L76 52 Z;blue p 3 40 56 60 56 44 86 30 86
    travel.plane.cat|고양이 비행기|Cat plane|d|sky p 3 10 50 6 22 20 22 34 42;w p 3 62 42 66 22 78 36;w p 3 92 42 92 22 78 36;w b 8 36 86 34 17;k! o 68 50 3;k! o 84 50 3;k q 2 72 57 76 61 80 57;pink! e 62 58 4 3;pink! e 90 58 3 3;sky p 3 34 58 52 58 38 86 26 86
    travel.suitcase|여행가방|Suitcase|m|k o 30 87 5;k o 70 87 5;T l 6 38 28 38 13 62 13 62 28;T b 14 26 72 60 10;k! l 5 34 34 34 78;k! l 5 66 34 66 78
    travel.carryon|캐리어|Carry-on|d|gray l 5 38 26 38 9 62 9 62 26;dark o 34 86 5;dark o 66 86 5;sky b 24 24 52 62 12;blue! l 3.5 38 32 38 78;blue! l 3.5 50 32 50 78;blue! l 3.5 62 32 62 78
    travel.suitcase.cat|고양이 여행가방|Cat suitcase|d|dark l 6 38 26 38 10 62 10 62 26;dark o 28 88 4.5;dark o 72 88 4.5;@travel.ears 50 40 1 A=butter B=pink;butter b 14 24 72 62 14;@face.smile 50 50 1;orange! b 14 74 72 7 0
    travel.passport|여권|Passport|m|T b 20 8 60 84 8;k! o 50 40 18;T! o 50 40 14;k! e 50 40 7 15;T! e 50 40 4 13;k! l 2.6 36 40 64 40;k! l 5 36 72 64 72
    travel.passport.navy|남색 여권|Navy passport|d|navy b 20 8 60 84 8;yellow! o 50 40 18;navy! o 50 40 14;yellow! e 50 40 7 15;navy! e 50 40 4 13;yellow! l 2.6 36 40 64 40;yellow! l 5 36 72 64 72
    travel.boardingpass|탑승권|Boarding pass|c|w b 8 24 84 52 8;sky! s M8 32 Q8 24 16 24 L84 24 Q92 24 92 32 L92 38 L8 38 Z;@travel.plane.flat 26 56 .3 90 A=blue;gray! l 3 44 50 60 50;gray! l 3 44 60 56 60;k! l 2 66 42 66 72;k! l 2.4 73 44 73 70;k! l 1.4 78 44 78 70;k! l 2.8 83 44 83 70
    travel.camera|카메라|Camera|m|T b 32 16 36 20 6;T b 8 26 84 58 12;k! o 50 56 21;T! o 50 56 16;k! o 50 56 9;T! o 46 52 2.6;k! o 78 40 4.5
    travel.map|지도|Map|c|mint s M10 24 L36 14 L36 76 L10 86 Z;butter s M36 14 L64 24 L64 86 L36 76 Z;mint s M64 24 L90 14 L90 76 L64 86 Z;red! o 20 66 3;red! o 32 56 3;red! o 44 58 3;red! o 56 50 3;@travel.pin 70 36 .36 A=red;w! o 70 30 3.4
    travel.map.mono|접은 지도|Folded map|m|T s M10 24 L36 14 L36 76 L10 86 Z;T s M36 14 L64 24 L64 86 L36 76 Z;T s M64 24 L90 14 L90 76 L64 86 Z;k! o 20 64 3.4;k! o 34 54 3.4;k! o 48 56 3.4;k! o 62 48 3.4;k! star 76 36 10 4 5
    travel.pin|핀|Map pin|m|@travel.pin 50 50 1 A=T;@paw 50 38 .56 A=k
    travel.pin.red|빨간 핀|Red pin|d|@travel.pin 50 50 1 A=red;w! o 50 38 15
    travel.compass|나침반|Compass|c|butter o 50 13 6;butter o 50 54 37;w! o 50 54 29;k! l 3 50 29 50 33;k! l 3 50 75 50 79;k! l 3 25 54 29 54;k! l 3 71 54 75 54;red! p 3 50 32 58 54 42 54;navy! p 3 50 76 42 54 58 54;k! o 50 54 3
    travel.ticket|표|Ticket|m|@travel.ticket 50 50 1 -12 A=T
    travel.ticket.admit|별 표|Star ticket|c|@travel.ticket 50 50 1 -12 A=peach;red! star 40 52 13 6 5
    travel.train|기차|Train|d|gray l 5 32 78 22 92;gray l 5 68 78 78 92;sky b 18 8 64 72 18;w! b 28 18 44 26 7;blue! b 18 50 64 5 0;butter! o 33 66 6;butter! o 67 66 6;k! b 42 62 16 6 3
    travel.steam|증기기관차|Steam train|c|w o 26 15 7;gray o 36 13 5;dark b 26 24 14 20 3;navy b 12 40 54 30 8;red b 56 18 34 52 6;sky! b 63 26 20 16 3;red b 8 62 84 12 4;@travel.wheel 26 76 .36 A=gray;@travel.wheel 50 76 .36 A=gray;@travel.wheel 76 76 .36 A=gray
    travel.subway|지하철|Subway|m|k l 6 34 78 24 92;k l 6 66 78 76 92;T b 18 8 64 72 16;k! b 26 18 21 24 5;k! b 53 18 21 24 5;k! o 32 62 5.5;k! o 68 62 5.5;k! l 4 43 62 57 62
    travel.bus|버스|Bus|c|butter b 8 22 84 54 12;sky! b 14 30 16 16 3;sky! b 34 30 16 16 3;sky! b 54 30 16 16 3;sky! b 74 30 12 26 3;orange! b 8 54 66 6 0;@travel.wheel 28 76 .36 A=gray;@travel.wheel 70 76 .36 A=gray
    travel.bus.front|마을버스|Local bus|m|k b 24 78 12 12 3;k b 64 78 12 12 3;T b 16 10 68 72 14;k! b 24 20 52 28 5;k! o 30 64 5.5;k! o 70 64 5.5;k! l 4 42 64 58 64
    travel.car|자동차|Car|m|@travel.car 50 48 1 A=T B=k C=T
    travel.car.red|빨간 자동차|Red car|d|@travel.car 50 48 1 A=red B=sky C=gray
    travel.car.cat|고양이 자동차|Cat car|d|@travel.ears 50 26 .56 A=peach B=pink;@travel.car 50 50 1 A=peach B=w C=gray;k! o 38 39 2.6;k! o 62 39 2.6
    travel.taxi|택시|Taxi|c|yellow b 36 12 28 16 4;k! t 50 21 10 TAXI;@travel.car 50 50 1 A=yellow B=sky C=gray;k! b 12 60 8 6 0;k! b 28 60 8 6 0;k! b 44 60 8 6 0;k! b 60 60 8 6 0;k! b 76 60 8 6 0
    travel.bike|자전거|Bicycle|m|k o 25 66 19;T! o 25 66 13;k o 75 66 19;T! o 75 66 13;T l 5 25 66 42 38 66 38 50 66 25 66;T l 5 66 38 75 66;k l 6 34 30 50 30;k l 2 42 38 42 30;k l 6 62 24 74 22;T l 5 66 38 64 24
    travel.scooter|스쿠터|Scooter|c|dark l 6 62 16 80 16;mint p 4 66 68 68 18 78 18 80 68;mint b 34 58 36 14 5;mint s M12 72 Q10 46 36 44 L44 44 Q48 60 40 72 Z;dark b 16 34 28 12 6;butter o 80 28 5.5;@travel.wheel 24 76 .34 A=gray;@travel.wheel 76 76 .34 A=gray
    travel.ship|배|Ship|m|T b 42 10 18 24 4;T b 26 30 50 30 6;k! o 38 44 4.5;k! o 51 44 4.5;k! o 64 44 4.5;T s M8 54 L92 54 L80 86 Q78 90 74 90 L26 90 Q22 90 20 86 Z;k! l 4 16 66 84 66
    travel.sailboat|돛단배|Sailboat|c|w p 3 52 10 84 60 52 60;red p 3 46 22 46 60 18 60;brown l 4 50 8 50 66;navy s M10 66 L90 66 L78 86 Q76 90 72 90 L28 90 Q24 90 22 86 Z;w! l 3.5 20 76 80 76
    travel.balloon|열기구|Hot air balloon|d|k l 2.6 42 70 44 78;k l 2.6 58 70 56 78;red s M50 8 C26 8 14 24 14 40 C14 56 34 62 40 72 L60 72 C66 62 86 56 86 40 C86 24 74 8 50 8 Z;butter! s M50 8 C38 8 30 24 30 40 C30 54 40 62 44 72 L56 72 C60 62 70 54 70 40 C70 24 62 8 50 8 Z;red! s M50 8 C46 8 42 24 42 40 C42 54 46 62 48 72 L52 72 C54 62 58 54 58 40 C58 24 54 8 50 8 Z;tan b 40 78 20 14 4
    travel.tent|텐트|Tent|c|leaf p 4 50 12 92 86 8 86;dark! p 3 50 42 68 86 32 86;yellow! o 50 74 4
    travel.tent.mono|캠핑 텐트|Camp tent|m|T p 4 50 12 92 86 8 86;k! p 3 50 40 68 86 32 86
    travel.campfire|모닥불|Campfire|c|orange s M50 8 C54 26 74 34 74 56 C74 72 62 80 50 80 C38 80 26 72 26 56 C26 44 36 38 39 26 C43 32 45 34 47 34 C50 28 48 18 50 8 Z;butter! s M50 44 C54 52 62 56 62 66 C62 74 56 78 50 78 C44 78 38 74 38 66 C38 56 46 54 50 44 Z;brown b 14 72 72 13 6 14;choco b 14 72 72 13 6 -14
    travel.mountain|등산 산|Mountain|m|k l 3.4 38 36 38 8;T p 3 38 8 64 16 38 25;T p 5 8 88 38 36 52 58 66 42 92 88;k! l 4 28 56 36 62 42 54 48 62
    travel.mountain.snow|설산|Snowy mountain|c|leaf p 5 46 86 70 34 92 86;green p 5 8 86 38 18 68 86;w! s M38 18 L50 40 L44 37 L38 44 L32 37 L26 40 Z
    travel.palm|야자수|Palm tree|c|butter e 50 84 40 9;brown q 9 44 82 40 56 52 34;leaf s M52 32 C40 12 20 16 10 34 C26 28 40 28 52 32 Z;green s M52 32 C62 10 82 12 92 32 C76 26 64 28 52 32 Z;green s M52 32 C38 34 22 46 22 64 C32 48 42 40 52 32 Z;leaf s M52 32 C66 34 82 46 82 64 C72 48 62 40 52 32 Z;brown o 47 37 4.5;brown o 57 38 4.5
    travel.parasol|해변 파라솔|Beach parasol|c|butter e 50 85 42 7;dark l 5 50 40 50 84;red s M10 46 Q10 10 50 10 Q90 10 90 46 Z;w! s M34 46 Q34 12 50 10 Q66 12 66 46 Z;sky o 78 76 7
    travel.bed|호텔 침대|Hotel bed|m|T b 8 26 12 62 5;T b 80 48 12 40 5;T b 14 52 72 24 6;T b 22 40 26 16 8;k! l 4 56 52 56 76
    travel.hotel|호텔|Hotel|c|lilac b 18 14 64 78 8;yellow! star 50 25 8 3.4 5;sky! b 26 36 12 12 2;sky! b 44 36 12 12 2;sky! b 62 36 12 12 2;sky! b 26 54 12 12 2;sky! b 62 54 12 12 2;purple! b 42 62 16 30 3;sky! b 26 72 12 12 2;sky! b 62 72 12 12 2
    travel.house|집|House|m|T p 4 50 10 92 48 78 48 78 88 22 88 22 48 8 48;k! b 41 58 18 30 4;k! o 54 74 2
    travel.house.cat|고양이 집|Cat house|d|peach b 22 44 56 44 8;red p 4 50 12 90 50 10 50;red p 3 24 34 24 14 40 22;red p 3 76 34 76 14 60 22;dark! s M34 88 L34 68 Q34 54 50 54 Q66 54 66 68 L66 88 Z;w! o 44 68 2.6;w! o 56 68 2.6;w! q 2 47 74 50 77 53 74
    travel.globe|지구본|Globe|d|dark q 5 18 28 2 62 44 80;brown l 7 50 76 50 86;brown b 30 84 40 8 4;sky o 50 44 34;leaf! s M34 22 C44 18 54 24 50 34 C46 42 36 38 30 44 C24 40 26 28 34 22 Z;leaf! s M60 44 C70 40 80 44 78 54 C74 66 62 72 58 66 C56 58 54 50 60 44 Z
    travel.globe.mono|지구|Earth|m|T o 50 50 41;k! l 3 9 50 91 50;k! q 3 50 9 16 50 50 91;k! q 3 50 9 84 50 50 91;k! q 3 16 26 50 38 84 26;k! q 3 16 74 50 62 84 74;k! l 3 50 9 50 91
    travel.telescope|망원경|Telescope|m|@travel.scope 50 50 1 A=T B=T
    travel.backpack|배낭|Backpack|m|k q 5 40 20 50 5 60 20;T b 10 40 12 36 6;T b 78 40 12 36 6;T b 18 16 64 74 20;T b 30 54 40 28 8;k! l 3.4 30 42 70 42;k! o 50 66 3
    travel.backpack.cat|고양이 배낭|Cat backpack|d|@travel.ears 50 40 1 A=mint B=pink;mint b 18 22 64 70 20;@face.smile 50 36 .7;blue b 30 62 40 24 8;orange! o 50 74 3
    travel.postcard|엽서|Postcard|c|w b 8 20 84 60 6;sky! b 14 27 34 46 3;leaf! p 3 14 73 30 44 48 73;yellow! o 38 36 5;k! l 2 54 26 54 74;rose! b 70 27 16 20 2;red! heart 78 37 11;gray! l 3 60 54 86 54;gray! l 3 60 64 86 64
    travel.snowglobe|스노우볼 기념품|Snow globe|d|sky o 50 44 34;@cat.hwarang 50 52 .5;@face.smile 50 53 .5;w! o 30 34 3;w! o 42 22 2.4;w! o 66 26 3;w! o 74 44 2.4;brown b 24 72 52 18 6;butter! star 50 81 6 2.6 5
    travel.magnet|기념 자석|Souvenir magnet|c|butter b 14 22 72 56 10;sky! b 22 30 56 40 6;w! o 66 42 6;leaf! p 3 22 70 44 42 62 70;red! heart 50 62 11
    travel.stamp|여행 체크 도장|Travel check stamp|m|T o 50 50 42;k! o 50 50 34;T! o 50 50 29;k! l 9 33 50 46 64 68 37
    travel.fuel|주유|Fuel|m|k q 4.5 60 54 84 64 84 40;k l 4.5 84 40 74 26;T b 16 10 46 78 8;k! b 24 18 30 20 4;k! s M39 46 C31 58 29 62 39 70 C49 62 47 58 39 46 Z;k b 10 82 58 10 4
    travel.trafficlight|신호등|Traffic light|c|dark l 7 50 72 50 88;dark b 30 6 40 70 12;red! o 50 21 10;yellow! o 50 41 10;green! o 50 61 10
    travel.busstop|정류장|Bus stop|m|k l 7 50 50 50 88;k b 32 84 36 8 4;T o 50 30 24;k! b 37 17 26 22 5;T! b 41 21 18 9 2;T! o 43 33 2.2;T! o 57 33 2.2;k! b 40 38 5 5 1;k! b 55 38 5 5 1
    travel.signpost|표지판|Signpost|c|leaf e 50 88 24 5;brown b 45 8 10 80 3;sky p 3 22 16 78 16 90 27 78 38 22 38;butter p 3 78 44 24 44 10 55 24 66 78 66
    travel.sunglasses|선글라스|Sunglasses|m|T l 4 12 42 6 34;T l 4 88 42 94 34;T q 5 44 44 50 38 56 44;T b 8 38 38 30 12;T b 54 38 38 30 12;k! l 3 16 46 26 56;k! l 3 62 46 72 56
    travel.strawhat|밀짚모자|Straw hat|c|tan e 50 66 43 16;butter s M26 62 C26 26 74 26 74 62 Q50 74 26 62 Z;red! s M26 52 Q50 64 74 52 L74 62 Q50 74 26 62 Z
    travel.cablecar|케이블카|Cable car|c|k l 3.5 8 26 92 12;dark l 4 50 18 50 34;red b 22 34 56 52 12;sky! b 30 42 18 20 3;sky! b 52 42 18 20 3;w! b 22 70 56 5 0
    travel.helicopter|헬리콥터|Helicopter|m|k l 5 24 18 76 18;k l 5 50 18 50 30;T l 7 60 52 90 44;T l 4 90 36 90 54;k l 4.5 36 74 32 86;k l 4.5 56 74 60 86;k l 4.5 20 86 72 86;T b 14 30 56 46 22;k! s M20 52 Q20 36 36 36 L36 52 Z
    travel.rocket|로켓|Rocket|d|red p 3 32 60 14 86 34 80;red p 3 68 60 86 86 66 80;orange p 3 40 78 60 78 50 94;w s M50 6 C66 18 70 40 66 78 L34 78 C30 40 34 18 50 6 Z;red! s M50 6 C56 11 60 16 63 24 L37 24 C40 16 44 11 50 6 Z;sky o 50 44 10
    travel.lighthouse|등대|Lighthouse|c|red p 3 50 12 68 28 32 28;yellow b 38 26 24 14 2;w p 3 36 40 64 40 72 88 28 88;red! p 3 34 54 66 54 68 68 32 68;navy e 50 88 38 5
    travel.anchor|닻|Anchor|m|T l 8 50 26 50 84;T l 8 32 40 68 40;T q 8 16 58 22 88 50 88;T q 8 84 58 78 88 50 88;T p 3 8 62 24 62 16 48;T p 3 76 62 92 62 84 48;T o 50 18 11;k! o 50 18 4.2
    travel.lifebuoy|튜브|Swim ring|c|red o 50 50 41;w! b 41 8 18 24 0;w! b 41 68 18 24 0;w! b 8 41 24 18 0;w! b 68 41 24 18 0;sky o 50 50 17
    travel.beachball|비치볼|Beach ball|d|w o 50 50 41;red! s M50 50 L50 9 C38 10 24 16 16 28 Z;blue! s M50 50 L91 50 C91 38 84 22 72 15 Z;yellow! s M50 50 L50 91 C62 90 78 84 84 72 Z;leaf! s M50 50 L9 50 C9 62 16 78 28 85 Z;w o 50 50 8
    travel.surfboard|서핑보드|Surfboard|c|mint s M50 6 C68 24 70 70 56 94 L44 94 C30 70 32 24 50 6 Z;w! s M50 6 C54 26 54 74 50 94 C46 74 46 26 50 6 Z;red! b 36 58 28 6 0
    travel.pawprints|발자국 여행|Paw trail|m|@travel.pawbig 28 72 .56 -20 A=T;@travel.pawbig 72 52 .56 18 A=T;@travel.pawbig 34 24 .56 -14 A=T
    travel.ferris|관람차|Ferris wheel|m|k l 6 50 46 26 90;k l 6 50 46 74 90;k l 6 16 90 84 90;T o 50 46 33;k! o 50 46 25;T! o 50 46 22;k! l 2.6 50 24 50 68;k! l 2.6 28 46 72 46;k! l 2.6 34 30 66 62;k! l 2.6 34 62 66 30;k! o 50 46 5;T b 44 6 12 12 4;T b 78 40 12 12 4;T b 10 40 12 12 4;T b 44 74 12 12 4;T b 68 16 12 12 4;T b 20 16 12 12 4;T b 68 64 12 12 4;T b 20 64 12 12 4
    """#

    static let fitnessSource = #"""
    fitness.dumbbell|아령|Dumbbell|m|@fitness.dumbbell 50 50 1 A=T B=T
    fitness.dumbbell.pink|분홍 아령|Pink dumbbell|d|@fitness.dumbbell 50 50 1 -30 A=pink B=rose
    fitness.kettlebell|케틀벨|Kettlebell|m|T q 9 30 44 50 -24 70 44;T o 50 62 30;k! q 4 34 64 36 78 50 82
    fitness.plate|원판|Weight plate|m|T o 50 50 41;k! o 50 50 28;T! o 50 50 24;k! o 50 50 9
    fitness.sneaker|운동화|Sneaker|c|w b 8 68 84 16 8;rose s M12 72 L12 38 Q12 28 22 32 L34 36 Q42 48 56 52 L78 58 Q90 62 90 72 Z;w! l 3.5 40 44 34 52;w! l 3.5 49 49 43 57;w! l 3.5 58 53 52 61;red! b 14 40 12 22 4
    fitness.sneaker.mono|달리기 신발|Running shoe|m|T b 8 68 84 16 8;T s M12 72 L12 38 Q12 28 22 32 L34 36 Q42 48 56 52 L78 58 Q90 62 90 72 Z;k! l 3.5 40 44 34 52;k! l 3.5 49 49 43 57;k! l 3.5 58 53 52 61
    fitness.runner|달리기|Running|m|T o 62 16 10;T l 8 54 38 72 46 84 38;T l 8 54 38 36 38 26 50;T l 12 56 36 46 60;T l 9 46 60 64 68 60 88;T l 9 46 60 36 76 16 76
    fitness.pawrun|달리는 발자국|Running paws|m|@travel.pawbig 24 74 .5 70 A=T;@travel.pawbig 70 62 .5 70 A=T;@travel.pawbig 34 26 .5 70 A=T
    fitness.catrun|운동 고양이|Workout cat|d|@cat.chunhyang;@face.happy;red! b 20 32 60 7 3;w! star 50 36 4 2 5
    fitness.yogamat|요가 매트|Yoga mat|c|lilac b 22 28 70 44 22;purple b 50 28 7 44 0;purple b 70 28 7 44 0;purple o 30 50 22;lilac! o 30 50 15;purple! o 30 50 8;lilac! o 30 50 3
    fitness.bottle|물병|Water bottle|m|T b 38 8 24 16 5;T b 24 22 52 70 14;k! l 4 34 42 66 42;k! l 4 34 74 66 74;k! s M50 48 C43 58 42 62 50 68 C58 62 57 58 50 48 Z
    fitness.shaker|단백질 쉐이크|Protein shake|d|dark b 30 8 40 10 5;sky p 3 24 18 76 18 70 90 30 90;w! p 3 32 42 68 42 66 84 34 84;peach! p 3 33 60 67 60 66 84 34 84
    fitness.jumprope|줄넘기|Jump rope|m|T q 4.5 18 32 50 140 82 32;T b 11 8 14 32 7;T b 75 8 14 32 7
    fitness.bike|운동 자전거|Racing bike|d|k o 25 66 19;w! o 25 66 13;k o 75 66 19;w! o 75 66 13;red l 6 25 66 42 38 66 38 50 66 25 66;red l 6 66 38 75 66;k l 6 34 30 50 30;k l 2.4 42 38 42 30;red l 6 66 38 64 24;k q 5 64 24 82 18 76 34
    fitness.goggles|수영 물안경|Swim goggles|c|dark l 7 8 50 92 50;blue l 7 44 44 56 44;sky b 14 32 34 34 14;sky b 52 32 34 34 14;w! l 3 22 42 30 52;w! l 3 60 42 68 52
    fitness.swim|수영|Swimming|m|T o 66 30 11;T l 11 50 54 26 46 38 26;T l 12 50 54 28 58;T q 6 8 72 22 60 36 72;T q 6 36 72 50 84 64 72;T q 6 64 72 78 60 92 72
    fitness.soccer|축구공|Soccer ball|m|T o 50 50 41;k! p 3 50 34 65 45 59 62 41 62 35 45;k! l 3 50 34 50 12;k! l 3 65 45 84 38;k! l 3 59 62 72 80;k! l 3 41 62 28 80;k! l 3 35 45 16 38;k! s M38 11 L62 11 L50 20 Z;k! s M90 34 L90 56 L80 44 Z;k! s M10 34 L10 56 L20 44 Z;k! s M64 88 L82 74 L68 72 Z;k! s M36 88 L18 74 L32 72 Z
    fitness.basketball|농구공|Basketball|c|orange o 50 50 41;k! l 3 9 50 91 50;k! l 3 50 9 50 91;k! q 3 21 21 40 50 21 79;k! q 3 79 21 60 50 79 79
    fitness.baseball|야구공|Baseball|c|w o 50 50 41;red! q 3.4 26 16 42 50 26 84;red! q 3.4 74 16 58 50 74 84;red! l 2.4 31 28 38 26;red! l 2.4 35 42 42 40;red! l 2.4 35 58 42 60;red! l 2.4 31 72 38 74;red! l 2.4 69 28 62 26;red! l 2.4 65 42 58 40;red! l 2.4 65 58 58 60;red! l 2.4 69 72 62 74
    fitness.volleyball|배구공|Volleyball|m|T o 50 50 41;k! q 3 50 50 40 22 58 10;k! q 3 50 50 78 44 88 64;k! q 3 50 50 34 72 12 66;k! q 3 44 34 66 40 76 24;k! q 3 70 56 56 74 62 88;k! q 3 38 62 20 44 26 18
    fitness.tennis|테니스 라켓|Tennis racket|c|@fitness.racket 46 50 .95 35 A=red B=dark;yellow o 80 26 10;w! q 2 72 22 80 28 88 22
    fitness.shuttle|배드민턴|Badminton|c|w p 3 28 12 72 12 60 64 40 64;gray! l 2 40 14 45 62;gray! l 2 50 14 50 62;gray! l 2 60 14 55 62;gray! q 2 31 30 50 36 69 30;red! b 38 56 24 8 2;w s M40 64 L60 64 Q62 88 50 90 Q38 88 40 64 Z
    fitness.bowling|볼링|Bowling|c|w s M34 8 C43 8 45 19 43 28 C42 34 50 46 50 62 C50 78 46 88 42 91 L26 91 C22 88 18 78 18 62 C18 46 26 34 25 28 C23 19 25 8 34 8 Z;red! l 3.4 27 31 41 31;red! l 3.4 26 38 42 38;navy o 66 68 24;k! o 60 58 3.6;k! o 71 58 3.6;k! o 65 68 3.6
    fitness.pingpong|탁구|Table tennis|c|tan l 11 58 58 76 84;red o 42 38 32;choco! b 40 58 28 5 2 40;w o 80 28 10
    fitness.golf|골프|Golf|c|leaf e 50 80 42 13;k! e 42 80 9 3.4;w l 3.5 42 78 42 10;red p 3 42 10 76 21 42 32;w o 72 74 7
    fitness.ski|스키|Ski|c|@fitness.skis 50 50 1 -22 A=sky;@fitness.skis 50 50 1 22 A=red
    fitness.boxing|권투 글러브|Boxing glove|c|red s M24 46 C24 22 44 10 62 12 C80 14 90 32 86 50 C84 62 74 66 66 66 L30 66 Q24 56 24 46 Z;red p 3 22 44 22 30 40 26 44 46;w b 26 64 44 24 6;red! b 26 76 44 5 0
    fitness.whistle|호루라기|Whistle|m|k q 4 26 34 10 18 34 10;T s M12 38 L64 38 L88 34 Q92 34 92 40 L92 50 Q92 54 88 54 L74 54 C72 72 58 84 42 84 C24 84 12 72 12 58 Z;k! o 42 58 8
    fitness.pulse|심박 하트|Heart rate|m|T heart 50 52 86;k! l 4.5 12 50 36 50 44 34 56 66 62 50 88 50
    fitness.heart|튼튼 하트|Healthy heart|d|red heart 50 52 84;@face.smile 50 40 .8
    fitness.scale|체중계|Scale|m|T b 12 14 76 76 14;k! o 50 40 20;T! o 50 40 16;k! l 3.4 50 40 58 30;k! e 34 74 6 8;k! e 66 74 6 8
    fitness.pedometer|만보기 발자국|Step counter|m|k b 42 6 16 12 3;T b 22 14 56 76 14;k! b 30 22 40 24 5;@paw 50 66 .52 A=k
    fitness.smartwatch|운동 시계|Sport watch|m|T b 34 6 32 88 8;T b 20 24 60 52 14;k! b 28 32 44 36 8;T! l 3 32 50 42 50 47 42 54 58 58 50 68 50
    fitness.stopwatch|스톱워치|Stopwatch|m|T b 42 6 16 12 4;T b 76 18 12 12 4 45;T o 50 56 36;k! o 50 56 28;T! o 50 56 24;k! l 5 50 56 50 40;k! l 5 50 56 62 62
    fitness.pill|약|Pill|c|@fitness.capsule 44 46 .9 -35 A=red B=w;w o 74 74 14;gray! l 2.6 64 74 84 74
    fitness.pills.mono|알약|Tablet|m|@fitness.capsule 50 50 1.1 -40 A=T B=T;k! l 4 36 28 64 72
    fitness.vitamin|영양제|Vitamins|d|w b 30 8 40 18 5;orange b 20 24 60 68 12;w! b 20 42 60 32 0;orange! star 50 58 13 6 5
    fitness.bandage|밴드|Bandage|m|@travel.bandage 50 50 1 -40 A=T B=T
    fitness.thermometer|체온계|Thermometer|c|w b 42 8 16 62 8;k! l 3 58 20 52 20;k! l 3 58 32 52 32;k! l 3 58 44 52 44;red o 50 76 16;red! b 46 36 8 36 0
    fitness.cross|병원 십자|Medical cross|m|T p 5 34 10 66 10 66 34 90 34 90 66 66 66 66 90 34 90 34 66 10 66 10 34 34 34
    fitness.firstaid|구급상자|First aid kit|c|dark l 7 36 28 36 14 64 14 64 28;w b 10 26 80 62 10;red! b 44 38 12 38 2;red! b 31 51 38 12 2
    fitness.syringe|주사기|Syringe|c|@fitness.syringe 50 50 1 45
    fitness.tooth|이빨|Tooth|m|T s M28 14 C38 8 44 16 50 16 C56 16 62 8 72 14 C84 22 84 42 78 54 C74 64 74 86 66 88 C58 90 58 62 50 62 C42 62 42 90 34 88 C26 86 26 64 22 54 C16 42 16 22 28 14 Z;k! l 3.4 30 28 36 22
    fitness.tooth.smile|웃는 이빨|Smiling tooth|d|w s M28 14 C38 8 44 16 50 16 C56 16 62 8 72 14 C84 22 84 42 78 54 C74 64 74 86 66 88 C58 90 58 62 50 62 C42 62 42 90 34 88 C26 86 26 64 22 54 C16 42 16 22 28 14 Z;@face.smile 50 16 .8;pink! e 30 44 5 3;pink! e 70 44 5 3
    fitness.sleep|수면 달|Sleep moon|m|T s M62 12 C36 12 12 30 12 56 C12 78 32 92 54 92 C70 92 82 84 88 74 C62 78 46 60 46 40 C46 28 52 20 62 12 Z;T star 72 36 11 4.5 4;T star 86 16 7 3 4
    fitness.glass|물 한 잔|Glass of water|c|w p 3 22 12 78 12 70 90 30 90;sky! p 3 26 36 74 36 68 86 32 86;w! o 40 54 3.4;w! o 56 66 2.8
    fitness.apple|사과|Apple|d|brown l 5 50 30 54 14;red s M50 30 C38 18 12 24 12 50 C12 74 32 92 42 90 C46 90 48 88 50 88 C52 88 54 90 58 90 C68 92 88 74 88 50 C88 24 62 18 50 30 Z;leaf s M54 22 C60 8 74 8 80 12 C74 24 62 28 54 22 Z
    fitness.salad|샐러드|Salad|c|leaf o 28 42 15;green o 50 34 18;leaf o 72 42 15;red o 40 44 7;yellow o 62 44 6;w s M10 50 L90 50 Q88 86 62 88 L38 88 Q12 86 10 50 Z;mint! s M12 60 L88 60 Q87 66 85 70 L15 70 Q13 66 12 60 Z
    fitness.stretch|스트레칭|Stretching|m|T o 74 30 10;T q 8 56 38 44 2 88 10;T l 8 54 42 32 50;T q 12 48 60 48 46 60 38;T l 10 48 60 34 90;T l 10 48 60 66 90
    fitness.meditate|명상|Meditation|m|T o 50 18 11;T l 7 50 36 28 58 22 70;T l 7 50 36 72 58 78 70;T l 13 50 36 50 62;T b 14 66 72 20 10
    fitness.catcalm|고양이 명상|Calm cat|d|@cat.yunbok;@face.sleep;yellow! star 18 18 8 3 4;yellow! star 84 22 6 2.4 4
    fitness.medal|메달|Medal|c|red p 3 28 8 46 8 56 44 42 50;blue p 3 72 8 54 8 44 44 58 50;yellow o 50 64 27;orange! star 50 64 15 7 5
    fitness.trophy|트로피|Trophy|d|yellow q 6 28 22 4 26 32 52;yellow q 6 72 22 96 26 68 52;yellow b 44 58 12 16 2;brown b 28 72 44 18 5;yellow s M26 10 L74 10 L74 34 C74 52 62 62 50 62 C38 62 26 52 26 34 Z;orange! star 50 34 13 6 5
    """#

    static let hobbySource = #"""
    hobby.book|책|Book|m|T b 16 10 68 80 8;k! b 26 10 3.5 80 0;k! l 4 40 30 72 30;k! l 4 40 42 64 42
    hobby.book.open|펼친 책|Open book|c|sky s M50 26 C40 16 22 14 8 18 L8 78 C22 74 40 76 50 86 C60 76 78 74 92 78 L92 18 C78 14 60 16 50 26 Z;w! s M50 30 C40 22 24 20 14 22 L14 72 C26 70 42 72 50 80 C58 72 74 70 86 72 L86 22 C76 20 60 22 50 30 Z;k! l 2.4 50 30 50 80;gray! q 2.6 22 34 34 32 42 38;gray! q 2.6 22 46 34 44 42 50;gray! q 2.6 78 34 66 32 58 38;gray! q 2.6 78 46 66 44 58 50
    hobby.bookstack|책 더미|Book stack|c|red b 14 62 72 24 5;w! b 20 68 54 4 0;butter b 20 38 60 24 5;w! b 26 44 44 4 0;sky b 12 16 66 22 5;w! b 18 22 48 4 0
    hobby.gamepad|게임 패드|Game pad|m|T s M28 26 L72 26 C86 26 92 44 92 62 C92 76 82 80 74 72 L64 62 L36 62 L26 72 C18 80 8 76 8 62 C8 44 14 26 28 26 Z;k! b 22 42 18 6 1;k! b 28 36 6 18 1;k! o 68 38 4.4;k! o 78 48 4.4
    hobby.handheld|휴대용 게임기|Handheld game|c|mint b 22 8 56 84 10;dark! b 30 16 40 34 4;w! l 3 36 24 44 24;k! b 32 62 16 5 1;k! b 37.5 56.5 5 16 1;red! o 62 60 4.6;red! o 70 70 4.6
    hobby.headphones|헤드폰|Headphones|m|T q 8 18 56 50 -28 82 56;T b 8 50 22 38 10;T b 70 50 22 38 10;k! b 16 58 6 22 3;k! b 78 58 6 22 3
    hobby.headphones.cat|고양이 헤드폰|Cat headphones|d|pink p 4 22 28 24 8 40 16;pink p 4 78 28 76 8 60 16;pink q 9 18 56 50 -24 82 56;w! q 3 30 26 50 18 70 26;butter b 8 50 22 38 10;butter b 70 50 22 38 10;@travel.pawflat 19 69 .3 A=pink;@travel.pawflat 81 69 .3 A=pink
    hobby.note|음표|Music note|m|T q 10 54 16 74 18 74 46;T l 8 50 72 50 14;T e 36 74 18 15 -20
    hobby.notes|겹음표|Beamed notes|m|T l 7 36 76 36 22;T l 7 80 66 80 14;T l 13 36 24 80 14;T e 24 78 14 12 -20;T e 68 68 14 12 -20;T! l 5 36 24 36 30;T! l 5 80 16 80 22
    hobby.guitar|기타|Guitar|c|brown b 46 6 8 46 2;dark b 42 4 16 14 4;tan s M50 38 C62 38 66 46 62 52 C74 56 78 66 74 76 C70 88 58 94 50 94 C42 94 30 88 26 76 C22 66 26 56 38 52 C34 46 38 38 50 38 Z;choco! o 50 60 7;choco! b 40 76 20 5 2;brown! b 47 38 6 22 0
    hobby.piano|피아노|Piano|c|w b 8 28 84 50 7;dark b 8 22 84 16 6;gray! l 2 22 40 22 76;gray! l 2 36 40 36 76;gray! l 2 50 40 50 76;gray! l 2 64 40 64 76;gray! l 2 78 40 78 76;k! b 17 38 9 22 2;k! b 31 38 9 22 2;k! b 59 38 9 22 2;k! b 73 38 9 22 2
    hobby.mic|마이크|Microphone|m|k q 5 22 42 24 74 50 74;k q 5 78 42 76 74 50 74;k l 5 50 74 50 88;k l 6 32 90 68 90;T b 34 8 32 54 16;k! l 3.4 40 26 50 26;k! l 3.4 40 36 50 36
    hobby.karaoke|노래방 마이크|Karaoke mic|c|pink p 3 46 50 58 40 88 82 80 90;dark! b 50 42 8 8 0 45;gray o 36 34 25;k! q 2 20 26 36 36 52 26;k! q 2 20 42 36 32 52 42
    hobby.popcorn|영화 팝콘|Popcorn|c|butter o 30 32 11;butter o 50 22 13;butter o 70 32 11;butter o 40 38 10;butter o 60 38 10;red p 3 22 40 78 40 70 92 30 92;w! p 3 34 41 44 41 46 91 38 91;w! p 3 56 41 66 41 62 91 54 91
    hobby.clapper|영화 클래퍼|Clapper board|m|T b 10 44 80 46 6;T p 3 10 38 84 12 90 28 16 54;k! p 3 26 33 38 29 44 43 32 48;k! p 3 50 25 62 21 68 35 56 40;k! l 4 22 62 78 62;k! l 4 22 74 60 74
    hobby.tv|TV|TV|c|dark l 4 50 28 34 8;dark l 4 50 28 66 8;lilac b 10 26 80 60 12;sky! b 18 34 50 44 8;@face.smile 43 34 .8;k! o 78 44 4;k! o 78 58 4;dark l 6 26 88 26 92;dark l 6 74 88 74 92
    hobby.filmroll|필름 통|Film reel|m|T o 50 50 42;k! o 50 26 9;k! o 73 43 9;k! o 64 70 9;k! o 36 70 9;k! o 27 43 9;k! o 50 50 4
    hobby.filmstrip|사진 필름|Film strip|m|T b 26 8 48 84 6;k! b 30 14 5 7 1;k! b 30 28 5 7 1;k! b 30 42 5 7 1;k! b 30 56 5 7 1;k! b 30 70 5 7 1;k! b 65 14 5 7 1;k! b 65 28 5 7 1;k! b 65 42 5 7 1;k! b 65 56 5 7 1;k! b 65 70 5 7 1;k! b 39 14 22 30 3;k! b 39 52 22 30 3
    hobby.instantcamera|즉석 카메라|Instant camera|d|peach b 10 18 80 66 14;w! b 10 62 80 6 0;dark o 50 44 21;sky! o 50 44 13;w! o 45 38 4;red! o 78 32 5;k! b 18 28 14 8 2;k! b 28 73 44 4 2
    hobby.photo|즉석 사진|Instant photo|c|w b 16 8 68 84 5 -6;sky! b 25 16 50 50 2 -6;@cat.chunhyang 50 42 .46 -6;@face.smile 50 43 .46 -6;gray! l 3 32 79 66 75
    hobby.palette|그림 팔레트|Paint palette|c|tan s M50 10 C76 10 92 30 92 52 C92 66 80 70 70 66 C62 64 56 68 58 76 C60 86 54 90 46 90 C24 90 8 72 8 50 C8 28 26 10 50 10 Z;red o 34 30 8;yellow o 56 26 8;green o 74 40 8;blue o 22 50 8;pink o 32 70 8
    hobby.brush|붓|Paintbrush|c|@fitness.brush 50 50 1 40 A=tan B=blue C=gray
    hobby.brush.mono|그림 붓|Art brush|m|@fitness.brush 50 50 1 40 A=T B=T C=k
    hobby.yarn|뜨개|Yarn ball|d|tan l 5 14 24 70 86;tan l 5 86 24 30 86;tan o 13 23 3.6;tan o 87 23 3.6;pink o 50 48 34;w! q 3 22 40 44 22 66 24;w! q 3 20 54 46 30 80 38;w! q 3 28 72 52 46 82 54;w! q 3 44 80 64 60 78 62
    hobby.spool|재봉 실패|Thread spool|c|tan b 22 10 50 12 4;tan b 22 76 50 12 4;rose b 28 22 38 54 4;red! l 2 30 32 64 28;red! l 2 30 44 64 40;red! l 2 30 56 64 52;red! l 2 30 68 64 64;gray l 3 84 14 84 88;k! o 84 22 1.4
    hobby.sewing|재봉틀|Sewing machine|m|T b 8 74 84 16 5;T b 62 20 24 58 6;T b 18 18 68 24 9;T b 24 42 12 12 3;k l 3.5 30 54 30 70;k o 86 30 8;k! o 62 30 3.5
    hobby.pot|요리 냄비|Cooking pot|c|red b 8 48 12 10 4;red b 80 48 12 10 4;gray! q 3 40 22 34 16 40 10;gray! q 3 60 22 54 16 60 10;red b 16 40 68 48 10;red b 12 32 76 12 6;dark o 50 28 5
    hobby.pan|프라이팬|Frying pan|m|T l 10 62 38 90 12;T o 38 58 32;k! o 38 58 24;T! o 38 58 21;k! o 38 58 8
    hobby.chefhat|요리 모자|Chef hat|m|T o 28 34 18;T o 50 26 20;T o 72 34 18;T b 26 36 48 30 2;T b 24 62 52 26 6;T! b 28 34 44 26 0;k! l 3.4 40 72 40 80;k! l 3.4 60 72 60 80
    hobby.wateringcan|원예 물뿌리개|Watering can|m|T q 7 36 34 52 8 68 36;T l 9 28 60 10 34;T p 3 2 34 18 26 20 36;T b 26 32 54 54 8;k! l 4 34 48 72 48
    hobby.sprout|원예 새싹|Sprout pot|c|leaf l 5 50 50 50 30;leaf s M50 34 C44 16 26 12 16 16 C16 30 34 42 50 34 Z;green s M50 28 C56 12 74 8 84 12 C84 26 66 36 50 28 Z;orange p 3 24 52 76 52 68 90 32 90;choco! b 24 52 52 7 1
    hobby.fishing|낚시|Fishing|c|brown q 4.5 10 90 34 30 78 12;k l 1.8 78 12 78 42;gray q 2 78 42 76 50 70 46;sky s M54 62 C66 46 84 50 90 66 C84 80 66 84 54 68 L44 56 L46 74 Z;k! o 78 62 3;w! q 2 62 56 68 66 62 74
    hobby.rod.cat|고양이 낚싯대|Cat teaser|c|tan q 4.5 12 88 40 40 74 18;k q 2 74 18 86 26 82 44;red o 80 50 7;yellow p 3 80 54 70 80 80 74;blue p 3 80 54 92 78 80 74;peach o 26 28 15;@travel.pawflat 26 28 .3 A=red
    hobby.dice|보드게임 주사위|Dice|d|@travel.die 50 50 1.1 -12
    hobby.pawn|보드게임 말|Game piece|m|T o 50 24 15;T p 3 40 36 60 36 68 78 32 78;T b 28 74 44 14 5
    hobby.cards|카드|Playing cards|c|w b 12 18 44 64 6 -14;@travel.spade 33 49 .5 -14;w b 44 16 44 66 6 12;red! heart 66 48 26
    hobby.puzzle|퍼즐|Puzzle piece|m|T s M16 30 L38 30 C34 18 42 10 50 10 C58 10 66 18 62 30 L84 30 L84 46 C92 40 94 74 84 66 L84 88 L16 88 L16 66 C26 74 26 42 16 48 Z
    hobby.blocks|블록|Toy blocks|c|red b 14 44 12 10 2;red b 34 44 12 10 2;red b 8 52 44 34 4;butter b 58 56 12 10 2;butter b 76 56 12 10 2;butter b 54 64 38 22 4;sky b 32 14 12 10 2;sky b 50 14 12 10 2;sky b 28 22 38 22 4
    hobby.phone|스마트폰|Smartphone|m|T b 26 6 48 88 11;k! b 32 16 36 62 4;T! heart 50 46 22;k! l 4 44 86 56 86
    hobby.radio|라디오|Radio|c|k l 3.5 26 34 72 8;orange b 8 32 84 56 10;dark! o 32 60 18;gray! o 32 60 13;dark! o 32 60 5;butter! b 56 42 28 12 2;red! l 2.4 66 42 66 54;w o 62 70 6;w o 78 70 6
    hobby.record|레코드판|Record|m|T o 50 50 42;k! o 50 50 38;T! o 50 50 15;k! o 50 50 4;T! q 2 30 28 22 38 22 48;T! q 2 70 72 78 62 78 52
    hobby.diary|일기장|Diary|c|rose b 18 8 64 84 8;red! b 18 8 12 84 3;w! heart 56 42 26;red b 66 44 22 16 4;yellow o 72 52 5
    hobby.concert|공연 티켓|Concert ticket|c|@travel.ticket 50 50 1 -12 A=lilac;red! star 40 52 16 7 5
    hobby.lightstick|응원봉|Light stick|c|dark b 43 56 14 36 5;w b 40 50 20 10 3;pink o 50 30 24;w! star 50 30 15 7 5;yellow! star 14 16 7 2.6 4;yellow! star 86 20 7 2.6 4;yellow! star 84 56 5 2 4
    hobby.stargazing|망원경 별보기|Stargazing|d|navy o 50 50 42;yellow! star 26 28 8 3 5;yellow! star 72 22 6 2.4 5;w! o 44 18 2;w! o 82 44 2;@travel.scope 50 54 .78 A=w B=sky
    hobby.drone|드론|Drone|m|k l 5 34 46 16 30;k l 5 66 46 84 30;T e 16 26 12 4.5;T e 84 26 12 4.5;k l 4.5 38 62 30 76;k l 4.5 62 62 70 76;T b 30 38 40 28 10;k! o 50 52 7;T! o 48 50 2
    hobby.dart|다트|Darts|c|red o 46 54 37;w! o 46 54 27;red! o 46 54 17;w! o 46 54 8;k! o 46 54 3;gray l 3 46 54 74 26;orange p 2 74 26 84 10 90 22
    hobby.kite|연|Kite|c|pink p 3 50 8 82 38 50 70 18 38;sky! p 3 50 8 50 70 18 38;k! l 2 50 8 50 70;k! l 2 18 38 82 38;k q 2.4 50 70 34 78 46 86;yellow p 3 46 82 54 88 42 90
    hobby.chess|체스 말|Chess piece|m|T p 4 36 58 34 34 28 18 44 8 74 26 72 42 58 38 64 58;T b 24 72 52 16 5;T b 32 58 36 16 3;k! o 50 24 3
    hobby.skateboard|스케이트보드|Skateboard|m|T s M8 40 Q12 54 22 54 L78 54 Q88 54 92 40 L92 50 Q88 62 78 62 L22 62 Q12 62 8 50 Z;k o 28 74 8;k o 72 74 8;T! o 28 74 3;T! o 72 74 3
    """#
}
