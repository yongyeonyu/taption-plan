# 스티커 그리기 안내

스티커는 외부 이미지 없이 100×100 격자의 벡터 문구로 그린다. 해석기는 `TaptionPlan/UI/StickerArtEngine.swift`, 목록은 `StickerCatalog.swift`, 그림은 `StickerArt*.swift`.

```bash
bash scripts/sticker-sheet/run.sh <출력 폴더> [분류 id…]
```

## 한 줄 형식
`id|한글 이름|English|스타일|층;층;층`
- 스타일 `m`: 단색 2D, 색 변경 가능. 색은 `T`(사용자 색)와 `k`(검정)만 쓴다.
- 스타일 `c`: 다색 2D, 색 변경 없음. `T`를 쓰지 않는다.
- 스타일 `d`: 입체(위 밝음·아래 어두움·광택 자동). 색 변경 없음. `T`를 쓰지 않는다.
- id는 전체에서 유일한 `분류.이름`. 저장되는 값이므로 한번 정하면 바꾸지 않는다. `;`·`|`는 글자에 쓸 수 없다.

## 층
`색 모양 인자…`. 색 뒤 `!`는 테두리 없음(볼터치·무늬·광택 같은 안쪽 장식).
- 색: `T k w cream rose sky mint butter lilac peach red orange yellow green leaf blue navy purple pink brown tan choco gray dark`, `#RRGGBB`
- `o cx cy r` 원, `e cx cy rx ry [각도]` 타원, `b x y w h r [각도]` 둥근 사각(x,y는 왼쪽 위)
- `p 둥글기 x y x y…` 다각형(둥글기 3 이상), `s M x y L x y Q cx cy x y C a b c d x y Z` 자유 경로(절대 좌표)
- `l 굵기 x y x y…` 선, `q 굵기 x0 y0 cx cy x1 y1` 곡선, `t cx cy 크기 글자` 글자(가운데 정렬, 폭 84 넘으면 줄어듦)
- `star cx cy R r n [각도]` 별, `heart cx cy 폭` 하트
- `@파츠 cx cy 배율 [각도] [A=색 B=색]` 파츠(파츠는 (50,50)이 가운데). 공용 파츠: `paw`(A), `cat.hwarang`, `cat.chunhyang`, `cat.yunbok`, `face.smile|happy|love|sleep|cry|angry|wow|wink`

바깥 검은 테두리는 엔진이 자동으로 두른다. 앞 층이 뒤 층에 덮인다.

## 그림 기준
- 앱 메뉴 아이콘과 같은 느낌: 끝이 둥글고 통통한 면, 적은 선, 44pt에서도 읽히는 큰 모양. 그림은 8~92 안에 둔다.
- 고양이 느낌을 곳곳에: 물건에 고양이 귀·발바닥, 작은 표정.
- 흔한 소재를 참고하되 특정 상품·캐릭터·브랜드 그림과 로고는 넣지 않는다.
- 고양이: 화랑이(수컷 흰색), 춘향이(암컷 삼색·호박색 눈), 윤복이(암컷 줄무늬·흰 가슴·흰 양말).
