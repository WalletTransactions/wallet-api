-- Имя счёта уникально без учёта регистра, «ё» = «е» (org/docs/TODO_telegram_bot.md,
-- «Открытые вопросы», решение 2026-10-01). Раньше индекс сравнивал имя как есть, и в
-- одном леджере могли жить «Кафе» и «кафе»; бот (text::normalize_name) нашёл бы два
-- точных совпадения. То же правило на Android (v80, AccountNames: replace(lower(name),
-- 'ё', 'е')) — результат одинаковый.
--
-- Живых дублей по новому правилу на момент миграции не было (проверено 2026-10-01),
-- поэтому без чистки: если они появились, CREATE UNIQUE INDEX упадёт и миграция
-- откатится целиком — разбираться вручную.
DROP INDEX uq_account_name;
CREATE UNIQUE INDEX uq_account_name ON account (ledger_id, lower(translate(name, 'Ёё', 'Ее')))
    WHERE deleted_at IS NULL;

COMMENT ON COLUMN account.name IS
    'Название счёта/категории, видимое пользователю — уникально среди живых (deleted_at IS NULL) строк леджера без учёта регистра, «ё» = «е», см. uq_account_name.';
