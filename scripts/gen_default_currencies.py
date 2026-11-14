#!/usr/bin/env python3
"""Генератор общего справочника валют wallet-api (change default-reference-currencies).

Справочник — снимок валют и валютных пар стартового набора телефона
(android-wallet/app/src/main/assets/seed.json). Два режима:

  collect --android <папка android-wallet>
      читает seed.json и пишет migrations/default_currencies/manifest.json
      (валюты: код, название, символ, имя иконки, точность; пары: символ, база, квота).

  build
      по manifest.json пишет migrations/000039_default_reference_currencies.up.sql
      и .down.sql. android-wallet для этого не нужен: набор воспроизводится из
      репозитория.

SQL руками не правится — только этим скриптом (тест
test_committed_sql_is_what_the_generator_writes падает, если файл разошёлся).
"""
import argparse
import hashlib
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIR = os.path.join(ROOT, "migrations", "default_currencies")
MANIFEST = os.path.join(DIR, "manifest.json")
NUMBER = 39
NAME = "default_reference_currencies"
UP_SQL = os.path.join(ROOT, "migrations", f"{NUMBER:06d}_{NAME}.up.sql")
DOWN_SQL = os.path.join(ROOT, "migrations", f"{NUMBER:06d}_{NAME}.down.sql")
REFERENCE_STREAM = "00000000-0000-0000-0000-000000000001"
PAIR_PRECISION = 5  # как у пар, которые телефон заводит сам (currency_pair.precision DEFAULT 5)


def sql_text(value):
    return "'" + value.replace("'", "''") + "'"


# ── collect ──────────────────────────────────────────────────────────────────

def cmd_collect(android):
    seed_path = os.path.join(android, "app", "src", "main", "assets", "seed.json")
    with open(seed_path, encoding="utf-8") as f:
        seed = json.load(f)
    currencies = [
        {"iso": c["iso"], "name": c["name"], "symbol": c["symbol"], "icon": c["icon"],
         "precision": c.get("precision", 2)}
        for c in seed["currencies"]
    ]
    pairs = [{"symbol": p["symbol"], "base": p["base"], "quote": p["quote"]} for p in seed["currency_pairs"]]
    os.makedirs(DIR, exist_ok=True)
    with open(MANIFEST, "w", encoding="utf-8", newline="\n") as f:
        json.dump({"currencies": currencies, "pairs": pairs}, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print(f"манифест: {len(currencies)} валют, {len(pairs)} пар")


# ── build ────────────────────────────────────────────────────────────────────

def load_manifest():
    with open(MANIFEST, encoding="utf-8") as f:
        manifest = json.load(f)
    isos = [c["iso"].upper() for c in manifest["currencies"]]
    if len(set(isos)) != len(isos):
        sys.exit("в манифесте коды валют повторяются")
    names = [c["name"].lower() for c in manifest["currencies"]]
    if len(set(names)) != len(names):
        sys.exit("в манифесте названия валют повторяются без учёта регистра")
    symbols = [p["symbol"].upper() for p in manifest["pairs"]]
    if len(set(symbols)) != len(symbols):
        sys.exit("в манифесте символы пар повторяются")
    known = set(isos)
    for p in manifest["pairs"]:
        if p["base"].upper() not in known or p["quote"].upper() not in known:
            sys.exit(f"пара {p['symbol']}: валюта базы или квоты не в манифесте")
        if p["symbol"].upper() != (p["base"] + p["quote"]).upper():
            sys.exit(f"пара {p['symbol']}: символ не равен базе + квоте")
    return manifest


def build_up(manifest):
    cur_rows = ",\n".join(
        f"        ({sql_text(c['iso'].upper())}, {sql_text(c['name'])}, {sql_text(c['symbol'])}, "
        f"{sql_text(c['icon'])}, {c['precision']})"
        for c in manifest["currencies"])
    pair_rows = ",\n".join(
        f"        ({sql_text(p['symbol'].upper())}, {sql_text(p['base'].upper())}, {sql_text(p['quote'].upper())})"
        for p in manifest["pairs"])
    return f"""-- default-reference-currencies (wallet-api/openspec/changes/default-reference-currencies):
-- общий справочник валют и валютных пар по умолчанию — снимок стартового набора
-- телефона (android-wallet seed.json: валюты и пары без курсов). Файл СГЕНЕРИРОВАН
-- scripts/gen_default_currencies.py из migrations/default_currencies/manifest.json —
-- руками не править (README.md, раздел «Миграции»).
--
-- Что делает:
--  * currency — общие валюты (ledger_id IS NULL) с детерминированным uuid
--    md5('reference-currency:' || iso_code); иконка — живая общая иконка с именем
--    из набора (набор иконок — миграции 000037, 000038); валюта, для которой иконки
--    нет, пропускается;
--  * currency_pair — общие пары с детерминированным uuid
--    md5('reference-currency-pair:' || symbol), точность {PAIR_PRECISION}; база и квота —
--    живые общие валюты по коду;
--  * один seq потока reference на всю вставку (как атомарный батч синка), и только
--    если есть что вставлять — повторный накат поток не двигает;
--  * валюта с кодом или названием (без учёта регистра), уже занятыми живой общей
--    валютой, и пара с занятым символом пропускаются: работу администратора
--    миграция не трогает и не ловит uq_currency_*_reference. Удалённые (deleted_at)
--    строки набору не мешают, а сами не воскресают (ON CONFLICT (uuid) DO NOTHING);
--  * курсов нет — только справочник.
DO $$
DECLARE
    v_seq bigint;
BEGIN
    CREATE TEMP TABLE _default_currency (
        iso_code text NOT NULL, name text NOT NULL, symbol text NOT NULL,
        icon_name text NOT NULL, "precision" smallint NOT NULL) ON COMMIT DROP;
    INSERT INTO _default_currency (iso_code, name, symbol, icon_name, "precision") VALUES
{cur_rows};

    CREATE TEMP TABLE _default_currency_todo ON COMMIT DROP AS
        SELECT md5('reference-currency:' || d.iso_code)::uuid AS uuid, d.iso_code, d.name,
               d.symbol, i.uuid AS icon_uuid, d."precision"
          FROM _default_currency d
          JOIN icon i ON i.ledger_id IS NULL AND i.deleted_at IS NULL
                     AND lower(i.name) = lower(d.icon_name)
         WHERE NOT EXISTS (SELECT 1 FROM currency c
                            WHERE c.ledger_id IS NULL AND c.deleted_at IS NULL
                              AND (upper(c.iso_code) = d.iso_code OR lower(c.name) = lower(d.name)));

    IF EXISTS (SELECT 1 FROM _default_currency_todo) THEN
        v_seq := next_seq('{REFERENCE_STREAM}'::uuid);
        INSERT INTO currency (uuid, ledger_id, seq, name, iso_code, icon_uuid, symbol, "precision")
        SELECT uuid, NULL, v_seq, name, iso_code, icon_uuid, symbol, "precision"
          FROM _default_currency_todo
        ON CONFLICT (uuid) DO NOTHING;
    END IF;

    CREATE TEMP TABLE _default_pair (symbol text NOT NULL, base text NOT NULL, quote text NOT NULL) ON COMMIT DROP;
    INSERT INTO _default_pair (symbol, base, quote) VALUES
{pair_rows};

    CREATE TEMP TABLE _default_pair_todo ON COMMIT DROP AS
        SELECT md5('reference-currency-pair:' || p.symbol)::uuid AS uuid, p.symbol,
               b.uuid AS base_uuid, q.uuid AS quote_uuid
          FROM _default_pair p
          JOIN currency b ON b.ledger_id IS NULL AND b.deleted_at IS NULL AND upper(b.iso_code) = p.base
          JOIN currency q ON q.ledger_id IS NULL AND q.deleted_at IS NULL AND upper(q.iso_code) = p.quote
         WHERE NOT EXISTS (SELECT 1 FROM currency_pair x
                            WHERE x.ledger_id IS NULL AND x.deleted_at IS NULL
                              AND upper(x.symbol) = p.symbol);

    IF EXISTS (SELECT 1 FROM _default_pair_todo) THEN
        IF v_seq IS NULL THEN
            v_seq := next_seq('{REFERENCE_STREAM}'::uuid);
        END IF;
        INSERT INTO currency_pair (uuid, ledger_id, seq, symbol, base_currency_uuid, quote_currency_uuid, "precision")
        SELECT uuid, NULL, v_seq, symbol, base_uuid, quote_uuid, {PAIR_PRECISION} FROM _default_pair_todo
        ON CONFLICT (uuid) DO NOTHING;
    END IF;
END
$$;
"""


def build_down(manifest):
    cur_isos = ",\n".join(f"        ({sql_text(c['iso'].upper())})" for c in manifest["currencies"])
    pair_symbols = ",\n".join(f"        ({sql_text(p['symbol'].upper())})" for p in manifest["pairs"])
    return f"""-- Откат {NUMBER:06d} {NAME}: удаляет только пары и валюты этого набора (по
-- детерминированным uuid md5('reference-currency-pair:' || symbol) и
-- md5('reference-currency:' || iso_code)). Пары и валюты администратора (другие uuid)
-- не трогаются. Строка, на которую уже кто-то ссылается (кошелёк с этой валютой,
-- курс пары), остаётся: внешний ключ не даёт её удалить, и откат её пропускает.
-- seq потока reference назад не возвращается; после того как клиенты забрали набор,
-- схему назад не откатываем (как 000036).
-- Файл СГЕНЕРИРОВАН scripts/gen_default_currencies.py.
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT md5('reference-currency-pair:' || n.symbol)::uuid AS uuid
               FROM (VALUES
{pair_symbols}
               ) n(symbol)
    LOOP
        BEGIN
            DELETE FROM currency_pair WHERE uuid = r.uuid;
        EXCEPTION WHEN foreign_key_violation THEN
            NULL;
        END;
    END LOOP;

    FOR r IN SELECT md5('reference-currency:' || n.iso_code)::uuid AS uuid
               FROM (VALUES
{cur_isos}
               ) n(iso_code)
    LOOP
        BEGIN
            DELETE FROM currency WHERE uuid = r.uuid;
        EXCEPTION WHEN foreign_key_violation THEN
            NULL;
        END;
    END LOOP;
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
    print(f"{os.path.basename(UP_SQL)}: {os.path.getsize(UP_SQL)} байт (sha256 {digest}), "
          f"валют {len(manifest['currencies'])}, пар {len(manifest['pairs'])}")


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
