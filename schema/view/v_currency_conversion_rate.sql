-- Курс на дату по каждому направлению из v_currency_conversion, с уже применённым
-- 1/rate для обратного направления, плюс тождественный курс 1 валюты в саму себя.
--
-- UNION с тождественным курсом — не украшение: благодаря ему пересчёт валюты в
-- себя всегда находит курс, и вызывающему коду не нужна отдельная ветка «если
-- валюты совпали». Дата '2000-01-01' заведомо раньше любой операции.
--
-- Область видимости курса и направления могут различаться: ручной курс леджера
-- ставится и к ОБЩЕЙ паре. Поэтому джойн разрешает сочетание, когда хотя бы одна
-- сторона общая, а наружу отдаётся более узкая из двух — курс леджера делает
-- строку строкой леджера.
--
-- is_reverse и num наружу не выводятся, как и в клиенте: они использованы внутри
-- вычисления rate, и показывать их значило бы предлагать считать курс заново.
CREATE VIEW v_currency_conversion_rate AS
SELECT COALESCE(r.ledger_id, cc.ledger_id) AS ledger_id,
       cc.from_currency_uuid,
       cc.from_currency_name,
       cc.from_currency_iso,
       cc.to_currency_uuid,
       cc.to_currency_name,
       cc.to_currency_iso,
       r."date",
       CASE WHEN cc.is_reverse THEN 1.0 / r.rate ELSE r.rate END AS rate
  FROM v_currency_conversion cc
  JOIN currency_pair_rate r
    ON r.currency_pair_uuid = cc.currency_pair_uuid
   AND r.deleted_at IS NULL
   AND (cc.ledger_id IS NULL OR r.ledger_id IS NULL OR r.ledger_id = cc.ledger_id)

UNION ALL

SELECT c.ledger_id,
       c.uuid, c.name, c.iso_code,
       c.uuid, c.name, c.iso_code,
       DATE '2000-01-01',
       1::numeric
  FROM currency c
 WHERE c.deleted_at IS NULL;
