-- Флаг «показывать в пикерах валюты эквивалента» (change currency-ui-tweaks).
-- Константный DEFAULT не переписывает таблицу; существующие валюты получают true,
-- поведение не меняется, пока флаг не сняли. seq не трогается: клиенты знают
-- значение по умолчанию сами (старый клиент без ключа в push флаг не сбрасывает,
-- см. TableSpec::optional_columns в src/sync_repo.hpp).
ALTER TABLE currency ADD COLUMN show_in_equivalent boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN currency.show_in_equivalent IS
    'Показывать ли валюту в выборе валюты эквивалента (отчёты, пикеры). true по умолчанию; в push необязательна — строка без ключа не меняет прежнее значение.';
