# Taption Plan 개인정보처리방침

최종 업데이트: 2026-11-06

Taption Plan은 사용자가 허용한 범위에서 하루의 일정, 위치, 이동, 활동, 수면과 메모를 기기 안에서 정리합니다. 광고, 사용자 추적, 데이터 판매를 하지 않습니다.

## 처리하는 정보

- 사용자가 입력한 계획, 메모, 장소와 설정
- 허용한 경우 위치, 동작 및 피트니스, Apple Watch, 건강, 캘린더, 사진 정보
- 허용한 경우 연결된 Wi-Fi 이름(SSID), 스크린 타임 앱 사용 시간, AirPods 등 오디오 경로와 통화 시작·종료 상태, 음성 메모 녹음
- 앱 동작 확인에 필요한 오류 상태와 진단 정보
- Apple이 제공하는 구매 및 복원 상태

Wi-Fi 이름은 지하철 Wi-Fi 등 이동 수단을 추정하는 용도로만 기기에 기록하고, 스크린 타임은 사용자가 허용한 앱·카테고리 사용 시간만 기기에서 읽습니다. 음성 메모는 사용자가 녹음을 시작한 때에만 마이크를 사용하며 기기에 저장합니다. AirPods 정보는 오디오 경로 이름과 통화·재생 상태만 사용하며 통화나 음악의 내용은 기록하지 않습니다. 이 정보는 사용자가 아래의 개발자 메일로 직접 보낼 때를 빼고는 기기 밖으로 전송하지 않습니다. 구글 계정을 직접 연결하면 화면에서 연 날짜의 일정을 Google에서 읽어 기기에 저장하고, 일정 제목은 활동 판정에 씁니다. 제목 분류는 기기 안의 단어 규칙과 사용자가 고른 값으로 처리하며, 연결을 해제하면 저장한 구글 일정을 지웁니다. Apple Watch 앱은 사용자가 시작한 걷기·달리기·자전거 운동을 Apple 건강 앱에 저장할 수 있으며, iPhone 앱은 건강 데이터를 읽기만 합니다.

권한은 기능별로 요청하며 설정에서 언제든 끌 수 있습니다. 권한을 거부해도 해당 기능을 제외한 앱 기능은 사용할 수 있습니다.

## 저장과 외부 전송

- HealthKit에서 읽은 건강 데이터(수면, 심박, 운동, 걸음, 에너지, 운동 경로)와 이를 바탕으로 만든 기록은 기기에 파일 보호를 적용해 저장하며 iCloud 백업과 동기화에서 제외합니다.
- 사용자가 iCloud 동기화나 백업을 사용하면 계획, 확인된 기록, 메모, 설정과 함께 iPhone 위치 기록(이동 경로), 방문 장소와 Apple Watch 동작 센서 표본이 사용자의 비공개 iCloud 영역에 저장될 수 있습니다. 별도 백업 파일은 사용자가 정한 6자리 앱 비밀번호에서 만든 키로 AES-GCM 암호화됩니다. 비밀번호를 잊었을 때 다시 볼 수 있도록 그 6자리는 사용자의 iCloud 키체인에 보관되며, 기기 주인 확인(Face ID·Touch ID·기기 암호)을 거친 뒤에만 앱에 보입니다.
- 사용자가 「AI 연결」을 켜면 Taption Plan의 중계 서버(Cloudflare Workers, `trip.bokkiyaw.com`)를 거쳐 사용자가 고른 AI 비서와 자료를 주고받습니다. 서버에 올라가는 것은 사용자가 고른 공유 수준의 하루 기록(시간대별 활동·분류·메모·일정·목표·여행 일정·가계부 금액과 분류, 고르면 장소 이름)이며 좌표·이동 경로·주소는 보내지 않습니다. 서버는 저장하는 값을 연결 키에서 만든 키로 암호화하고, 하루 기록은 사용자가 고른 1·7·30일, AI가 보낸 여행 계획은 3일, AI가 보낸 명령과 다듬기를 맡긴 메모는 7일, 연결 안내 1회용 주소는 10분 뒤 지웁니다. 공유를 끄거나 기간을 줄이면 서버의 기록을 지우고, 연결을 끊으면 그 AI가 보내 두고 아직 반영되지 않은 명령도 지웁니다. 승인 PIN은 서버에 비밀값을 섞은 검증값으로만 남고 앱 비밀번호 자체는 서버로 가지 않습니다. 사용자가 연결한 AI 서비스(예: Claude, ChatGPT, 피클)가 받은 자료는 각 서비스의 개인정보 정책을 따릅니다.
- 국내 장소 검색어와, 이름 없는 머문 곳의 이름을 찾을 때의 좌표(식당·카페 반경 검색)는 같은 중계 서버를 거쳐 카카오 로컬 검색에 전달되며, 중계 서버는 검색어와 좌표를 저장하지 않습니다.
- 가계부 기록은 기기의 앱 저장소에 두고 백업에 함께 암호화됩니다. 환율은 중계 서버가 하루 한 번 공개 환율(Frankfurter, 유럽중앙은행 기준)을 받아 두며 사용자 정보는 보내지 않습니다. 결제 문자는 사용자가 붙여 넣거나 단축어로 넘긴 글만 읽고, 영수증 사진은 기기에서 글자만 읽고 사진과 글을 따로 남기지 않습니다.
- 날씨를 조회할 때 좌표와 조회 시각이 Apple WeatherKit에 전달됩니다. 국내 대기질은 기기에서 가까운 측정소를 고른 뒤 측정소 이름만 Taption Plan의 중계 서버(Cloudflare Workers)를 거쳐 공공데이터포털(에어코리아)에 전달하며 좌표는 보내지 않습니다. 중계 서버는 요청 내용을 저장하지 않지만, 호스팅 업체가 일반적인 네트워크 정보(IP 주소 등)를 처리할 수 있습니다. 계획 제목, 메모, 건강 기록은 전달하지 않습니다. 날씨 데이터 출처와 법적 고지는 앱의 날씨 화면과 설정에서 확인할 수 있습니다.
- 지도 표시와 장소 검색에는 Apple MapKit을, 지도 타일에는 OpenFreeMap(MapLibre)을 사용합니다. 보고 있는 지도 영역의 타일 좌표, 검색어와 일반적인 네트워크 정보(IP 주소 등)가 각 제공자에게 전달될 수 있습니다.
- 구매와 복원은 Apple StoreKit이 처리하며 Taption Plan은 결제수단 정보를 받지 않습니다.
- 사용자가 직접 진단 로그 내보내기를 실행하면 로그가 사용자의 iCloud Drive에 저장됩니다. 진단 로그에서는 제목, 메모 본문, 좌표와 원시 건강값을 제외합니다.
- 사용자가 설정에서 개발자에게 보내기를 실행하고 메일 화면에서 직접 보내면, 압축한 파일이 사용자의 메일 계정을 거쳐 support@bokkiyaw.com으로 전달됩니다. 로그 보내기에는 진단 로그가, 어제·오늘 데이터에는 그 이틀의 센서 원본(위치 기록, 이동, 활동, Wi-Fi 이름 등)과 방문 장소, 이동·활동 기록이 들어갑니다. 받은 자료는 문제 확인에만 사용하며, 삭제를 원하면 같은 주소로 요청할 수 있습니다.

Taption Plan은 자체 광고·분석 서버를 운영하지 않으며 앱 데이터를 제3자에게 판매하지 않습니다.

## 이용 목적과 보관 기간

정보는 자동 기록, 일정 연동, 지도와 경로 표시, 백업·복원, 구매 권한 확인 및 오류 진단에만 사용합니다. 기기와 iCloud의 정보는 사용자가 삭제하거나 iCloud에서 제거할 때까지 보관됩니다.

앱의 `설정 > 데이터와 개인정보 > 모든 데이터 삭제`에서 기기와 iCloud의 Taption Plan 데이터를 삭제할 수 있습니다. 구매 내역은 Apple 계정에 남으며 Apple 정책에 따라 관리됩니다.

## 보호 조치

기기 파일 보호, Keychain·Face ID 기반 키 보호, 암호화 백업, 무결성 검사와 세대 기반 복원 검증을 사용합니다. 인터넷 전송은 운영체제가 제공하는 암호화 연결을 사용합니다.

## Google 사용자 데이터

사용자가 앱에서 구글 계정을 직접 연결한 경우에만 Google Calendar API의 `https://www.googleapis.com/auth/calendar.readonly` 범위를 요청합니다. 쓰기·삭제 권한은 요청하지 않습니다.

- **읽는 정보:** 구글 캘린더에서 표시로 켠 캘린더 목록과, 화면에서 연 날짜의 일정(제목, 시작·종료 시각, 종일 여부, 캘린더 이름).
- **사용 목적:** 그날 일정을 지도 홈과 일정 목록에 보여 주고, 일정 시간대의 활동(업무, 수업 등)을 판정합니다. 제목 분류는 기기 안의 단어 규칙과 사용자가 고른 값으로만 처리합니다.
- **전송과 공유:** 구글 일정은 Google 서버와 사용자 기기 사이에서만 오갑니다. 개발자 서버로 보내지 않고, 제3자에게 판매·공유하지 않으며, 광고, 신용 평가, AI·머신러닝 모델 학습에 쓰지 않습니다. 개발자를 포함한 사람이 열람하지 않습니다.
- **저장:** 받은 일정은 기기 안 앱 데이터베이스에 저장합니다. 사용자가 iCloud 백업을 켜면 일정이 다른 앱 데이터와 함께 사용자의 비공개 iCloud 영역에 AES-GCM으로 암호화된 백업에 포함될 수 있습니다.
- **보관과 삭제:** 연결을 해제하면 구글 쪽 토큰 권한을 취소하고, 기기에 저장한 구글 일정과 일정 제목으로 만든 판정 근거를 지웁니다. `모든 데이터 삭제`를 실행해도 지워집니다. 사용자는 구글 계정의 보안 설정에서도 언제든 권한을 취소할 수 있습니다.

### 민감한 데이터 보호 조치

- 로그인은 OAuth 2.0 PKCE로 처리하며 앱은 구글 비밀번호를 보거나 저장하지 않습니다.
- 갱신 토큰은 iOS Keychain에 `이 기기에서만, 첫 잠금 해제 후`(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) 접근 조건으로 저장해 다른 기기나 백업으로 옮겨지지 않습니다. 접근 토큰은 메모리에만 두고 만료 전에 갱신합니다.
- 모든 Google API 요청은 HTTPS(TLS)로만 보냅니다.
- 앱 데이터는 iOS 데이터 보호(파일 암호화)가 적용된 앱 전용 저장소에 두며, 다른 앱은 읽을 수 없습니다. 별도 백업 파일은 AES-GCM으로 암호화하고 무결성을 검사합니다.
- 진단 로그와 개발자에게 보내는 로그에는 일정 제목과 일정 내용을 넣지 않습니다.

Taption Plan의 Google API 데이터 사용은 [Google API 서비스 사용자 데이터 정책](https://developers.google.com/terms/api-services-user-data-policy)과 그 제한된 사용(Limited Use) 요구사항을 따릅니다.

### Google user data (English)

Taption Plan (BOKKI Plan) requests the read-only Google Calendar scope `https://www.googleapis.com/auth/calendar.readonly` only when the user connects a Google account in the app. It never requests write or delete access.

- **Data accessed:** the list of calendars the user has set as visible, and the events (title, start and end time, all-day flag, calendar name) for the day the user opens.
- **Purpose:** show that day's schedule on the map home and schedule list, and classify the user's activity (for example work or class) during those events. Title classification runs on the device with built-in keyword rules and the user's own choices.
- **Transfer and sharing:** calendar data moves only between Google's servers and the user's device. It is not sent to any developer server, not sold or shared with third parties, not used for advertising, credit decisions, or training AI/ML models, and not read by any person, including the developer.
- **Storage:** events are stored in the app's on-device database. If the user turns on iCloud backup, they may be included in the user's private, AES-GCM encrypted iCloud backup together with other app data.
- **Retention and deletion:** disconnecting revokes the Google token and deletes the stored Google events and the activity evidence derived from their titles. "Delete all data" in the app also removes them. Users can also revoke access at any time in their Google Account security settings.

**Protection of sensitive data**

- Sign-in uses OAuth 2.0 with PKCE; the app never sees or stores the Google password.
- The refresh token is stored in the iOS Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so it never leaves the device or moves through backups. The access token is kept in memory only and refreshed before it expires.
- All Google API requests use HTTPS (TLS) only.
- App data is kept in the app's sandboxed storage protected by iOS Data Protection (file encryption) and cannot be read by other apps. Separate backup files are encrypted with AES-GCM and integrity-checked.
- Diagnostic logs and logs sent to the developer exclude event titles and event contents.

Taption Plan's use of information received from Google APIs adheres to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements.

## 아동의 개인정보

Taption Plan은 아동을 대상으로 만든 서비스가 아니며, 고의로 아동의 정보를 수집하지 않습니다.

## 문의

개인정보 관련 문의는 [Taption Plan 지원](SUPPORT.md)을 이용해 주세요. 공개 이슈에는 위치, 건강 정보, 일정 내용이나 진단 로그를 올리지 마세요.

