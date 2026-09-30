-- Явный признак «кошелёк или категория» (обсуждение 2026-09-09, см.
-- schema/server/table/account.sql) — тем же приёмом, что 000012_account_system_kind.
--
-- До этой миграции признак нигде не хранился явно — вычислялся join'ом на
-- account_operating (есть строка — кошелёк, нет — категория). account_operating
-- никуда не делась и остаётся источником валюты кошелька; kind — её явный,
-- дешёвый в проверке слепок на самой строке account.
ALTER TABLE account
    ADD COLUMN kind smallint NOT NULL DEFAULT 0 CHECK (kind IN (0, 1));

COMMENT ON COLUMN account.kind IS
    'Явный признак «кошелёк или категория»: 0 = категория, 1 = кошелёк (см. AccountItem.Kind на клиенте). Дублирует наличие строки в account_operating, проставляется один раз при создании и дальше не меняется.';

-- Бэкфилл — единственное легитимное место, где kind выводится из наличия
-- строки в account_operating, а не берётся готовым: ровно момент превращения
-- старого неявного состояния в новое явное. Та же логика (наличие живой
-- строки в account_operating) выполняется и на клиенте (WalletDbHelper, шаг
-- v76) — бэкфилл должен дать одинаковый результат на обеих сторонах, иначе
-- после следующего push/pull kind разъедется между устройством и сервером.
UPDATE account SET kind = 1 WHERE EXISTS (
    SELECT 1 FROM account_operating ao
    WHERE ao.ledger_id = account.ledger_id
      AND ao.uuid = account.uuid
      AND ao.deleted_at IS NULL
);
