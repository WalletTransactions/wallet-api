## 1. Генератор и миграция

- [x] 1.1 `scripts/gen_default_icons.py`: таблица `MIGRATIONS`, поле `since` в манифесте, `build` пишет пару файлов на каждый `since`, `collect --since N` только добавляет новые имена. Проверка: `000037_*.sql` после `build` без diff в git
- [x] 1.2 Собрать `Flag BTC` / `Flag LTC` из `seed.json` телефона (`collect --since 38`), получить `migrations/000038_default_reference_icons_btc_ltc.{up,down}.sql` и PNG. Проверка: manifest растёт на две записи с `since: 38`, PNG 64×64 RGBA
- [x] 1.3 Тесты генератора: SQL совпадает с генератором для каждой миграции, имя добавлено одной миграцией, у `000037` по-прежнему 87 иконок, `000038` — ровно BTC и LTC. Проверка: `python3 -m unittest discover -s scripts/tests` зелёный

## 2. Интеграционные тесты

- [x] 2.1 `tests_integration/test_default_icons.cpp`: манифест фильтруется по `since`, сценарии `000038` — иконки на месте после всех миграций, down/up трогает только две иконки и даёт один `seq`, повторный up без изменений, иконка администратора `flag btc` не затёрта. Проверка: прогон на одноразовом Postgres, все `default_icons_*` зелёные — выполнено 2026-11-14: одноразовый `postgres:16-alpine`, миграции до 38 накатились, 12 `default_icons_*` (8 прежних + 4 новых) зелёные, весь интеграционный набор — код 0

## 3. Документация и выкатка

- [x] 3.1 `README.md` («Набор иконок по умолчанию»: 89 иконок, две миграции) и `scripts/README.md`; спека `default-reference-icons` обновляется при архивации change
- [x] 3.2 Выкатить на test: накат `000038`, проверка в базе и `GET /sync/pull` потока `reference` — выполнено 2026-11-14: `000038` выкачена вместе с `v0.4.3-rc.1` (wallet-api#32, история контура 09:44 UTC), `schema_migrations` = 39 (после `000039`), `Flag BTC` и `Flag LTC` в `icon` с `icon_type` = 1 без `deleted_at`; `GET /sync/pull?reference_seq=0` отдаёт обе иконки в `reference.changes.icon` (`ledger_id` = null, один `seq` = 2)
