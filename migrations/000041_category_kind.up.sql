-- 000041 category-kind-income-expense: вид категории — расход / доход / оба.
-- Явный признак на самой строке account (design D1), того же рода, что
-- system_kind и kind: клиенты по нему разделяют «Статью расхода» и «Статью
-- дохода» при вводе операции.
--
-- 1. Колонка category_kind: 0 = расход, 1 = доход, 2 = оба (умолчание). Для
--    кошельков и системных категорий вид не задаётся — у них всегда 2; сервер
--    сочетание kind/system_kind/category_kind не проверяет (решает клиент).
-- 2. Разметка живых обычных категорий по живым операциям их леджера (D5):
--    только «категория → кошелёк» (acc_fr_uuid) — 1, только «кошелёк →
--    категория» (acc_to_uuid) — 0, обе стороны или ни одной — 2. Строки с
--    итогом 2 не трогаются — колонка у них уже 2, seq не двигается.
-- 3. Изменённым строкам — один next_seq на леджер и updated_by = NULL
--    (изменение сервера, как в 000035): устройство, уже дочитавшее поток,
--    получит разметку следующим /sync/pull.
--
-- operation секционирована по ledger_id (000040), поэтому разметка идёт в цикле
-- по леджерам: каждый запрос к operation фильтруется по ledger_id и трогает
-- одну секцию, а не все шестнадцать.
--
-- Файл без собственных BEGIN/COMMIT: golang-migrate выполняет его одним
-- запросом (одна неявная транзакция), а тест прогоняет его внутри своей
-- откатываемой транзакции.

ALTER TABLE account
    ADD COLUMN category_kind smallint NOT NULL DEFAULT 2
        CHECK (category_kind IN (0, 1, 2));

COMMENT ON COLUMN account.category_kind IS
    'Вид категории: 0 = расход, 1 = доход, 2 = оба (умолчание). Для кошельков и системных категорий всегда 2. Изменяемое поле — пользователь меняет вид в карточке категории.';

DO $$
DECLARE
    l_ledger uuid;
    l_seq    bigint;
    l_uuids  uuid[];
    l_kinds  smallint[];
BEGIN
    FOR l_ledger IN SELECT l.id FROM ledger l
    LOOP
        -- Только категории с видом, отличным от 2: у остальных колонка уже
        -- равна умолчанию.
        SELECT array_agg(c.uuid), array_agg(c.k)
          INTO l_uuids, l_kinds
          FROM (
              SELECT a.uuid,
                     (CASE
                          WHEN s.fr AND NOT s.tw THEN 1
                          WHEN s.tw AND NOT s.fr THEN 0
                          ELSE 2
                      END)::smallint AS k
                FROM account a
               CROSS JOIN LATERAL (
                     SELECT EXISTS (SELECT 1 FROM operation o
                                     WHERE o.ledger_id = l_ledger
                                       AND o.acc_fr_uuid = a.uuid
                                       AND o.deleted_at IS NULL) AS fr,
                            EXISTS (SELECT 1 FROM operation o
                                     WHERE o.ledger_id = l_ledger
                                       AND o.acc_to_uuid = a.uuid
                                       AND o.deleted_at IS NULL) AS tw
               ) s
               WHERE a.ledger_id = l_ledger
                 AND a.kind = 0
                 AND a.system_kind = 0
                 AND a.deleted_at IS NULL
          ) c
         WHERE c.k <> 2;

        IF l_uuids IS NOT NULL THEN
            l_seq := next_seq(l_ledger);
            UPDATE account a
               SET category_kind = t.k, seq = l_seq, updated_by = NULL
              FROM unnest(l_uuids, l_kinds) AS t(uuid, k)
             WHERE a.ledger_id = l_ledger
               AND a.uuid = t.uuid;
        END IF;
    END LOOP;
END
$$;
