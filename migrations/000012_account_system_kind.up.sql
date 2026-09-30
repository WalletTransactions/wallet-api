-- Явный признак системной категории вместо распознавания по name
-- (обсуждение 2026-09-09, см. schema/server/table/account.sql).
--
-- До этой миграции ни клиент, ни сервер не хранили признак системности
-- вообще — обе стороны сравнивали account.name со строками "Transfer"/
-- "Transfer commission" (AccountItem.isSystemName). Хрупко вдвойне: name —
-- единственное уникальное поле счёта, и переименование системной категории
-- молча снимало с неё защиту от удаления и ломало логику разновалютных
-- переводов (TransactionActivity.GetOrCreateCategory искал её по тому же
-- имени).
--
-- IN (0, 1, 2), а не просто >= 0, в отличие от icon.icon_type: там
-- ограничение снято из-за унаследованных мусорных значений в реальных
-- данных, здесь колонка новая и без такого прошлого.
ALTER TABLE account
    ADD COLUMN system_kind smallint NOT NULL DEFAULT 0 CHECK (system_kind IN (0, 1, 2));

COMMENT ON COLUMN account.system_kind IS
    'Явный признак системной категории вместо распознавания по name: 0 = обычная, 1 = Transfer, 2 = Transfer commission (см. AccountItem.SystemKind на клиенте).';

-- Бэкфилл — ЕДИНСТВЕННОЕ оставшееся легитимное место сравнения по имени:
-- ровно момент превращения старого неявного состояния в новое явное. Ровно
-- та же пара UPDATE выполняется и на клиенте (WalletDbHelper, шаг v75) —
-- бэкфилл должен дать одинаковый результат на обеих сторонах, иначе после
-- следующего push/pull system_kind разъедется между устройством и сервером.
UPDATE account SET system_kind = 1 WHERE lower(name) = lower('Transfer');
UPDATE account SET system_kind = 2 WHERE lower(name) = lower('Transfer commission');
