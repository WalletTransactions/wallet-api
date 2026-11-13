#!/usr/bin/env python3
"""Генератор общего набора иконок wallet-api (change default-reference-icons).

Набор — снимок стартового набора телефона (android-wallet/app/src/main/assets/seed.json):
категории Fluent 3D, флаги, запасная иконка `unknown`. Два режима:

  collect --android <папка android-wallet>
      читает seed.json и res/drawable, кладёт PNG в migrations/default_icons/
      (готовые PNG копирует, векторные флаги Android XML растеризует в PNG 64x64)
      и пишет migrations/default_icons/manifest.json. Растеризации нужен cairosvg
      (`pip install cairosvg` в виртуальном окружении), больше ничего.

  build
      по manifest.json и PNG пишет migrations/000037_default_reference_icons.up.sql
      и .down.sql. android-wallet для этого не нужен: набор воспроизводится из репозитория.

SQL руками не правится — только этим скриптом (README.md, раздел «Миграции»).
"""
import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import sys
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON_DIR = os.path.join(ROOT, "migrations", "default_icons")
MANIFEST = os.path.join(ICON_DIR, "manifest.json")
# Готовые PNG, которые заменяют растеризацию вектора с телефона (имя файла = resource).
OVERRIDE_DIR = os.path.join(ROOT, "scripts", "icon_overrides")
UP_SQL = os.path.join(ROOT, "migrations", "000037_default_reference_icons.up.sql")
DOWN_SQL = os.path.join(ROOT, "migrations", "000037_default_reference_icons.down.sql")

ICON_TYPE_CATEGORY = 2  # как у телефона: «1 — флаг, остальное — категория» (openapi, createReferenceIcon)
ICON_TYPE_FLAG = 1
MAX_BLOB_BYTES = 1048576  # blob_bytes_check
FLAG_SIZE = 64
ANDROID_NS = "{http://schemas.android.com/apk/res/android}"
REFERENCE_STREAM = "00000000-0000-0000-0000-000000000001"


# ── collect ──────────────────────────────────────────────────────────────────

def collect_entries(seed):
    """Имя -> (ресурс телефона, icon_type), в порядке seed.json; первое объявление побеждает."""
    entries = {}
    for item in seed["category_icons"]:
        entries.setdefault(item["name"], (item["resource"], ICON_TYPE_CATEGORY))
    for item in seed["flag_icons"]:
        entries.setdefault(item["name"], (item["resource"], ICON_TYPE_FLAG))
    for cur in seed["currencies"]:
        if cur.get("icon") and cur.get("icon_resource"):
            entries.setdefault(cur["icon"], (cur["icon_resource"], ICON_TYPE_FLAG))
    return entries


def android_color(value):
    """Android: #RRGGBB или #AARRGGBB → (css-цвет, альфа или None)."""
    value = value.strip()
    if value.startswith("#") and len(value) == 9:
        a = int(value[1:3], 16) / 255.0
        return "#" + value[3:], a
    return value, None


def vector_to_svg(xml_path):
    """Простые Android vector (группы с clip-path, path с заливкой/обводкой) → SVG-строка."""
    root = ET.parse(xml_path).getroot()
    width = float(root.get(ANDROID_NS + "viewportWidth"))
    height = float(root.get(ANDROID_NS + "viewportHeight"))
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width:g} {height:g}" '
             f'width="{FLAG_SIZE}" height="{FLAG_SIZE}">']
    clip_id = [0]

    def path_el(el):
        attrs = ['d="%s"' % el.get(ANDROID_NS + "pathData")]
        fill = el.get(ANDROID_NS + "fillColor")
        if fill:
            color, alpha = android_color(fill)
            attrs.append(f'fill="{color}"')
            if alpha is not None:
                attrs.append(f'fill-opacity="{alpha:g}"')
        else:
            attrs.append('fill="none"')
        if el.get(ANDROID_NS + "fillAlpha"):
            attrs.append(f'fill-opacity="{el.get(ANDROID_NS + "fillAlpha")}"')
        if el.get(ANDROID_NS + "fillType") == "evenOdd":
            attrs.append('fill-rule="evenodd"')
        stroke = el.get(ANDROID_NS + "strokeColor")
        if stroke:
            color, alpha = android_color(stroke)
            attrs.append(f'stroke="{color}"')
            if alpha is not None:
                attrs.append(f'stroke-opacity="{alpha:g}"')
            attrs.append(f'stroke-width="{el.get(ANDROID_NS + "strokeWidth", "1")}"')
            for src, dst in (("strokeLineCap", "stroke-linecap"), ("strokeLineJoin", "stroke-linejoin"),
                             ("strokeMiterLimit", "stroke-miterlimit"), ("strokeAlpha", "stroke-opacity")):
                if el.get(ANDROID_NS + src):
                    attrs.append(f'{dst}="{el.get(ANDROID_NS + src)}"')
        return "<path " + " ".join(attrs) + "/>"

    def walk(node, out):
        clip = None
        for child in node:
            tag = child.tag.split("}")[-1]
            if tag == "clip-path":
                clip_id[0] += 1
                clip = f"c{clip_id[0]}"
                out.append(f'<clipPath id="{clip}"><path d="{child.get(ANDROID_NS + "pathData")}"/></clipPath>')
                out.append(f'<g clip-path="url(#{clip})">')
            elif tag == "path":
                out.append(path_el(child))
            elif tag == "group":
                walk(child, out)
            else:
                raise ValueError(f"{os.path.basename(xml_path)}: неподдерживаемый элемент <{tag}>")
        if clip:
            out.append("</g>")

    walk(root, parts)
    parts.append("</svg>")
    return "".join(parts)


def rasterize(xml_path, png_path):
    try:
        import cairosvg
    except ImportError:
        sys.exit("для растеризации векторных флагов нужен cairosvg: python3 -m venv v && v/bin/pip install cairosvg")
    cairosvg.svg2png(bytestring=vector_to_svg(xml_path).encode("utf-8"), write_to=png_path,
                     output_width=FLAG_SIZE, output_height=FLAG_SIZE)


def cmd_collect(android):
    seed_path = os.path.join(android, "app", "src", "main", "assets", "seed.json")
    drawable = os.path.join(android, "app", "src", "main", "res", "drawable")
    with open(seed_path, encoding="utf-8") as f:
        entries = collect_entries(json.load(f))

    os.makedirs(ICON_DIR, exist_ok=True)
    for old in os.listdir(ICON_DIR):
        if old.endswith(".png"):
            os.remove(os.path.join(ICON_DIR, old))

    manifest = []
    for name, (resource, icon_type) in entries.items():
        png_src = os.path.join(drawable, resource + ".png")
        xml_src = os.path.join(drawable, resource + ".xml")
        target = os.path.join(ICON_DIR, resource + ".png")
        override = os.path.join(OVERRIDE_DIR, resource + ".png")
        if os.path.exists(override):
            shutil.copyfile(override, target)
            source = "override"
        elif os.path.exists(png_src):
            shutil.copyfile(png_src, target)
            source = "png"
        elif os.path.exists(xml_src):
            rasterize(xml_src, target)
            source = "vector"
        else:
            sys.exit(f"нет файла для «{name}» ({resource}) в {drawable}")
        size = os.path.getsize(target)
        if size > MAX_BLOB_BYTES:
            sys.exit(f"{resource}.png — {size} байт, больше лимита blob {MAX_BLOB_BYTES}")
        manifest.append({"name": name, "icon_type": icon_type, "file": resource + ".png", "source": source})

    with open(MANIFEST, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
        f.write("\n")
    flags = sum(1 for m in manifest if m["icon_type"] == ICON_TYPE_FLAG)
    vectors = sum(1 for m in manifest if m["source"] == "vector")
    print(f"манифест: {len(manifest)} иконок ({len(manifest) - flags} категорий, {flags} флагов, "
          f"из них растеризовано векторов: {vectors})")


# ── build ────────────────────────────────────────────────────────────────────

def sql_text(value):
    return "'" + value.replace("'", "''") + "'"


def load_manifest():
    with open(MANIFEST, encoding="utf-8") as f:
        manifest = json.load(f)
    names = [m["name"].lower() for m in manifest]
    if len(set(names)) != len(names):
        sys.exit("в манифесте имена повторяются без учёта регистра")
    return manifest


def build_up(manifest):
    rows = []
    for m in manifest:
        with open(os.path.join(ICON_DIR, m["file"]), "rb") as f:
            data = f.read()
        if len(data) > MAX_BLOB_BYTES:
            sys.exit(f"{m['file']} больше лимита blob")
        rows.append(f"        ({sql_text(m['name'])}, {m['icon_type']}, "
                    f"decode('{base64.b64encode(data).decode('ascii')}', 'base64'))")
    return f"""-- default-reference-icons (wallet-api/openspec/changes/default-reference-icons):
-- общий набор иконок по умолчанию — снимок стартового набора телефона
-- (android-wallet seed.json: категории Fluent 3D, флаги, запасная `unknown`).
-- Файл СГЕНЕРИРОВАН scripts/gen_default_icons.py из migrations/default_icons/ —
-- руками не править (README.md, раздел «Миграции»).
--
-- Что делает:
--  * blob — байты картинок, sha256 считает база (sha256(bytes)), повтор — ON CONFLICT DO NOTHING;
--  * icon — общие иконки (ledger_id IS NULL) с детерминированным uuid
--    md5('reference-icon:' || lower(name)), icon_type: 2 — категория, 1 — флаг;
--  * один seq потока reference на всю вставку (как атомарный батч синка), и только
--    если есть что вставлять — повторный накат поток не двигает;
--  * иконка, чьё имя уже занято живой общей иконкой (без учёта регистра), пропускается:
--    работу администратора с экрана «Иконки» миграция не трогает и не ловит
--    uq_icon_name_reference. Удалённые (deleted_at) не мешают.
DO $$
DECLARE
    v_seq bigint;
BEGIN
    CREATE TEMP TABLE _default_icon (name text NOT NULL, icon_type smallint NOT NULL, bytes bytea NOT NULL) ON COMMIT DROP;
    INSERT INTO _default_icon (name, icon_type, bytes) VALUES
{(","+chr(10)).join(rows)};

    CREATE TEMP TABLE _default_icon_todo ON COMMIT DROP AS
        SELECT md5('reference-icon:' || lower(d.name))::uuid AS uuid, d.name, d.icon_type,
               d.bytes, sha256(d.bytes) AS sha
          FROM _default_icon d
         WHERE NOT EXISTS (SELECT 1 FROM icon i
                            WHERE i.ledger_id IS NULL AND i.deleted_at IS NULL
                              AND lower(i.name) = lower(d.name));

    IF EXISTS (SELECT 1 FROM _default_icon_todo) THEN
        INSERT INTO blob (sha256, bytes)
        SELECT sha, bytes FROM _default_icon_todo
        ON CONFLICT (sha256) DO NOTHING;

        v_seq := next_seq('{REFERENCE_STREAM}'::uuid);

        INSERT INTO icon (uuid, ledger_id, seq, name, content_sha256, icon_type)
        SELECT uuid, NULL, v_seq, name, sha, icon_type FROM _default_icon_todo
        ON CONFLICT (uuid) DO NOTHING;
    END IF;
END
$$;
"""


def build_down(manifest):
    names = ",\n".join(f"        ({sql_text(m['name'])})" for m in manifest)
    return f"""-- Откат 000037 default_reference_icons: удаляет только иконки этого набора (по
-- детерминированным uuid md5('reference-icon:' || lower(name))) и blob, на которые
-- после этого никто не ссылается. Иконки администратора (другие uuid) и blob,
-- общий с чужой иконкой, не трогаются. seq потока reference назад не возвращается;
-- после того как клиенты забрали набор, схему назад не откатываем (как 000036).
-- Файл СГЕНЕРИРОВАН scripts/gen_default_icons.py.
DO $$
BEGIN
    CREATE TEMP TABLE _default_icon_gone (sha bytea NOT NULL) ON COMMIT DROP;

    WITH names (name) AS (VALUES
{names}
    ), gone AS (
        DELETE FROM icon i
         USING names n
         WHERE i.uuid = md5('reference-icon:' || lower(n.name))::uuid
        RETURNING i.content_sha256
    )
    INSERT INTO _default_icon_gone (sha) SELECT content_sha256 FROM gone;

    DELETE FROM blob b
     WHERE b.sha256 IN (SELECT sha FROM _default_icon_gone)
       AND NOT EXISTS (SELECT 1 FROM icon i WHERE i.content_sha256 = b.sha256);
END
$$;
"""


def cmd_build():
    manifest = load_manifest()
    with open(UP_SQL, "w", encoding="utf-8", newline="\n") as f:
        f.write(build_up(manifest))
    with open(DOWN_SQL, "w", encoding="utf-8", newline="\n") as f:
        f.write(build_down(manifest))
    digest = hashlib.sha256(open(UP_SQL, "rb").read()).hexdigest()[:12]
    print(f"{os.path.basename(UP_SQL)}: {os.path.getsize(UP_SQL)} байт (sha256 {digest}), иконок {len(manifest)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("collect")
    c.add_argument("--android", required=True, help="папка репозитория android-wallet")
    sub.add_parser("build")
    args = parser.parse_args()
    if args.cmd == "collect":
        cmd_collect(args.android)
    else:
        cmd_build()


if __name__ == "__main__":
    main()
