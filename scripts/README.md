# scripts

## `gen_default_icons.py` — набор иконок по умолчанию

Генератор миграции `000037_default_reference_icons` (change
`default-reference-icons`, см. `../README.md`, «Набор иконок по умолчанию»).
Набор — снимок стартового набора телефона (`android-wallet` `seed.json`).

```bash
# 1. Собрать PNG и манифест из android-wallet (нужен cairosvg для 11 векторных флагов):
python3 -m venv /tmp/icons-venv && /tmp/icons-venv/bin/pip install cairosvg
/tmp/icons-venv/bin/python scripts/gen_default_icons.py collect --android ../android-wallet

# 2. Написать SQL миграции по манифесту и PNG (android-wallet больше не нужен):
python3 scripts/gen_default_icons.py build
```

Готовые PNG из `scripts/icon_overrides/<resource>.png` заменяют растеризацию
вектора телефона (сейчас `flag_albania.png`: векторный орёл на телефоне
получился неразборчивым, взят круглый кроп флага Noto Color Emoji).

Результат: `migrations/default_icons/*.png` и `manifest.json`,
`migrations/000037_default_reference_icons.up.sql` и `.down.sql`. SQL руками не
правится — тест `test_committed_sql_is_what_the_generator_writes` падает, если
файл разошёлся с генератором. Набор — снимок: изменение набора телефона
закрывается НОВОЙ миграцией (новый номер, этот же генератор с другим
манифестом), `000037` не переписывается.

Тесты генератора (из `wallet-api/`):

```bash
python3 -m unittest discover -s scripts/tests -v
```

Сверка имён с `seed.json` телефона идёт, если рядом лежит `android-wallet` (или
задан `ANDROID_WALLET`), иначе этот один тест пропускается.

## `linux/`, `windows/`

Установка wallet-api как системной службы.
