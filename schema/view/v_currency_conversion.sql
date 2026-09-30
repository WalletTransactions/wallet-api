-- Маршрут пересчёта одной валюты в другую: каждая пара развёрнута в ОБА
-- направления (base -> quote и quote -> base с флагом is_reverse), поверх них
-- левым джойном подмешано переопределение из currency_conversion.
--
-- Смысл приёма тот же, что в клиенте: запрос выше по стеку спрашивает курс
-- from -> to и не обязан знать, в какую сторону задана пара — обратное
-- направление уже готово здесь.
--
-- ledger_id: NULL означает, что направление доступно всем, заполненный — только
-- своему леджеру. Обе строки остаются видимыми, а перекрытие «своё поверх общего»
-- делается там, где выбирается конкретный курс (v_operation_eq). Иначе пришлось бы
-- разворачивать каждую общую строку на все леджеры, то есть строить декартово
-- произведение со всей историей курсов ради выбора одной строки.
--
-- Ограничение по переопределениям: currency_conversion присоединяется только в
-- своей области видимости (IS NOT DISTINCT FROM). Своё переопределение поверх
-- ОБЩЕЙ пары не поддержано намеренно — в клиенте эта таблица всегда пуста
-- (android-wallet/schema/table/README.md), и вводить непроверенную семантику ради
-- ненаполняемой таблицы незачем.
CREATE VIEW v_currency_conversion AS
SELECT COALESCE(cc.ledger_id, fk.ledger_id)                   AS ledger_id,
       fc.uuid                                                AS from_currency_uuid,
       fc.name                                                AS from_currency_name,
       fc.iso_code                                            AS from_currency_iso,
       tc.uuid                                                AS to_currency_uuid,
       tc.name                                                AS to_currency_name,
       tc.iso_code                                            AS to_currency_iso,
       COALESCE(cc.currency_pair_uuid, fk.currency_pair_uuid) AS currency_pair_uuid,
       COALESCE(cc.num, fk.num)                               AS num,
       COALESCE(cc.is_reverse, fk.is_reverse)                 AS is_reverse
  FROM (
        SELECT cp.uuid                AS currency_pair_uuid,
               cp.ledger_id,
               cp.base_currency_uuid  AS from_currency_uuid,
               cp.quote_currency_uuid AS to_currency_uuid,
               0::smallint            AS num,
               false                  AS is_reverse
          FROM currency_pair cp
         WHERE cp.deleted_at IS NULL
        UNION ALL
        SELECT cp.uuid,
               cp.ledger_id,
               cp.quote_currency_uuid,
               cp.base_currency_uuid,
               0::smallint,
               true
          FROM currency_pair cp
         WHERE cp.deleted_at IS NULL
       ) fk
  LEFT JOIN currency_conversion cc
         ON cc.from_currency_uuid = fk.from_currency_uuid
        AND cc.to_currency_uuid   = fk.to_currency_uuid
        AND cc.ledger_id IS NOT DISTINCT FROM fk.ledger_id
        AND cc.deleted_at IS NULL
  JOIN currency fc
    ON fc.uuid = COALESCE(cc.from_currency_uuid, fk.from_currency_uuid)
   AND fc.deleted_at IS NULL
  JOIN currency tc
    ON tc.uuid = COALESCE(cc.to_currency_uuid, fk.to_currency_uuid)
   AND tc.deleted_at IS NULL;
