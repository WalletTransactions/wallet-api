"""Тесты генератора набора иконок (change default-reference-icons).

Запуск: python3 -m unittest discover -s scripts/tests -v   (из wallet-api/)
Сверка с seed.json телефона идёт, если рядом лежит android-wallet (или задана
переменная ANDROID_WALLET); без него этот тест пропускается.
"""
import importlib.util
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(os.path.dirname(HERE), "gen_default_icons.py")

spec = importlib.util.spec_from_file_location("gen_default_icons", SCRIPT)
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def android_dir():
    path = os.environ.get("ANDROID_WALLET") or os.path.join(gen.ROOT, "..", "android-wallet")
    seed = os.path.join(path, "app", "src", "main", "assets", "seed.json")
    return path if os.path.exists(seed) else None


class ManifestTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = gen.load_manifest()

    def test_names_unique_ignoring_case_and_unknown_present(self):
        names = [m["name"].lower() for m in self.manifest]
        self.assertEqual(len(names), len(set(names)))
        self.assertIn("unknown", names)

    def test_types_are_flag_or_category(self):
        types = {m["icon_type"] for m in self.manifest}
        self.assertEqual(types, {gen.ICON_TYPE_FLAG, gen.ICON_TYPE_CATEGORY})
        flags = [m for m in self.manifest if m["icon_type"] == gen.ICON_TYPE_FLAG]
        self.assertTrue(all(m["name"].lower().startswith("flag") or m["name"].endswith("flag") for m in flags),
                        "флагом помечено не только имя флага")

    def test_every_file_is_png_within_blob_limit(self):
        for m in self.manifest:
            path = os.path.join(gen.ICON_DIR, m["file"])
            self.assertTrue(os.path.exists(path), m["file"])
            size = os.path.getsize(path)
            self.assertLessEqual(size, gen.MAX_BLOB_BYTES, m["file"])
            with open(path, "rb") as f:
                self.assertEqual(f.read(8), PNG_SIGNATURE, m["file"])

    def test_vector_flags_are_rasterized_to_64px(self):
        from PIL import Image
        vectors = [m for m in self.manifest if m["source"] in ("vector", "override")]
        self.assertEqual(len(vectors), 11)
        self.assertEqual([m["file"] for m in vectors if m["source"] == "override"], ["flag_albania.png"])
        for m in vectors:
            with Image.open(os.path.join(gen.ICON_DIR, m["file"])) as im:
                self.assertEqual(im.size, (gen.FLAG_SIZE, gen.FLAG_SIZE), m["file"])
                self.assertEqual(im.mode, "RGBA", m["file"])
                # Углы прозрачны (круглый флаг), центр — нет.
                self.assertEqual(im.getpixel((0, 0))[3], 0, m["file"])
                self.assertGreater(im.getpixel((32, 32))[3], 0, m["file"])

    @unittest.skipIf(android_dir() is None, "рядом нет android-wallet")
    def test_names_match_phone_seed(self):
        path = os.path.join(android_dir(), "app", "src", "main", "assets", "seed.json")
        with open(path, encoding="utf-8") as f:
            expected = gen.collect_entries(json.load(f))
        self.assertEqual({n.lower() for n in expected}, {m["name"].lower() for m in self.manifest})
        types = {m["name"]: m["icon_type"] for m in self.manifest}
        for name, (_, icon_type) in expected.items():
            self.assertEqual(types[name], icon_type, name)


class SqlTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = gen.load_manifest()

    def test_committed_sql_is_what_the_generator_writes(self):
        with open(gen.UP_SQL, encoding="utf-8") as f:
            self.assertEqual(f.read(), gen.build_up(self.manifest), "up.sql правили руками или он устарел")
        with open(gen.DOWN_SQL, encoding="utf-8") as f:
            self.assertEqual(f.read(), gen.build_down(self.manifest), "down.sql правили руками или он устарел")

    def test_up_sql_shape(self):
        up = gen.build_up(self.manifest)
        self.assertEqual(up.count("decode('"), len(self.manifest))
        self.assertEqual(up.count("next_seq("), 1)
        self.assertIn("sha256(d.bytes)", up)
        self.assertIn("ON CONFLICT (sha256) DO NOTHING", up)
        self.assertIn("ON CONFLICT (uuid) DO NOTHING", up)
        self.assertIn("lower(i.name) = lower(d.name)", up)
        self.assertIn(gen.REFERENCE_STREAM, up)

    def test_down_sql_lists_every_name_and_drops_only_orphan_blobs(self):
        down = gen.build_down(self.manifest)
        for m in self.manifest:
            self.assertIn(gen.sql_text(m["name"]), down)
        self.assertIn("NOT EXISTS (SELECT 1 FROM icon i WHERE i.content_sha256 = b.sha256)", down)


class VectorConversionTest(unittest.TestCase):
    def test_argb_color_becomes_rgb_and_alpha(self):
        self.assertEqual(gen.android_color("#80FF0000"), ("#FF0000", 128 / 255.0))
        self.assertEqual(gen.android_color("#FF0000"), ("#FF0000", None))

    def test_clip_group_and_paths_become_svg(self):
        xml = """<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="64dp" android:height="64dp" android:viewportWidth="64" android:viewportHeight="64">
  <group>
    <clip-path android:pathData="M2,32 A30,30 0 1 0 62,32 A30,30 0 1 0 2,32Z"/>
    <path android:fillColor="#0057B7" android:pathData="M0,0 H64 V32 H0Z"/>
    <path android:strokeColor="#FFFFFF" android:strokeWidth="4" android:pathData="M0,0 L64,64"/>
  </group>
  <path android:fillColor="#CCCCCC" android:fillAlpha="0.4" android:pathData="M2,32 A30,30 0 1 0 62,32Z"/>
</vector>"""
        with tempfile.NamedTemporaryFile("w", suffix=".xml", delete=False, encoding="utf-8") as f:
            f.write(xml)
            path = f.name
        try:
            svg = gen.vector_to_svg(path)
        finally:
            os.unlink(path)
        self.assertIn('viewBox="0 0 64 64"', svg)
        self.assertIn('<clipPath id="c1">', svg)
        self.assertIn('<g clip-path="url(#c1)">', svg)
        self.assertIn('fill="#0057B7"', svg)
        self.assertIn('stroke="#FFFFFF"', svg)
        self.assertIn('fill-opacity="0.4"', svg)


if __name__ == "__main__":
    unittest.main()
