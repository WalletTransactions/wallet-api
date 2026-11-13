# Tasks

## 1. Генератор и PNG набора

- [x] 1.1 `scripts/gen_default_icons.py collect --android <путь к android-wallet>`: читает `seed.json` (`category_icons`, `flag_icons`, флаги `currencies`), копирует `fl_*.png` и PNG-флаги в `migrations/default_icons/<имя>.png`, пишет `migrations/default_icons/manifest.json` (имя, `icon_type` 2 для категорий и 1 для флагов, файл). Проверка: манифест содержит 87 уникальных имён, среди них `unknown`; каждый файл ≤ 1 МиБ; повторный запуск даёт тот же манифест
- [ ] 1.2 Растеризация 11 векторных флагов (`flag_albania`, `flag_gbp`, `flag_byn`, `flag_uah`, `flag_kazakhstan`, `flag_georgia`, `flag_amd`, `flag_aed`, `flag_cny`, `flag_thb`, `flag_try`) в PNG 64×64 с прозрачным фоном: `pathData` → SVG → PNG (`cairosvg` в виртуальном окружении, запасной путь `rsvg-convert`). Проверка: 11 PNG на месте, размер и режим RGBA; контакт-лист всех 22 флагов показан владельцу на ревью
- [x] 1.3 Тест генератора `scripts/tests/test_gen_default_icons.py` (`python3 -m unittest`): имена манифеста совпадают с `seed.json` с точностью до регистра, `unknown` есть, типы 1 и 2 как ожидается, все файлы PNG ≤ 1 МиБ. Проверка: тест зелёный; в `scripts/README.md` описан запуск

## 2. Миграция 000037

- [x] 2.1 `gen_default_icons.py build` пишет `migrations/000037_default_reference_icons.up.sql` (`DO`-блок: временная таблица имён и байт, `blob` по `sha256(bytes)` с `ON CONFLICT DO NOTHING`, `icon` с детерминированным `uuid` и общим `seq` от `next_seq` только при непустой вставке, пропуск имён, занятых живой общей иконкой без учёта регистра) и `.down.sql` (удаление по `uuid` набора и осиротевших `blob`). Проверка: `infra/db/migrate.sh wallet up` на пустой базе проходит, `SELECT count(*) FROM icon WHERE ledger_id IS NULL` = 87, `icon_type` 1 у 22 флагов и 2 у 65 категорий
- [x] 2.2 Интеграционный тест `tests_integration/test_default_icons.cpp` (в `CMakeLists.txt`): состав набора и совпадение `sha256(blob.bytes)` с `content_sha256`; выдача набора `pull_reference_stream` с курсором 0 и отсутствие повторной выдачи за курсором; повтор `up.sql` в транзакции с откатом не меняет число иконок, `uuid` и `seq`; иконка администратора с тем же именем (другая картинка) сохраняется, а удалённая иконка тёзка не мешает; `down.sql` в транзакции с откатом убирает набор, не трогает иконку администратора `Cinema` и общий с чужой иконкой `blob`. Проверка: `tests_integration/run_local.sh` зелёный, в `tests_integration/README.md` добавлена строка таблицы
- [x] 2.3 Время и размер: замерить накат `000037` на пустой базе и на базе с данными prod-размера. Проверка: накат укладывается в таймаут миграционного шага образа (`Containerfile`), результат записан в `design.md` (Risks)

## 3. Документация и версия

- [x] 3.1 `VERSION` → `0.4.1`, раздел про миграции в `README.md` и `schema/README.md` (набор общих иконок, как его пересоздать генератором, правило «не править `up.sql` руками»). Проверка: в README описан порядок `collect` → `build` → накат и он выполняется как написан
- [ ] 3.2 Спецификация `default-reference-icons` попадает в основные после слияния (`openspec archive`). Проверка: `openspec validate --all` без новых ошибок

## 4. Проверка на устройстве

- [ ] 4.1 После выката rc-тега на test (`wallet-api 0.4.1-rc.1`, `release-watch`) и `test-refresh`: в `icon` 87 общих иконок, веб показывает флаги в форме валют, Pixel 8 Pro проходит «Синхронизировать сейчас» без «нет иконки-заместителя» и операция списания из `archive-wallet-writeoff` видна в web. Проверка: ручная на test — Тест: [android-wallet#44](https://github.com/WalletTransactions/android-wallet/issues/44)

## Workflow follow-up

- Выкат на prod (`:8090`) — отдельная задача после проверки на test: перед накатом проверить, какие общие иконки уже есть на prod (набор их пропустит, а не затрёт).
- Архивировать change после 4.1.
