extension StickerCatalog {
    /// 다녀온 곳 기록: 별점·맛집 평가·재방문 표시. 지도 메모에 남기는 다꾸 소재다.
    static let placesSource = #"""
    places.star1|별점 1|1 star|m|T star 50 52 40 19 5
    places.star2|별점 2|2 stars|m|T star 29 52 22 10.5 5;T star 71 52 22 10.5 5
    places.star3|별점 3|3 stars|m|T star 50 31 22 10.5 5;T star 27 69 21 10 5;T star 73 69 21 10 5
    places.star4|별점 4|4 stars|m|T star 28 30 20 9.5 5;T star 72 30 20 9.5 5;T star 28 72 20 9.5 5;T star 72 72 20 9.5 5
    places.star5|별점 5|5 stars|m|T star 22 32 16 7.5 5;T star 50 32 16 7.5 5;T star 78 32 16 7.5 5;T star 36 68 16 7.5 5;T star 64 68 16 7.5 5
    places.tasty|맛집|Tasty spot|m|T o 50 50 40;k! t 50 51 32 맛집
    places.best|인생 맛집|Best ever|m|T star 50 50 42 32 10;k! t 50 42 19 인생;k! t 50 62 19 맛집
    places.again|또 갈래|Going back|m|T b 8 26 84 48 20;k! t 50 51 22 또 갈래
    places.revisit|재방문|Revisit|m|T b 8 26 84 48 20;k! t 50 51 24 재방문
    places.menu|추천 메뉴|Must order|m|T b 16 10 68 80 12;k! t 50 37 21 추천;k! t 50 63 21 메뉴
    places.wait|웨이팅|Long wait|m|T b 8 26 84 48 12;k! t 50 51 22 웨이팅
    places.value|가성비|Good value|m|T b 8 26 84 48 12;k! t 50 51 24 가성비
    places.mood|분위기|Nice mood|m|T b 8 26 84 48 24;k! t 50 51 24 분위기
    places.solo|혼밥|Solo meal|m|T o 50 50 40;k! t 50 51 34 혼밥
    places.date|데이트|Date|m|T heart 50 50 84;k! t 50 44 22 데이트
    places.friend|친구랑|With friends|m|T b 8 26 84 48 24;k! t 50 51 24 친구랑
    places.family|가족과|With family|m|T b 8 26 84 48 24;k! t 50 51 24 가족과
    places.meh|아쉬움|So-so|m|T b 8 26 84 48 12;k! t 50 51 24 아쉬움
    places.photo|사진 명소|Photo spot|m|T b 12 26 76 56 12;T b 34 14 32 16 6;k! o 50 54 16;T o 50 54 9
    places.visited|다녀옴|Visited|m|T o 50 50 40;k! o 50 50 31;T o 50 50 27;k! l 7 34 50 46 62 67 38
    places.reserve|예약|Reserved|m|T b 12 18 76 68 12;k! l 5 30 10 30 26;k! l 5 70 10 70 26;k! t 50 58 28 예약
    places.spoon|식사|Meal|m|T e 34 28 13 19;T l 8 34 44 34 88;T l 8 66 12 66 88;k! l 3 60 12 60 30;k! l 3 72 12 72 30
    places.pin.heart|하트 핀|Heart pin|m|T s M50 92 C40 74 20 60 20 38 C20 20 33 8 50 8 C67 8 80 20 80 38 C80 60 60 74 50 92 Z;k! heart 50 38 28
    places.pin.star|별 핀|Star pin|m|T s M50 92 C40 74 20 60 20 38 C20 20 33 8 50 8 C67 8 80 20 80 38 C80 60 60 74 50 92 Z;k! star 50 38 17 8 5
    places.pin.paw|발바닥 핀|Paw pin|m|T s M50 92 C40 74 20 60 20 38 C20 20 33 8 50 8 C67 8 80 20 80 38 C80 60 60 74 50 92 Z;@paw 50 34 0.55 A=k
    places.pin.fork|식당 핀|Restaurant pin|m|T s M50 92 C40 74 20 60 20 38 C20 20 33 8 50 8 C67 8 80 20 80 38 C80 60 60 74 50 92 Z;k! l 3.6 44 24 44 34 50 40 50 54;k! l 3.6 50 24 50 40;k! l 3.6 56 24 56 34 50 40
    places.cat.yum|화랑이 맛있다|Hwarang yum|d|@cat.hwarang 50 50 1;k q 3 29 56 36 47 43 56;k q 3 57 56 64 47 71 56;red! e 50 68 6 7;k q 2.6 44 64 50 66 56 64
    places.cat.best|춘향이 최고|Chunhyang best|d|@cat.chunhyang 50 54 0.95;@face.love 50 54 0.95;yellow star 82 18 13 6 5
    places.cat.again|윤복이 또 올래|Yunbok again|d|@cat.yunbok 50 54 0.95;@face.happy 50 54 0.95;red heart 82 20 20
    """#
}
