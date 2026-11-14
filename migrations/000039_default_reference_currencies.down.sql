-- Откат 000039 default_reference_currencies: удаляет только пары и валюты этого набора (по
-- детерминированным uuid md5('reference-currency-pair:' || symbol) и
-- md5('reference-currency:' || iso_code)). Пары и валюты администратора (другие uuid)
-- не трогаются. Строка, на которую уже кто-то ссылается (кошелёк с этой валютой,
-- курс пары), остаётся: внешний ключ не даёт её удалить, и откат её пропускает.
-- seq потока reference назад не возвращается; после того как клиенты забрали набор,
-- схему назад не откатываем (как 000036).
-- Файл СГЕНЕРИРОВАН scripts/gen_default_currencies.py.
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT md5('reference-currency-pair:' || n.symbol)::uuid AS uuid
               FROM (VALUES
        ('EURUSD'),
        ('USDRUB'),
        ('EURRUB'),
        ('USDGBP'),
        ('EURGBP'),
        ('USDCNY'),
        ('EURCNY'),
        ('USDKZT'),
        ('EURKZT'),
        ('USDBYN'),
        ('EURBYN'),
        ('USDUAH'),
        ('EURUAH'),
        ('USDGEL'),
        ('EURGEL'),
        ('USDAMD'),
        ('EURAMD'),
        ('USDTRY'),
        ('EURTRY'),
        ('USDRSD'),
        ('EURRSD'),
        ('USDPLN'),
        ('EURPLN'),
        ('USDTHB'),
        ('EURTHB'),
        ('USDAED'),
        ('EURAED'),
        ('BTCUSD'),
        ('BTCEUR'),
        ('LTCUSD'),
        ('LTCEUR')
               ) n(symbol)
    LOOP
        BEGIN
            DELETE FROM currency_pair WHERE uuid = r.uuid;
        EXCEPTION WHEN foreign_key_violation THEN
            NULL;
        END;
    END LOOP;

    FOR r IN SELECT md5('reference-currency:' || n.iso_code)::uuid AS uuid
               FROM (VALUES
        ('RUB'),
        ('USD'),
        ('EUR'),
        ('GBP'),
        ('CNY'),
        ('KZT'),
        ('BYN'),
        ('UAH'),
        ('GEL'),
        ('AMD'),
        ('TRY'),
        ('RSD'),
        ('PLN'),
        ('THB'),
        ('AED'),
        ('BTC'),
        ('LTC')
               ) n(iso_code)
    LOOP
        BEGIN
            DELETE FROM currency WHERE uuid = r.uuid;
        EXCEPTION WHEN foreign_key_violation THEN
            NULL;
        END;
    END LOOP;
END
$$;
