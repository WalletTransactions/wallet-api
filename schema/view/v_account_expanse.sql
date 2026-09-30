-- Обратный фильтр к v_account_operating: счета БЕЗ строки в account_operating,
-- то есть категории расходов и доходов, а не кошельки.
--
-- В клиенте вьюха определена, но не используется — экраны фильтруют категории на
-- стороне Java через AccountList. На сервере такого слоя нет: сервису отчётов
-- различать кошельки и категории придётся в SQL, поэтому здесь она не декоративная.
CREATE VIEW v_account_expanse AS
SELECT a.ledger_id,
       a.uuid,
       a.name,
       a.comment,
       a.icon_uuid,
       a.is_archived
  FROM account a
  LEFT JOIN account_operating ao
         ON ao.ledger_id = a.ledger_id
        AND ao.uuid      = a.uuid
        AND ao.deleted_at IS NULL
 WHERE a.deleted_at IS NULL
   AND ao.uuid IS NULL;
