-- Откат 000043: возврат прежнего смысла currency_conversion («переопределение
-- направления пары»), потребителей — на подзапрос к v_currency_conversion_rate.
-- Маршруты, заведённые за время жизни миграции, откат не переживают — поэтому
-- guard: непустую таблицу молча не стираем.

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM currency_conversion) THEN
        RAISE EXCEPTION 'currency_conversion не пуста: откат 000043 потерял бы маршруты (удалите их вручную, если это намеренно)';
    END IF;
END
$$;

-- Потребители — обратно на вьюху курса (зеркало замены в up).
DO $$
DECLARE
    pattern text := 'FROM rate_on\(([^,\n]+), ([^,\n]+), ([^,\n]+), ([^\n]+)\) rr';
    fn      text;
    r       record;
    def     text;
    patched text;
    found   int;
BEGIN
    FOR fn IN VALUES ('f_balance_to_date'), ('f_balance_to_dates'), ('f_balance_series'),
                     ('f_debts_for_period'), ('f_assets_for_period')
    LOOP
        found := 0;
        FOR r IN SELECT p.oid FROM pg_proc p
                  WHERE p.proname = fn AND p.pronamespace = 'public'::regnamespace
        LOOP
            def := pg_get_functiondef(r.oid);
            patched := regexp_replace(def, pattern,
                'FROM v_currency_conversion_rate rr
                 WHERE rr.from_currency_uuid = \2
                   AND rr.to_currency_uuid   = \3
                   AND rr."date"            <= \4
                   AND (rr.ledger_id IS NULL OR rr.ledger_id = \1)
                 ORDER BY rr."date" DESC, (rr.ledger_id IS NULL)
                 LIMIT 1', 'g');
            IF patched <> def THEN
                found := found + 1;
                EXECUTE patched;
            END IF;
        END LOOP;
        IF found = 0 THEN
            RAISE EXCEPTION 'откат 000043: в % не нашлось вызова rate_on', fn;
        END IF;
    END LOOP;
END
$$;

CREATE OR REPLACE VIEW v_operation_eq AS
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

DROP FUNCTION rate_on(uuid, uuid, uuid, date);
DROP FUNCTION rate_fallback(uuid, uuid, uuid, date);

-- Определение v_currency_conversion — из миграции 000002.
CREATE OR REPLACE VIEW v_currency_conversion AS
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

DROP INDEX ix_currency_conversion_pair;
DROP INDEX uq_currency_conversion_ledger_uuid;
DROP INDEX uq_currency_conversion_unordered;
DROP INDEX uq_currency_conversion_step;

ALTER TABLE currency_conversion DROP CONSTRAINT ck_currency_conversion_num;
ALTER TABLE currency_conversion ALTER COLUMN num SET DEFAULT 0;
ALTER TABLE currency_conversion ADD CONSTRAINT currency_conversion_num_check CHECK (num >= 0);
ALTER TABLE currency_conversion ALTER COLUMN ledger_id DROP NOT NULL;

CREATE INDEX ix_currency_conversion_reference_sync ON currency_conversion (seq) WHERE ledger_id IS NULL;

CREATE UNIQUE INDEX uq_currency_conversion_reference
    ON currency_conversion (from_currency_uuid, to_currency_uuid, num)
 WHERE ledger_id IS NULL     AND deleted_at IS NULL;

CREATE UNIQUE INDEX uq_currency_conversion_ledger
    ON currency_conversion (ledger_id, from_currency_uuid, to_currency_uuid, num)
 WHERE ledger_id IS NOT NULL AND deleted_at IS NULL;

COMMENT ON TABLE currency_conversion IS
    'Ручное переопределение маршрута пересчёта одной валюты в другую, когда прямой пары нет. В клиенте таблица всегда пустая — заведена ради полноты зеркала.';
COMMENT ON COLUMN currency_conversion.uuid IS 'Идентификатор строки переопределения.';
COMMENT ON COLUMN currency_conversion.ledger_id IS 'NULL — общее переопределение; заполнено — своё для этого леджера.';
COMMENT ON COLUMN currency_conversion.seq IS 'Версия строки в её потоке изменений (ledger или reference).';
COMMENT ON COLUMN currency_conversion.from_currency_uuid IS 'Исходная валюта пересчёта.';
COMMENT ON COLUMN currency_conversion.to_currency_uuid IS 'Целевая валюта пересчёта.';
COMMENT ON COLUMN currency_conversion.num IS
    'Номер альтернативного маршрута между этой парой валют — на случай нескольких путей пересчёта между одними и теми же валютами.';
COMMENT ON COLUMN currency_conversion.currency_pair_uuid IS 'Пара, курс которой использовать для этого маршрута.';
COMMENT ON COLUMN currency_conversion.is_reverse IS
    'true — использовать обратный курс пары (1.0/rate), false — прямой.';
