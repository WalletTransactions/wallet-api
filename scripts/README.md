# scripts

## `gen_default_icons.py` — набор иконок по умолчанию

Генератор миграций набора `000037_default_reference_icons` и
`000038_default_reference_icons_btc_ltc` (changes `default-reference-icons`,
`default-icons-btc-ltc`, см. `../README.md`, «Набор иконок по умолчанию»).
Набор — снимок стартового набора телефона (`android-wallet` `seed.json`);
новые иконки телефона едут новой миграцией (строка в `MIGRATIONS`).

```bash
# 1. Добавить новые иконки в манифест и PNG из android-wallet (нужен cairosvg
#    для векторных флагов). --since — номер миграции, которая их добавит:
python3 -m venv /tmp/icons-venv && /tmp/icons-venv/bin/pip install cairosvg
/tmp/icons-venv/bin/python scripts/gen_default_icons.py collect --android ../android-wallet --since 38

# 2. Написать SQL миграций по манифесту и PNG (android-wallet больше не нужен):
python3 scripts/gen_default_icons.py build
```

`collect` только добавляет имена, которых ещё нет в манифесте: картинки
собранных иконок вшиты в накатанные миграции и не пересоздаются.

Готовые PNG из `scripts/icon_overrides/<resource>.png` заменяют растеризацию
вектора телефона (сейчас `flag_albania.png`: векторный орёл на телефоне
получился неразборчивым, взят круглый кроп флага Noto Color Emoji).

Результат: `migrations/default_icons/*.png` и `manifest.json`,
`migrations/0000NN_*.up.sql` и `.down.sql` на каждую миграцию набора. SQL руками не
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

## `gen_default_currencies.py` — справочник валют по умолчанию

Генератор миграции `000039_default_reference_currencies` (change
`default-reference-currencies`, см. `../README.md`, «Справочник валют по
умолчанию»): общие валюты и валютные пары стартового набора телефона.

```bash
# 1. Собрать манифест (валюты и пары) из seed.json телефона:
python3 scripts/gen_default_currencies.py collect --android ../android-wallet

# 2. Написать SQL миграции по манифесту (android-wallet больше не нужен):
python3 scripts/gen_default_currencies.py build
```

Результат: `migrations/default_currencies/manifest.json`,
`migrations/000039_default_reference_currencies.up.sql` и `.down.sql`. SQL
руками не правится — тест `test_committed_sql_is_what_the_generator_writes`
падает, если файл разошёлся с генератором. Иконки валют берутся по имени из
набора иконок (`gen_default_icons.py`): тест проверяет, что каждое имя там есть.
Изменение набора телефона закрывается НОВОЙ миграцией, `000039` не переписывается.

## `linux/`, `windows/`

Установка wallet-api как системной службы.
