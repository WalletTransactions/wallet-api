// Свои валюты леджера с веба (change currency-ui-tweaks, spec currencies-api):
// создание, правка и мягкое удаление. Копия устройства currency_pairs_repo:
// логика отдельно от HTTP-слоя (currencies.cpp), проверяется интеграционным
// тестом напрямую (tests_integration/test_currencies.cpp); разбор тела
// запроса — чистые функции, юнит-тест tests/test_currencies.cpp.
//
// Правила — те же, что у формы валюты на телефоне (design D5/D6):
// - общие валюты (ledger_id IS NULL) этим путём не меняются — 404, как чужие;
// - код и название уникальны среди ВСЕХ видимых живых валют, своих и общих
//   (как getCurrencyByISO на телефоне) — индексы uq_currency_*_ledger общую
//   валюту не видят, поэтому проверка явная, а гонка на индексе тоже даёт 409;
// - удаление запрещено, пока на валюту ссылается живой кошелёк или живая пара
//   (IsCurrencyInUse на телефоне);
// - код валюты, входящей в живую пару, не меняется: символ пары — склейка
//   кодов её валют.
//
// Каждое изменение — одна транзакция с одним next_seq(ledger), updated_by
// пуст (у веб-сессии нет device_id), роль участника не проверяется — всё как
// у currency_pairs_repo (см. его шапку).
#pragma once

#include <optional>
#include <string>

#include "db.hpp"
#include "nlohmann/json.hpp"

namespace currencies_repo {

// Разобранное тело POST/PATCH: заданы только присланные поля. Значения уже
// нормализованы: края name/symbol обрезаны, iso_code в верхнем регистре.
// Пустой symbol остаётся пустым — подставить iso_code дело create/update
// (при PATCH код мог и не прийти).
struct CurrencyInput {
    std::optional<std::string> name;
    std::optional<std::string> iso_code;
    std::optional<std::string> symbol;
    std::optional<int> precision;
    std::optional<std::string> icon_uuid;
    std::optional<bool> show_in_equivalent;
};

// error пусто — тело годится; иначе текст для 400 и имя поля (field).
struct ParseResult {
    std::string error;
    std::string field;
    CurrencyInput input;
};

// POST: name, iso_code, icon_uuid обязательны; precision по умолчанию 2,
// show_in_equivalent — true (их подставляет create_currency, не разбор).
ParseResult parse_create(const nlohmann::json& body);
// PATCH: любое непустое подмножество полей, те же проверки.
ParseResult parse_update(const nlohmann::json& body);

enum class WriteError {
    kOk,
    kNotFound,      // нет своей живой валюты с таким uuid (общая и чужая — тоже сюда)
    kIconNotFound,  // icon_uuid не общая иконка и не иконка этого леджера
    kDuplicate,     // field = "iso_code" | "name"
    kInPair,        // смена iso_code у валюты живой пары
    kInUse,         // удаление валюты живого кошелька или пары
};

struct WriteResult {
    WriteError error = WriteError::kOk;
    std::string field;       // только при kDuplicate
    nlohmann::json currency; // только при kOk (кроме delete)
};

// Строка валюты в той же форме, что элемент GET /api/reports/currencies
// (wallet-report): uuid, name, iso_code, symbol, precision, icon_uuid,
// icon_sha256, show_in_equivalent, is_own. Видимая — своя или общая, живая.
std::optional<nlohmann::json> find_currency(db::Database& db, const std::string& ledger_id,
                                            const std::string& currency_uuid);

WriteResult create_currency(db::Database& db, const std::string& ledger_id, const CurrencyInput& input);
WriteResult update_currency(db::Database& db, const std::string& ledger_id, const std::string& currency_uuid,
                            const CurrencyInput& input);
// kOk / kNotFound / kInUse; currency в результате пуст.
WriteResult delete_currency(db::Database& db, const std::string& ledger_id, const std::string& currency_uuid);

// "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" (любой регистр hex) — до похода в
// базу: иначе Postgres ответит 22P02 на приведении к uuid, то есть 500.
bool is_uuid(const std::string& s);

} // namespace currencies_repo
