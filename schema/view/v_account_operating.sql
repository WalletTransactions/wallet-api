-- Счета, у которых есть строка в account_operating — то есть кошельки, а не
-- категории. INNER JOIN, не LEFT: строка без пары в account_operating сюда
-- не попадает вообще (обратный фильтр — v_account_expanse.sql).
CREATE VIEW v_account_operating AS
SELECT a.uuid, a.ledger_id, a.name, a.comment, a.icon_uuid, a.is_archived, ao.currency_uuid
  FROM account a
  JOIN account_operating ao
    ON ao.ledger_id = a.ledger_id
   AND ao.uuid      = a.uuid
 WHERE a.deleted_at IS NULL
   AND ao.deleted_at IS NULL;
