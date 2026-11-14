-- default-reference-currencies (wallet-api/openspec/changes/default-reference-currencies):
-- общий справочник валют и валютных пар по умолчанию — снимок стартового набора
-- телефона (android-wallet seed.json: валюты и пары без курсов). Файл СГЕНЕРИРОВАН
-- scripts/gen_default_currencies.py из migrations/default_currencies/manifest.json —
-- руками не править (README.md, раздел «Миграции»).
--
-- Что делает:
--  * currency — общие валюты (ledger_id IS NULL) с детерминированным uuid
--    md5('reference-currency:' || iso_code); иконка — живая общая иконка с именем
--    из набора (набор иконок — миграции 000037, 000038); валюта, для которой иконки
--    нет, пропускается;
--  * currency_pair — общие пары с детерминированным uuid
--    md5('reference-currency-pair:' || symbol), точность 5; база и квота —
--    живые общие валюты по коду;
--  * один seq потока reference на всю вставку (как атомарный батч синка), и только
--    если есть что вставлять — повторный накат поток не двигает;
--  * валюта с кодом или названием (без учёта регистра), уже занятыми живой общей
--    валютой, и пара с занятым символом пропускаются: работу администратора
--    миграция не трогает и не ловит uq_currency_*_reference. Удалённые (deleted_at)
--    строки набору не мешают, а сами не воскресают (ON CONFLICT (uuid) DO NOTHING);
--  * курсов нет — только справочник.
DO $$
DECLARE
    v_seq bigint;
BEGIN
    CREATE TEMP TABLE _default_currency (
        iso_code text NOT NULL, name text NOT NULL, symbol text NOT NULL,
        icon_name text NOT NULL, "precision" smallint NOT NULL) ON COMMIT DROP;
    INSERT INTO _default_currency (iso_code, name, symbol, icon_name, "precision") VALUES
        ('RUB', 'Russian Ruble', '₽', 'Flag RUB', 2),
        ('USD', 'US Dollar', '$', 'Flag USD', 2),
        ('EUR', 'Euro', '€', 'Flag Euro', 2),
        ('GBP', 'British Pound', '£', 'Flag GBP', 2),
        ('CNY', 'Chinese Yuan', '¥', 'Flag CNY', 2),
        ('KZT', 'Kazakhstani Tenge', '₸', 'Flag KZT', 2),
        ('BYN', 'Belarusian Ruble', 'Br', 'Flag BYN', 2),
        ('UAH', 'Ukrainian Hryvnia', '₴', 'Flag UAH', 2),
        ('GEL', 'Georgian Lari', '₾', 'Flag GEL', 2),
        ('AMD', 'Armenian Dram', '֏', 'Flag AMD', 2),
        ('TRY', 'Turkish Lira', '₺', 'Flag TRY', 2),
        ('RSD', 'Serbian Dinar', 'din.', 'Serbian flag', 2),
        ('PLN', 'Polish Zloty', 'zł', 'Flag PLN', 2),
        ('THB', 'Thai Baht', '฿', 'Flag THB', 2),
        ('AED', 'UAE Dirham', 'AED', 'Flag AED', 2),
        ('BTC', 'Bitcoin', '₿', 'Flag BTC', 8),
        ('LTC', 'Litecoin', 'Ł', 'Flag LTC', 8);

    CREATE TEMP TABLE _default_currency_todo ON COMMIT DROP AS
        SELECT md5('reference-currency:' || d.iso_code)::uuid AS uuid, d.iso_code, d.name,
               d.symbol, i.uuid AS icon_uuid, d."precision"
          FROM _default_currency d
          JOIN icon i ON i.ledger_id IS NULL AND i.deleted_at IS NULL
                     AND lower(i.name) = lower(d.icon_name)
         WHERE NOT EXISTS (SELECT 1 FROM currency c
                            WHERE c.ledger_id IS NULL AND c.deleted_at IS NULL
                              AND (upper(c.iso_code) = d.iso_code OR lower(c.name) = lower(d.name)));

    IF EXISTS (SELECT 1 FROM _default_currency_todo) THEN
        v_seq := next_seq('00000000-0000-0000-0000-000000000001'::uuid);
        INSERT INTO currency (uuid, ledger_id, seq, name, iso_code, icon_uuid, symbol, "precision")
        SELECT uuid, NULL, v_seq, name, iso_code, icon_uuid, symbol, "precision"
          FROM _default_currency_todo
        ON CONFLICT (uuid) DO NOTHING;
    END IF;

    CREATE TEMP TABLE _default_pair (symbol text NOT NULL, base text NOT NULL, quote text NOT NULL) ON COMMIT DROP;
    INSERT INTO _default_pair (symbol, base, quote) VALUES
        ('EURUSD', 'EUR', 'USD'),
        ('USDRUB', 'USD', 'RUB'),
        ('EURRUB', 'EUR', 'RUB'),
        ('USDGBP', 'USD', 'GBP'),
        ('EURGBP', 'EUR', 'GBP'),
        ('USDCNY', 'USD', 'CNY'),
        ('EURCNY', 'EUR', 'CNY'),
        ('USDKZT', 'USD', 'KZT'),
        ('EURKZT', 'EUR', 'KZT'),
        ('USDBYN', 'USD', 'BYN'),
        ('EURBYN', 'EUR', 'BYN'),
        ('USDUAH', 'USD', 'UAH'),
        ('EURUAH', 'EUR', 'UAH'),
        ('USDGEL', 'USD', 'GEL'),
        ('EURGEL', 'EUR', 'GEL'),
        ('USDAMD', 'USD', 'AMD'),
        ('EURAMD', 'EUR', 'AMD'),
        ('USDTRY', 'USD', 'TRY'),
        ('EURTRY', 'EUR', 'TRY'),
        ('USDRSD', 'USD', 'RSD'),
        ('EURRSD', 'EUR', 'RSD'),
        ('USDPLN', 'USD', 'PLN'),
        ('EURPLN', 'EUR', 'PLN'),
        ('USDTHB', 'USD', 'THB'),
        ('EURTHB', 'EUR', 'THB'),
        ('USDAED', 'USD', 'AED'),
        ('EURAED', 'EUR', 'AED'),
        ('BTCUSD', 'BTC', 'USD'),
        ('BTCEUR', 'BTC', 'EUR'),
        ('LTCUSD', 'LTC', 'USD'),
        ('LTCEUR', 'LTC', 'EUR');

    CREATE TEMP TABLE _default_pair_todo ON COMMIT DROP AS
        SELECT md5('reference-currency-pair:' || p.symbol)::uuid AS uuid, p.symbol,
               b.uuid AS base_uuid, q.uuid AS quote_uuid
          FROM _default_pair p
          JOIN currency b ON b.ledger_id IS NULL AND b.deleted_at IS NULL AND upper(b.iso_code) = p.base
          JOIN currency q ON q.ledger_id IS NULL AND q.deleted_at IS NULL AND upper(q.iso_code) = p.quote
         WHERE NOT EXISTS (SELECT 1 FROM currency_pair x
                            WHERE x.ledger_id IS NULL AND x.deleted_at IS NULL
                              AND upper(x.symbol) = p.symbol);

    IF EXISTS (SELECT 1 FROM _default_pair_todo) THEN
        IF v_seq IS NULL THEN
            v_seq := next_seq('00000000-0000-0000-0000-000000000001'::uuid);
        END IF;
        INSERT INTO currency_pair (uuid, ledger_id, seq, symbol, base_currency_uuid, quote_currency_uuid, "precision")
        SELECT uuid, NULL, v_seq, symbol, base_uuid, quote_uuid, 5 FROM _default_pair_todo
        ON CONFLICT (uuid) DO NOTHING;
    END IF;
END
$$;
