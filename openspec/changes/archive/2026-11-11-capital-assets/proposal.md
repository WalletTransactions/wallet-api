# Proposal

## Why

Покупку квартиры, ремонт, машину сейчас можно провести только расходом на
категорию: деньги «исчезают» из капитала и смешиваются с операционными
тратами, а переоценить имущество негде. Нужно вести такие вложения как
перевод в капитальный актив с периодической переоценкой (issue
[WalletTransactions/.github-private#1](https://github.com/WalletTransactions/.github-private/issues/1),
разбор и ответы на вопросы — в комментариях к нему).

Это серверная часть набора `capital-assets` (парные changes: `android-wallet`,
`wallet-report`, `wallet-web`). wallet-api — единственный владелец схемы и
всех отчётных SQL-функций, поэтому здесь: таблица признака актива, её синк,
системная категория «Переоценка» и правки отчётных функций, которые затем
вызывает wallet-report.

## What Changes

- Новая синхронизируемая таблица `account_asset` — расширение кошелька по
  образцу `account_operating`: строка есть и жива — кошелёк считается
  капитальным активом. Бизнес-колонки: `asset_type` (1 недвижимость, 2 авто,
  3 прочее), `include_in_net_worth`, `comment`.
- `account.system_kind` принимает значение `3` — системная категория
  «Переоценка» (Revaluation). Проводка переоценки — обычная операция между
  этой категорией и активом.
- Синк: `account_asset` в потоке `ledger`, push и pull; применяется после
  `account_operating`.
- Отчётные функции (новая миграция, номер — следующий свободный на момент
  реализации, с парным `.down.sql`):
  - доход/расход-функции и `f_wallet_turnover_for_period` не учитывают
    проводки переоценки;
  - `f_operations_for_period` отдаёт им `kind = 'revaluation'`;
  - балансовые функции (`f_balance_to_date`, `f_balance_to_dates`,
    `f_balance_series`) отдают на строке кошелька `asset_type` (`NULL` —
    ликвидный) и `include_in_net_worth`;
  - новая `f_assets_for_period` — сводка по каждому активу: вложено,
    переоценка накопленная и за период, оценка на конец, доходность.
- Справочные `schema/`, `README.md`, `openapi.yaml` (схемы push/pull).

Несовместимых изменений протокола нет: новая таблица старым клиентам не
мешает. Старый клиент покажет актив обычным кошельком, а переоценку —
обычной категорией (см. design, «Совместимость»).

## Capabilities

### New Capabilities
- `capital-assets`: что делает кошелёк капитальным активом, какие значения
  допустимы, системная категория «Переоценка» и доставка признака актива
  между устройствами.

### Modified Capabilities
- `sync-push`: в список синхронизируемых таблиц и в порядок применения
  батча добавляется `account_asset`.

Смысл и результаты отчётных функций по `wallet-schema-ownership` описывают
спецификации wallet-report (парный change), поэтому здесь отдельной
отчётной capability нет.

## Impact

- **Схема:** миграция с `account_asset`, расширенным CHECK
  `account.system_kind`, явным `GRANT SELECT` на `account_asset` роли
  `wallet_reader` и пересозданными отчётными функциями; зеркала в
  `schema/table/`, `schema/function/`, `schema/role/wallet_reader.sql`.
- **Код:** `src/sync_repo.cpp` (`push_tables()`, `kApplyOrder`),
  `openapi.yaml` (`syncPush`/`syncPull`), README.
- **wallet-report:** вызывает новые колонки и `f_assets_for_period`, а в
  `/wallet-turnover` и `/accounts` сам делает `LEFT JOIN account_asset`
  (парный change). Новые колонки добавляются в конец, поэтому старый
  wallet-report после миграции продолжает работать.
- **android-wallet:** таблица, синк, «Переоценка», UI (парный change).
  **wallet-telegram:** правок нет — бот шлёт только новые операции.
- **Порядок выката:** миграция и wallet-api выходят раньше Android-версии с
  активами (см. design, «Миграция и выкат»).
- **Пересечения:** `currency-ui-tweaks` и `purge-synced-tombstones` уже
  заявляют номер `000026`; `add-operations-filter-functions` и
  `partition-operation-by-ledger` пересоздают те же отчётные функции.
