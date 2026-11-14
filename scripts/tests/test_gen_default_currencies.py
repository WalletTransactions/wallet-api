"""Тесты генератора общего справочника валют (change default-reference-currencies).

Запуск: python3 -m unittest discover -s scripts/tests -v   (из wallet-api/)
Сверка с seed.json телефона идёт, если рядом лежит android-wallet (или задана
переменная ANDROID_WALLET); без него этот тест пропускается.
"""
import importlib.util
import json
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(SCRIPTS, name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


cur = load("gen_default_currencies")
icons = load("gen_default_icons")


def android_dir():
    path = os.environ.get("ANDROID_WALLET") or os.path.join(cur.ROOT, "..", "android-wallet")
    seed = os.path.join(path, "app", "src", "main", "assets", "seed.json")
    return path if os.path.exists(seed) else None


class ManifestTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = cur.load_manifest()

    def test_pairs_reference_known_currencies_and_symbol_is_base_plus_quote(self):
        isos = {c["iso"] for c in self.manifest["currencies"]}
        for p in self.manifest["pairs"]:
            self.assertIn(p["base"], isos, p["symbol"])
            self.assertIn(p["quote"], isos, p["symbol"])
            self.assertEqual(p["symbol"], p["base"] + p["quote"])
            self.assertNotEqual(p["base"], p["quote"])

    def test_every_currency_icon_is_in_the_default_icon_set(self):
        # Валюта без иконки пропускается миграцией, а пара без валюты — тоже: набор иконок
        # (000037/000038) обязан покрывать все флаги справочника.
        names = {m["name"].lower() for m in icons.load_manifest()}
        for c in self.manifest["currencies"]:
            self.assertIn(c["icon"].lower(), names, f"{c['iso']}: иконки «{c['icon']}» нет в наборе иконок")

    def test_precision_in_range_and_crypto_has_eight(self):
        by_iso = {c["iso"]: c["precision"] for c in self.manifest["currencies"]}
        for iso, precision in by_iso.items():
            self.assertTrue(0 <= precision <= 8, iso)
        self.assertEqual(by_iso["BTC"], 8)
        self.assertEqual(by_iso["LTC"], 8)
        self.assertEqual(by_iso["EUR"], 2)

    @unittest.skipIf(android_dir() is None, "рядом нет android-wallet")
    def test_matches_phone_seed(self):
        with open(os.path.join(android_dir(), "app", "src", "main", "assets", "seed.json"), encoding="utf-8") as f:
            seed = json.load(f)
        self.assertEqual([c["iso"] for c in self.manifest["currencies"]], [c["iso"] for c in seed["currencies"]])
        self.assertEqual([p["symbol"] for p in self.manifest["pairs"]], [p["symbol"] for p in seed["currency_pairs"]])
        for mine, phone in zip(self.manifest["currencies"], seed["currencies"]):
            self.assertEqual(mine["name"], phone["name"], phone["iso"])
            self.assertEqual(mine["symbol"], phone["symbol"], phone["iso"])
            self.assertEqual(mine["icon"], phone["icon"], phone["iso"])
            self.assertEqual(mine["precision"], phone.get("precision", 2), phone["iso"])


class SqlTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = cur.load_manifest()

    def test_committed_sql_is_what_the_generator_writes(self):
        with open(cur.UP_SQL, encoding="utf-8") as f:
            self.assertEqual(f.read(), cur.build_up(self.manifest), "up.sql правили руками или он устарел")
        with open(cur.DOWN_SQL, encoding="utf-8") as f:
            self.assertEqual(f.read(), cur.build_down(self.manifest), "down.sql правили руками или он устарел")

    def test_up_sql_shape(self):
        up = cur.build_up(self.manifest)
        for c in self.manifest["currencies"]:
            self.assertIn(cur.sql_text(c["iso"]), up)
        for p in self.manifest["pairs"]:
            self.assertIn(cur.sql_text(p["symbol"]), up)
        self.assertEqual(up.count("next_seq("), 2)  # одна ветка на валюты, вторая — если валют не было, а пары есть
        self.assertIn("md5('reference-currency:'", up)
        self.assertIn("md5('reference-currency-pair:'", up)
        self.assertIn("ON CONFLICT (uuid) DO NOTHING", up)
        self.assertIn("lower(c.name) = lower(d.name)", up)
        self.assertIn(cur.REFERENCE_STREAM, up)

    def test_down_sql_lists_every_code_and_symbol_and_survives_references(self):
        down = cur.build_down(self.manifest)
        for c in self.manifest["currencies"]:
            self.assertIn(cur.sql_text(c["iso"]), down)
        for p in self.manifest["pairs"]:
            self.assertIn(cur.sql_text(p["symbol"]), down)
        self.assertIn("foreign_key_violation", down)
        # Пары удаляются раньше валют, иначе внешний ключ держит валюты.
        self.assertLess(down.index("currency_pair WHERE"), down.index("currency WHERE"))

    def test_migration_number_follows_the_icon_migrations(self):
        self.assertEqual(cur.NUMBER, max(icons.MIGRATIONS) + 1)


if __name__ == "__main__":
    unittest.main()
