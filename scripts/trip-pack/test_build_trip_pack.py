import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import build_trip_pack as b

FIXTURE = Path(__file__).resolve().parents[2] / "seed" / "trip" / "_fixture"


def seed_with(**changes):
    seed = json.loads((FIXTURE / "seed.json").read_text(encoding="utf-8"))
    seed.update(changes)
    return seed


def write(seed):
    tmp = Path(tempfile.mkdtemp())
    (tmp / "seed.json").write_text(json.dumps(seed, ensure_ascii=False), encoding="utf-8")
    return tmp


class BuildTripPackTests(unittest.TestCase):
    def test_builds_items_and_index_deterministically(self):
        out1, out2 = Path(tempfile.mkdtemp()), Path(tempfile.mkdtemp())
        i1, t1 = b.build(FIXTURE, out1)
        i2, t2 = b.build(FIXTURE, out2)
        self.assertEqual((t1 / "items.json").read_bytes(), (t2 / "items.json").read_bytes())
        self.assertEqual(i1, i2)
        self.assertEqual(i1["count"], 3)
        self.assertEqual(i1["categories"], {"restaurant": 1, "sight": 1, "stay": 1})
        self.assertEqual(i1["generatedAt"], "2026-11-03", "생성 시각은 가장 늦은 확인일이라 같은 입력이면 같다")
        self.assertEqual(i1["archive"]["key"], "packs/trip/fixture-city/1/items.json")

    def test_empty_city_makes_no_pack(self):
        with self.assertRaises(b.SeedError):
            b.load_seed(write(seed_with(items=[])) / "seed.json")

    def test_checked_fields_are_required_and_checkedby_is_not_identifying(self):
        seed = seed_with()
        del seed["items"][0]["checkedAt"]
        with self.assertRaises(b.SeedError):
            b.load_seed(write(seed) / "seed.json")
        for bad in ["someone@example.test", "010-1234-5678", ""]:
            seed = seed_with()
            seed["items"][0]["checkedBy"] = bad
            with self.assertRaises(b.SeedError, msg=bad):
                b.load_seed(write(seed) / "seed.json")

    def test_api_sources_and_unknown_fields_are_refused(self):
        seed = seed_with()
        seed["items"][0]["source"] = "rakuten_travel"
        with self.assertRaises(b.SeedError):
            b.load_seed(write(seed) / "seed.json")
        seed = seed_with()
        seed["items"][0]["rawApiResponse"] = {"x": 1}
        with self.assertRaises(b.SeedError):
            b.load_seed(write(seed) / "seed.json")

    def test_category_must_be_declared_ids_unique_and_coordinates_in_range(self):
        seed = seed_with()
        seed["items"][0]["category"] = "undeclared"
        with self.assertRaises(b.SeedError):
            b.load_seed(write(seed) / "seed.json")
        seed = seed_with()
        seed["items"][1]["id"] = seed["items"][0]["id"]
        with self.assertRaises(b.SeedError):
            b.load_seed(write(seed) / "seed.json")
        seed = seed_with()
        seed["items"][0]["lat"] = 123
        with self.assertRaises(b.SeedError):
            b.load_seed(write(seed) / "seed.json")

    def test_links_must_be_https_and_phone_shape_is_checked(self):
        seed = seed_with()
        seed["items"][0]["photo"] = "http://example.test/x.jpg"
        with self.assertRaises(b.SeedError):
            b.load_seed(write(seed) / "seed.json")
        seed = seed_with()
        seed["items"][0]["phone"] = "call me maybe"
        with self.assertRaises(b.SeedError):
            b.load_seed(write(seed) / "seed.json")


if __name__ == "__main__":
    unittest.main()
