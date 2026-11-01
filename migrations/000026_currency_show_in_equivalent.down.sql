-- Откат 000026_currency_show_in_equivalent.up.sql. Перед ним откатываются
-- wallet-report и клиенты, которые читают поле.
ALTER TABLE currency DROP COLUMN show_in_equivalent;
