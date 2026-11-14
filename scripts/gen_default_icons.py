#!/usr/bin/env python3
"""Генератор общего набора иконок wallet-api (change default-reference-icons).

Набор — снимок стартового набора телефона (android-wallet/app/src/main/assets/seed.json):
категории Fluent 3D, флаги, запасная иконка `unknown`. Два режима:

  collect --android <папка android-wallet> [--since N]
      читает seed.json и res/drawable и ДОБАВЛЯЕТ в migrations/default_icons/ PNG и
      записи манифеста для имён, которых там ещё нет (готовые PNG копирует, векторные
      флаги Android XML растеризует в PNG 64x64); новые записи получают since = N
      (по умолчанию — последняя миграция из MIGRATIONS). Уже собранные иконки не
      пересоздаются: их байты вшиты в накатанные миграции. Растеризации нужен cairosvg
      (`pip install cairosvg` в виртуальном окружении), больше ничего.

  build
      по manifest.json и PNG пишет migrations/0000NN_*.up.sql и .down.sql — по одной
      паре на каждый `since` манифеста (37, 38, …). android-wallet для этого не нужен:
      набор воспроизводится из репозитория.

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
# Миграции набора: номер -> суффикс имени файла. Запись манифеста несёт `since` — номер
# миграции, которая её добавила (нет поля — 37). Набор — снимок: новые иконки телефона
# идут в НОВУЮ миграцию, уже накатанные файлы не переписываются.
MIGRATIONS = {
    37: "default_reference_icons",
    38: "default_reference_icons_btc_ltc",
}
FIRST_MIGRATION = 37


def migration_path(number, direction):
    return os.path.join(ROOT, "migrations", f"{number:06d}_{MIGRATIONS[number]}.{direction}.sql")

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


def cmd_collect(android, since):
    if since not in MIGRATIONS:
        sys.exit(f"--since {since}: нет такой миграции в MIGRATIONS ({sorted(MIGRATIONS)})")
    seed_path = os.path.join(android, "app", "src", "main", "assets", "seed.json")
    drawable = os.path.join(android, "app", "src", "main", "res", "drawable")
    with open(seed_path, encoding="utf-8") as f:
        entries = collect_entries(json.load(f))

    os.makedirs(ICON_DIR, exist_ok=True)
    # Добавляющий режим: имена, что уже в манифесте, не трогаем — их PNG вшиты в накатанную
    # миграцию, и пересоздание (другая версия cairosvg, другой флаг) поменяло бы её содержимое.
    manifest = load_manifest() if os.path.exists(MANIFEST) else []
    known = {m["name"].lower() for m in manifest}
    added = []
    for name, (resource, icon_type) in entries.items():
        if name.lower() in known:
            continue
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
        entry = {"name": name, "icon_type": icon_type, "file": resource + ".png", "source": source}
        if since != FIRST_MIGRATION:
            entry["since"] = since
        manifest.append(entry)
        added.append(name)

    with open(MANIFEST, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
        f.write("\n")
    flags = sum(1 for m in manifest if m["icon_type"] == ICON_TYPE_FLAG)
    vectors = sum(1 for m in manifest if m["source"] == "vector")
    print(f"манифест: {len(manifest)} иконок ({len(manifest) - flags} категорий, {flags} флагов, "
          f"из них растеризовано векторов: {vectors}); добавлено в миграцию {since}: {len(added)} {added}")


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


def migration_sets(manifest):
    """Номер миграции -> записи манифеста, которые она добавляет (порядок манифеста)."""
    sets = {}
    for m in manifest:
        number = m.get("since", FIRST_MIGRATION)
        if number not in MIGRATIONS:
            sys.exit(f"{m['name']}: since {number} нет в MIGRATIONS ({sorted(MIGRATIONS)})")
        sets.setdefault(number, []).append(m)
    return dict(sorted(sets.items()))


def up_header(number):
    if number == FIRST_MIGRATION:
        return """-- default-reference-icons (wallet-api/openspec/changes/default-reference-icons):
-- общий набор иконок по умолчанию — снимок стартового набора телефона
-- (android-wallet seed.json: категории Fluent 3D, флаги, запасная `unknown`).
-- Файл СГЕНЕРИРОВАН scripts/gen_default_icons.py из migrations/default_icons/ —
-- руками не править (README.md, раздел «Миграции»).
--"""
    return f"""-- {number:06d}_{MIGRATIONS[number]}: иконки, которые появились в стартовом наборе
-- телефона (android-wallet seed.json) после {FIRST_MIGRATION:06d}_{MIGRATIONS[FIRST_MIGRATION]} и тем самым после его снимка.
-- Набор — снимок: прежние миграции не переписываются, новое едет новой миграцией.
-- Файл СГЕНЕРИРОВАН scripts/gen_default_icons.py из migrations/default_icons/ —
-- руками не править (README.md, раздел «Миграции»).
--"""


def build_up(manifest, number=FIRST_MIGRATION):
    rows = []
    for m in manifest:
        with open(os.path.join(ICON_DIR, m["file"]), "rb") as f:
            data = f.read()
        if len(data) > MAX_BLOB_BYTES:
            sys.exit(f"{m['file']} больше лимита blob")
        rows.append(f"        ({sql_text(m['name'])}, {m['icon_type']}, "
                    f"decode('{base64.b64encode(data).decode('ascii')}', 'base64'))")
    return f"""{up_header(number)}
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


def build_down(manifest, number=FIRST_MIGRATION):
    names = ",\n".join(f"        ({sql_text(m['name'])})" for m in manifest)
    return f"""-- Откат {number:06d} {MIGRATIONS[number]}: удаляет только иконки этого набора (по
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
    for number, subset in migration_sets(manifest).items():
        up, down = migration_path(number, "up"), migration_path(number, "down")
        with open(up, "w", encoding="utf-8", newline="\n") as f:
            f.write(build_up(subset, number))
        with open(down, "w", encoding="utf-8", newline="\n") as f:
            f.write(build_down(subset, number))
        digest = hashlib.sha256(open(up, "rb").read()).hexdigest()[:12]
        print(f"{os.path.basename(up)}: {os.path.getsize(up)} байт (sha256 {digest}), иконок {len(subset)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("collect")
    c.add_argument("--android", required=True, help="папка репозитория android-wallet")
    c.add_argument("--since", type=int, default=max(MIGRATIONS),
                   help="номер миграции для новых иконок (по умолчанию последняя из MIGRATIONS)")
    sub.add_parser("build")
    args = parser.parse_args()
    if args.cmd == "collect":
        cmd_collect(args.android, args.since)
    else:
        cmd_build()


if __name__ == "__main__":
    main()
