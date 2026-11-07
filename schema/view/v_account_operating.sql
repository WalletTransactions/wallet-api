-- Счета, у которых есть строка в account_operating — то есть кошельки, а не
-- категории. INNER JOIN, не LEFT: строка без пары в account_operating сюда
-- не попадает вообще (обратный фильтр — v_account_expanse.sql).
--
-- asset_type/include_in_net_worth (capital-assets, миграция 000033) — признак
-- капитального актива из ЖИВОЙ строки account_asset (LEFT JOIN); NULL у обоих
-- — ликвидный кошелёк. Определение «что такое актив» для балансовых функций
-- живёт здесь одним местом: актив — кошелёк, у которого живы account,
-- account_operating и account_asset. Колонки — в конце: так CREATE OR REPLACE
-- VIEW их допускает.
CREATE VIEW v_account_operating AS
SELECT a.uuid, a.ledger_id, a.name, a.comment, a.icon_uuid, a.is_archived, ao.currency_uuid,
       aa.asset_type, aa.include_in_net_worth
  FROM account a
  JOIN account_operating ao
    ON ao.ledger_id = a.ledger_id
   AND ao.uuid      = a.uuid
  LEFT JOIN account_asset aa
    ON aa.ledger_id  = a.ledger_id
   AND aa.uuid       = a.uuid
   AND aa.deleted_at IS NULL
 WHERE a.deleted_at IS NULL
   AND ao.deleted_at IS NULL;
