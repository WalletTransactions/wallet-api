-- Откат 000037 default_reference_icons: удаляет только иконки этого набора (по
-- детерминированным uuid md5('reference-icon:' || lower(name))) и blob, на которые
-- после этого никто не ссылается. Иконки администратора (другие uuid) и blob,
-- общий с чужой иконкой, не трогаются. seq потока reference назад не возвращается;
-- после того как клиенты забрали набор, схему назад не откатываем (как 000036).
-- Файл СГЕНЕРИРОВАН scripts/gen_default_icons.py.
DO $$
BEGIN
    CREATE TEMP TABLE _default_icon_gone (sha bytea NOT NULL) ON COMMIT DROP;

    WITH names (name) AS (VALUES
        ('Groceries'),
        ('Restaurants'),
        ('Coffee'),
        ('Bar'),
        ('Public transport'),
        ('Taxi'),
        ('Petrol'),
        ('Car'),
        ('Car wash'),
        ('Parking'),
        ('Road'),
        ('Rentals'),
        ('Electricity'),
        ('Water Bill'),
        ('Gas'),
        ('Internet Bill'),
        ('Phone'),
        ('Doctor'),
        ('Pharmacy pills'),
        ('Clothing'),
        ('Accessories'),
        ('Personal care'),
        ('Hair dress'),
        ('Children & Babies'),
        ('Baby'),
        ('Cat'),
        ('Entertainment'),
        ('Cinema'),
        ('Games'),
        ('Traveling'),
        ('Airline ticket'),
        ('Hotel'),
        ('Sightseeing'),
        ('Presents'),
        ('Charity'),
        ('Book'),
        ('Sports'),
        ('Bicycle'),
        ('TV'),
        ('Electronics'),
        ('Houseware'),
        ('Maintenance'),
        ('Tools'),
        ('Insurance'),
        ('Family'),
        ('Friends'),
        ('Coin'),
        ('Salary'),
        ('Briefcase'),
        ('Percentage'),
        ('Trending up'),
        ('Debt'),
        ('Fees'),
        ('Transfer'),
        ('Money transfer'),
        ('Wallet'),
        ('Visa card'),
        ('MasterCard'),
        ('USD banknote'),
        ('Alcohol'),
        ('Award'),
        ('Baby Sitter'),
        ('Shops'),
        ('Travel'),
        ('unknown'),
        ('Flag ALL'),
        ('Flag ARS'),
        ('Bosnian flag'),
        ('Flag CLP'),
        ('Croatian flag'),
        ('Flag KES'),
        ('Flag TZS'),
        ('Flag RUB'),
        ('Flag USD'),
        ('Flag Euro'),
        ('Flag GBP'),
        ('Flag CNY'),
        ('Flag KZT'),
        ('Flag BYN'),
        ('Flag UAH'),
        ('Flag GEL'),
        ('Flag AMD'),
        ('Flag TRY'),
        ('Serbian flag'),
        ('Flag PLN'),
        ('Flag THB'),
        ('Flag AED')
    ), gone AS (
        DELETE FROM icon i
         USING names n
         WHERE i.uuid = md5('reference-icon:' || lower(n.name))::uuid
        RETURNING i.content_sha256
    )
    INSERT INTO _default_icon_gone (sha) SELECT content_sha256 FROM gone;

    DELETE FROM blob b
     WHERE b.sha256 IN (SELECT sha FROM _default_icon_gone)
       AND NOT EXISTS (SELECT 1 FROM icon i WHERE i.content_sha256 = b.sha256);
END
$$;
