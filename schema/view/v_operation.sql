-- Операция с раскрытыми именами счетов, валютой и признаками «операционный ли
-- счёт» с каждой стороны. Порт v_operation из android-wallet/schema/view/.
--
-- currency_uuid берётся с той стороны проводки, у которой валюта есть: расход это
-- «кошелёк -> категория», доход «категория -> кошелёк», и в обоих случаях валюту
-- задаёт кошелёк. Для перевода «кошелёк -> кошелёк» COALESCE берёт валюту
-- списания, как и в клиенте — вторая нога такого перевода приезжает отдельной
-- проводкой и связана через operation_link.
--
-- Счета НЕ фильтруются по deleted_at, и это существенно. Клиент удаляет счёт
-- физически, поэтому у него такой ситуации нет; на сервере удаление мягкое, и
-- живая операция вполне может ссылаться на снятый счёт. Отсеки мы их здесь —
-- операция молча исчезла бы из отчёта, а сумма по периоду занизилась.
--
-- Признаки acc_from_is_operating / acc_to_is_operating здесь boolean, а не 1/0:
-- в PostgreSQL для этого есть тип, и потребителю не придётся сравнивать с
-- единицей. Смысл тот же.
CREATE VIEW v_operation AS
SELECT o.ledger_id,
       o.uuid,
       o."date",
       o.acc_fr_uuid,
       o.acc_to_uuid,
       o.amount,
       o.comment,
       acf.name AS acc_fr_name,
       act.name AS acc_to_name,
       COALESCE(aof.currency_uuid, aot.currency_uuid) AS currency_uuid,
       (aof.uuid IS NOT NULL) AS acc_from_is_operating,
       (aot.uuid IS NOT NULL) AS acc_to_is_operating
  FROM operation o
  JOIN account acf
    ON acf.ledger_id = o.ledger_id
   AND acf.uuid      = o.acc_fr_uuid
  JOIN account act
    ON act.ledger_id = o.ledger_id
   AND act.uuid      = o.acc_to_uuid
  LEFT JOIN account_operating aof
         ON aof.ledger_id = acf.ledger_id
        AND aof.uuid      = acf.uuid
        AND aof.deleted_at IS NULL
  LEFT JOIN account_operating aot
         ON aot.ledger_id = act.ledger_id
        AND aot.uuid      = act.uuid
        AND aot.deleted_at IS NULL
 WHERE o.deleted_at IS NULL;
