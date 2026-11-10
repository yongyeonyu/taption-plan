#!/usr/bin/env python3
"""도감의 명소·시·도·종류 이름을 12개 언어 팩에 넣는다(PLB1109A04).

고유 이름은 Wikidata 라벨을 쓰고, 라벨이 없으면 영어 이름 그대로 둔다. 기존 번역은 덮어쓰지 않는다.
"""
import json
import pathlib
import time
import urllib.parse
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
TRANS = HERE.parents[1] / "scripts/l10n/translations"
API = "https://www.wikidata.org/w/api.php"
LANGS = {"ja": ["ja"], "zh-Hans": ["zh-hans", "zh-cn", "zh"], "zh-Hant": ["zh-hant", "zh-tw", "zh-hk", "zh"], "de": ["de"], "fr": ["fr"],
         "it": ["it"], "es": ["es"], "pt-BR": ["pt-br", "pt"], "vi": ["vi"], "id": ["id"], "th": ["th"], "hi": ["hi"]}
REGIONS = {"Seoul": "Q8684", "Busan": "Q16520", "Daegu": "Q20927", "Incheon": "Q20934", "Gwangju": "Q41283", "Daejeon": "Q20921",
           "Ulsan": "Q41278", "Sejong": "Q20929", "Gyeonggi": "Q20937", "Gangwon": "Q41071", "Chungbuk": "Q41066", "Chungnam": "Q41070",
           "Jeonbuk": "Q41157", "Jeonnam": "Q41161", "Gyeongbuk": "Q41151", "Gyeongnam": "Q41152", "Jeju": "Q41164"}
THEMES = {
    "Landmarks": dict(zip(LANGS, ["名所", "名胜", "名勝", "Sehenswürdigkeiten", "Sites", "Attrazioni", "Lugares", "Pontos turísticos", "Danh thắng", "Tempat wisata", "สถานที่สำคัญ", "दर्शनीय स्थल"])),
    "Mountains": dict(zip(LANGS, ["山", "山", "山", "Berge", "Montagnes", "Montagne", "Montañas", "Montanhas", "Núi", "Gunung", "ภูเขา", "पर्वत"])),
    "Temples": dict(zip(LANGS, ["寺院", "寺庙", "寺廟", "Tempel", "Temples", "Templi", "Templos", "Templos", "Chùa", "Kuil", "วัด", "मंदिर"])),
    "Islands": dict(zip(LANGS, ["島", "岛屿", "島嶼", "Inseln", "Îles", "Isole", "Islas", "Ilhas", "Đảo", "Pulau", "เกาะ", "द्वीप"])),
    "Sea": dict(zip(LANGS, ["海", "海", "海", "Meer", "Mer", "Mare", "Mar", "Mar", "Biển", "Laut", "ทะเล", "समुद्र"])),
    "Trees & forests": dict(zip(LANGS, ["木・森", "树木·森林", "樹木·森林", "Bäume & Wälder", "Arbres et forêts", "Alberi e foreste", "Árboles y bosques", "Árvores e florestas", "Cây & rừng", "Pohon & hutan", "ต้นไม้และป่า", "पेड़ और वन"])),
    "Scenic drives": dict(zip(LANGS, ["ドライブ", "自驾路线", "自駕路線", "Panoramastraßen", "Routes panoramiques", "Strade panoramiche", "Rutas panorámicas", "Estradas panorâmicas", "Cung đường đẹp", "Jalur indah", "เส้นทางชมวิว", "सुंदर सड़कें"])),
    "Airports": dict(zip(LANGS, ["空港", "机场", "機場", "Flughäfen", "Aéroports", "Aeroporti", "Aeropuertos", "Aeroportos", "Sân bay", "Bandara", "สนามบิน", "हवाई अड्डे"])),
}
EXTRA = {"현실 모드로 돌아가기|Back to everyday mode": dict(zip(LANGS, ["日常モードに戻る", "返回日常模式", "返回日常模式", "Zurück zum Alltagsmodus", "Retour au mode quotidien", "Torna alla modalità quotidiana", "Volver al modo diario", "Voltar ao modo diário", "Về chế độ thường ngày", "Kembali ke mode harian", "กลับสู่โหมดปกติ", "सामान्य मोड पर लौटें"])),
         "|Cities": dict(zip(LANGS, ["都市", "城市", "城市", "Städte", "Villes", "Città", "Ciudades", "Cidades", "Thành phố", "Kota", "เมือง", "शहर"]))}


def labels(qids):
    out = {}
    for start in range(0, len(qids), 50):
        query = urllib.parse.urlencode({"action": "wbgetentities", "ids": "|".join(qids[start:start + 50]), "props": "labels", "format": "json"})
        request = urllib.request.Request(f"{API}?{query}", headers={"User-Agent": "taption-place-book-build/1.0"})
        with urllib.request.urlopen(request, timeout=60) as response:
            out.update(json.load(response).get("entities", {}))
        time.sleep(1.2)
    return out


def main():
    rows = [line.split("\t") for line in (HERE / "places.tsv").read_text(encoding="utf-8").splitlines() if line.strip()]
    english = {row[1]: row[3] for row in rows}
    qids = json.loads((HERE / "qids.json").read_text(encoding="utf-8"))
    wanted = sorted({q for q in qids.values() if q.startswith("Q")} | set(REGIONS.values()))
    entities = labels(wanted)
    def pick(qid, codes):
        found = entities.get(qid, {}).get("labels", {})
        return next((found[c]["value"] for c in codes if c in found), None)
    total = hit = 0
    for lang, codes in LANGS.items():
        path = TRANS / f"{lang}.json"
        data = json.loads(path.read_text(encoding="utf-8"))
        ui = data["ui"]
        for place, qid in qids.items():
            name = english[place]
            value = pick(qid, codes) if qid.startswith("Q") else None
            total += 1
            hit += value is not None
            ui.setdefault(f"|{name}", value or name)
        for name, qid in REGIONS.items():
            ui.setdefault(f"|{name}", pick(qid, codes) or name)
        for name, values in THEMES.items():
            ui.setdefault(f"|{name}", values[lang])
        for key, values in EXTRA.items():
            ui.setdefault(key, values[lang])
        path.write_text(json.dumps(data, ensure_ascii=False, indent=0), encoding="utf-8")
    print(f"라벨 {hit}/{total}")


if __name__ == "__main__":
    main()
