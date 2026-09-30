-- Явная роль связки operation_link (обсуждение 2026-09-09, план "Б" по
-- Android/TODO_transfers.md) — тем же приёмом, что 000012_account_system_kind.
--
-- До этой миграции роль (нога валютного перевода / комиссия) нигде не
-- хранилась и выводилась в коде на лету — сначала по совпадению id со счётом
-- главной проводки, затем по system_kind счёта-источника связанной проводки
-- (TransactionActivity.loadLinkedParts / WalletDbLoader.AttachLinksTo).
-- Явное поле нужно уже сейчас: следующие виды связок будут отображаться в
-- окне операции иначе, а вывод по счетам для них уже не с чем сравнивать.
ALTER TABLE operation_link
    ADD COLUMN type smallint NOT NULL DEFAULT 0 CHECK (type IN (0, 1));

COMMENT ON COLUMN operation_link.type IS
    'Явная роль связки: 0 = нога валютного перевода, 1 = комиссия (см. OperationItem.LinkType на клиенте). Заменяет прежний вывод по system_kind счёта-источника.';

-- Бэкфилл — единственное легитимное место вывода type из system_kind: ровно
-- момент превращения старого неявного состояния в новое явное. DEFAULT уже
-- поставил всем "нога" (0); здесь донастраиваем на "комиссия" (1) те связки,
-- чья проводка списывается не с системной категории Transfer. Та же логика
-- выполняется и на клиенте (WalletDbHelper, шаг v77) — бэкфилл должен дать
-- одинаковый результат на обеих сторонах.
UPDATE operation_link
SET type = 1
WHERE type = 0
  AND (ledger_id, link_uuid) IN (
      SELECT o.ledger_id, o.uuid
        FROM operation o
        JOIN account a ON a.ledger_id = o.ledger_id AND a.uuid = o.acc_fr_uuid
       WHERE a.system_kind <> 1
  );
