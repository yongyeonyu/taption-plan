#!/usr/bin/env python3
"""위치 아이콘 8종(사용자·집·회사·학교·학원·운동·취미·식당)을 앱 그림체 SVG 자산으로 만든다(ICN1102A01).
화랑이·모자와 같은 진한 갈색 윤곽선과 납작한 면 색을 쓴다."""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "TaptionPlan/Assets.xcassets/PlaceIcons")
O = "#5A4033"
# 집 그림과 같은 연두색 바닥 받침
BASE = '<ellipse cx="32" cy="55" rx="27" ry="6.5" fill="#BCCB9B" stroke-width="2.2"/><path d="M14 54c6 1.6 14 2 22 1.6" fill="none" stroke="#E4EBCF" stroke-width="1.6"/>'


def S(body):
    return f'<g stroke="{O}" stroke-width="2.4" stroke-linejoin="round" stroke-linecap="round">{BASE}{body}</g>'


ICONS = {
    # 지도 핀과 화랑이 발바닥
    "user": S('<path d="M32 54C22 42 14 34 14 24a18 18 0 0 1 36 0c0 10-8 18-18 30z" fill="#E9A0AE"/>'
              '<path d="M20 22c0-7 5-11 11-12" fill="none" stroke="#F7D5DB" stroke-width="2.2"/>'
              '<ellipse cx="32" cy="28" rx="6.4" ry="5" fill="#FFF7EC" stroke-width="1.8"/>'
              '<circle cx="23.5" cy="20.5" r="2.7" fill="#FFF7EC" stroke-width="1.8"/><circle cx="32" cy="16.5" r="2.9" fill="#FFF7EC" stroke-width="1.8"/><circle cx="40.5" cy="20.5" r="2.7" fill="#FFF7EC" stroke-width="1.8"/>'),
    # 빨간 지붕 오두막
    "home": S('<rect x="41" y="9" width="7" height="14" rx="1.2" fill="#B08A72"/>'
              '<path d="M14 28h36v26H14z" fill="#F6E8CC"/>'
              '<path d="M7 31c8-7 17-16 25-24 8 8 17 17 25 24-1 1.6-2.6 2-4 1.6H11c-1.4.4-3 0-4-1.6z" fill="#C8715A"/>'
              '<path d="M18 26c5-5 9-9 14-14" fill="none" stroke="#E0A08C" stroke-width="2"/>'
              '<path d="M26.5 54V41c0-6.5 11-6.5 11 0v13z" fill="#A47C52"/><circle cx="34.6" cy="47" r="1.2" fill="#E7BE6A" stroke-width="1"/>'
              '<rect x="17" y="36" width="6.5" height="6.5" rx="1.4" fill="#BBD5D8" stroke-width="1.8"/><rect x="40.5" y="36" width="6.5" height="6.5" rx="1.4" fill="#BBD5D8" stroke-width="1.8"/>'),
    # 창이 있는 빌딩과 낮은 동
    "company": S('<rect x="11" y="29" width="16" height="25" rx="1.6" fill="#B9C6C2"/><rect x="24" y="7" width="29" height="47" rx="2" fill="#7C98A6"/>'
                 '<path d="M30.5 14h5.5v6h-5.5zM41 14h5.5v6H41zM30.5 25h5.5v6h-5.5zM41 25h5.5v6H41zM30.5 36h5.5v6h-5.5zM41 36h5.5v6H41z" fill="#F3E2AE" stroke-width="1.6"/>'
                 '<path d="M15 36h8M15 43h8" fill="none" stroke-width="2"/><path d="M34.5 54v-6h8v6" fill="#55707E" stroke-width="2"/>'),
    # 학사모
    "school": S('<path d="M17 29v13c0 8 30 8 30 0V29z" fill="#5C6F8E"/>'
                '<path d="M32 11 5 24.5 32 38l27-13.5z" fill="#73899F"/><path d="M15 24.5 32 16" fill="none" stroke="#A9BAC6" stroke-width="2"/>'
                '<path d="M52 28v13" fill="none" stroke-width="2.2"/><circle cx="52" cy="44" r="3.1" fill="#E3B65C" stroke-width="1.9"/>'),
    # 펼친 책과 연필
    "academy": S('<path d="M32 21c-6.5-6-17-7-25-5v31c8-2 18.5-1 25 5 6.5-6 17-7 25-5V16c-8-2-18.500-1-25 5z" fill="#FBF3DF"/>'
                 '<path d="M32 21v31" fill="none" stroke-width="2"/>'
                 '<path d="M12.500 24c5-.8 9.500 0 14 2M12.500 32c5-.8 9.500 0 14 2M12.500 40c5-.8 9.500 0 14 2M37.500 26c4.500-2 9-2.800 14-2" fill="none" stroke="#C4B79C" stroke-width="1.9"/>'
                 '<path d="M56 7l4.500 4.500-15.500 22-6.500 2.500 2-7z" fill="#E3B65C" stroke-width="2"/><path d="M52.500 12l4.500 4.500" fill="none" stroke-width="1.8"/>'),
    # 덤벨
    "exercise": S('<rect x="19" y="26" width="26" height="8" rx="2" fill="#B6BFC0"/>'
                  '<rect x="12" y="14" width="9" height="32" rx="3.4" fill="#C8715A"/><rect x="43" y="14" width="9" height="32" rx="3.4" fill="#C8715A"/>'
                  '<rect x="5" y="20" width="7.500" height="20" rx="3" fill="#A95B47"/><rect x="51.500" y="20" width="7.500" height="20" rx="3" fill="#A95B47"/>'
                  '<path d="M15 19v10M46 19v10" fill="none" stroke="#E0A08C" stroke-width="1.8"/>'),
    # 물감 팔레트
    "hobby": S('<path d="M32 9C18 9 8 19 8 31c0 12 10 21 22 21 5.500 0 6.500-3.500 4.500-7-2-4.500 1-8 6.500-8h5.500c6.500 0 10-3.500 10-9C56.500 16.500 45.500 9 32 9z" fill="#DDBB8A"/>'
               '<circle cx="21" cy="23" r="4" fill="#C8715A" stroke-width="1.8"/><circle cx="33" cy="18" r="4" fill="#E3B65C" stroke-width="1.8"/>'
               '<circle cx="45" cy="23" r="4" fill="#8DAA6C" stroke-width="1.8"/><circle cx="18" cy="36" r="4" fill="#73899F" stroke-width="1.8"/>'),
    # 줄무늬 차양 식당
    "restaurant": S('<path d="M12 26h40v28H12z" fill="#F6E8CC"/>'
                    '<path d="M11 8h42l6 15c0 6-54 6-54 0z" fill="#FBF3DF"/>'
                    '<path d="M19 8l-3 19c-4 1.800-8.500 1-11-3.500zM36 8l.8 19.500c-3.500 1.600-8 1.600-11 0L28 8zM53 8l6 15.500c-2.500 4.500-7 5.300-11 3.500L45 8z" fill="#C8715A" stroke-width="2"/>'
                    '<path d="M21 35v6M24.500 35v6M28 35v6M21 41c0 3 7 3 7 0M24.500 44v10" fill="none" stroke-width="2"/>'
                    '<path d="M41 54V35c-5 2-5 10 0 12.500" fill="#B6BFC0" stroke-width="2"/>'),
}

VIEW = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">{}</svg>'


def asset_name(icon):
    return "PlaceIcon_" + icon


def write_assets():
    os.makedirs(ASSETS, exist_ok=True)
    with open(os.path.join(ASSETS, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
    for icon, body in ICONS.items():
        d = os.path.join(ASSETS, asset_name(icon) + ".imageset")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "icon.svg"), "w") as f:
            f.write(VIEW.format(body))
        with open(os.path.join(d, "Contents.json"), "w") as f:
            json.dump({"images": [{"filename": "icon.svg", "idiom": "universal"}],
                       "info": {"author": "xcode", "version": 1},
                       "properties": {"preserves-vector-representation": True}}, f, indent=2)


if __name__ == "__main__":
    assert len(ICONS) == 8
    write_assets()
    print("icons", len(ICONS))
