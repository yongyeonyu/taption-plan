# APS1115A01 — App Store 스크린샷·미리보기 영상·홍보 영상

2026-11-15~16. 대표 지시 「일레븐랩스 크레딧으로 이미지·영상 생성, 앱스토어 이미지·영상 업데이트」.

## 만든 것

| 종류 | 위치 | 규격 |
| --- | --- | --- |
| iPhone 스크린샷 6장 | `output/iphone/NN-*.png` | 1290×2796 (6.7·6.9형 칸) |
| iPhone Duo 스크린샷 6장(초안) | `output/duo/NN-*.png` | 2007×2853 (`APP_IPHONE_DUO` 칸으로 시도). 화면은 iPhone 캡처 |
| iPad 스크린샷 6장(초안) | `output/ipad/NN-*.png` | 2064×2752 (13형 칸). 화면은 iPhone 캡처라 iPad 화면 캡처로 바꿔야 함 |
| 앱 미리보기 영상 | `output/preview/app-preview-iphone.mp4` | 886×1920, 30fps, H.264, 30초 이하, AAC 스테레오 |
| 홍보 영상(App Store 밖) | `output/promo/bokki-plan-promo.mp4` | 1080×1920, 일레븐랩스 생성 장면 + 스크린샷 |

## 재료

- `source/backgrounds/`: 일레븐랩스 이미지(Seedream 5.5, 9:16 2K) 배경 6장과 16:9 넓은 배경 `bg-pano.jpg`(검색 결과에 나란히 보이는 1~3번이 나눠 씀). 앱 아이콘 색(먼지 장밋빛 #C76D86·남색 #0F2A57·크림 #F5DFC2)으로 지어낸 그림, 글자 없음.
- `source/promo-clips/`: 일레븐랩스 영상(Gemini Omni Flash 1.2, 5초 9:16 720p) 3편 — 배경 그림을 시작 프레임으로 움직임.
- `source/music/`: 일레븐랩스 뮤직(v2.5, 30초) 2곡. 미리보기·홍보 영상 음악.
- 앱 화면: 빌드 347 Debug를 시뮬레이터(BOKKI-STL)에서 지어낸 견본 자료로 찍은 것(`build/validation/APS1115A01/captures/`, git 무시). 위치는 서울시청 앞 공공 좌표.
- 앱 미리보기 녹화: `xcrun simctl io … recordVideo --codec=h264`로 찍은 장면과 `clips.txt`(파일 시작초 길이)를 `preview.sh <녹화 폴더> <음악> <출력>`에 넘긴다. 녹화 원본은 외장 볼륨에만 두고 저장소에 넣지 않는다.
- 문구: `copy.json`. 합성: `compose.py <캡처 폴더> <출력 폴더>`. 미리보기 영상: `preview.sh`.

## 주의

- App Store 미리보기 영상에는 Apple 규정상 앱 화면 녹화만 넣었다. 일레븐랩스 생성 장면은 홍보 영상에만 쓴다.
- AI 연결 화면(05)에 다른 회사 AI 서비스 이름이 보인다. 심사에서 문제 되면 다른 화면으로 바꾼다.
- App Store Connect 올리기는 대표 확인 뒤에만 한다.
