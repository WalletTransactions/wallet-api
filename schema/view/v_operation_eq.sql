-- v_operation плюс курс на дату операции и сумма в эквиваленте — по строке на
-- каждую валюту эквивалента. Порт v_operation_eq из android-wallet/schema/view/.
--
-- Клиент реализует «курс на дату» через max(date) с группировкой по всем полям
-- операции и последующим джойном обратно за самим курсом. Здесь то же самое
-- выражено боковым соединением с LIMIT 1: смысл идентичен, но группировки по
-- дюжине колонок нет, а сортировка ложится на индекс
-- ix_currency_pair_rate_lookup (currency_pair_uuid, date DESC).
--
-- Порядок в LATERAL задаёт два правила разом:
--   date DESC          — последний курс не позже даты операции;
--   ledger_id IS NULL  — при равной дате ручной курс леджера бьёт общий
--                        (false сортируется раньше true).
--
-- Отсутствие COALESCE на курсе — принципиально, как и в клиенте. Если подставить
-- сюда 1, строка без курса перестанет быть NULL, кошелёк без курса молча войдёт в
-- итоги по курсу 1:1 и завысит их. NULL здесь означает «пересчитать нельзя», и
-- отчёт обязан пометить такую сумму как неполную (см. три состояния эквивалента
-- в android-wallet/docs/ARCHITECTURE.md).
--
-- Округление идёт по precision валюты эквивалента, а не по зашитой двойке, как в
-- клиенте: колонка для этого заведена, и захардкоженные два знака врали бы для
-- валюты с другой точностью.
--
-- Валюты эквивалента берутся видимые леджеру: общие плюс его собственные.
CREATE VIEW v_operation_eq AS
SELECT o.ledger_id,
       o.uuid,
       o."date",
       o.acc_fr_uuid,
       o.acc_to_uuid,
       o.amount,
       o.comment,
       o.acc_fr_name,
       o.acc_to_name,
       o.acc_from_is_operating,
       o.acc_to_is_operating,
       o.currency_uuid,
       tc.uuid                                   AS to_currency_uuid,
       r."date"                                  AS max_date_rate,
       r.rate,
       round(r.rate * o.amount, tc."precision")  AS amount_eq
  FROM v_operation o
  CROSS JOIN LATERAL (
        SELECT c.uuid, c."precision"
          FROM currency c
         WHERE c.deleted_at IS NULL
           AND (c.ledger_id IS NULL OR c.ledger_id = o.ledger_id)
       ) tc
  LEFT JOIN LATERAL (
        SELECT rr."date", rr.rate
          FROM v_currency_conversion_rate rr
         WHERE rr.from_currency_uuid = o.currency_uuid
           AND rr.to_currency_uuid   = tc.uuid
           AND rr."date"            <= o."date"::date
           AND (rr.ledger_id IS NULL OR rr.ledger_id = o.ledger_id)
         ORDER BY rr."date" DESC, (rr.ledger_id IS NULL)
         LIMIT 1
       ) r ON true;
