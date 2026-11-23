// Личные настройки пользователя (change user-eq-currency, spec
// user-settings-api): таблица user_settings, пока одна настройка — валюта
// эквивалента. Логика отдельно от HTTP-слоя (user_settings.cpp), как у
// currencies_repo: разбор тела — чистая функция (юнит-тест
// tests/test_user_settings.cpp), запись и проверка кода — интеграционный
// тест tests_integration/test_user_settings.cpp.
//
// Настройка личная, не данные леджера (design D4): роль участника не
// проверяется, seq/next_seq не трогается — строка в поток синка не входит.
#pragma once

#include <optional>
#include <string>

#include "db.hpp"
#include "nlohmann/json.hpp"

namespace user_settings_repo {

// Разобранное тело PUT /api/settings. error пусто — тело годится;
// eq_currency пусто — сброс (null), иначе код в верхнем регистре, края
// обрезаны.
struct ParseResult {
    std::string error;
    std::optional<std::string> eq_currency;
};

// {"eq_currency": "<код>" | null}: ключ обязателен, строка непустая или null.
ParseResult parse_put(const nlohmann::json& body);

// Сохранённый код; nullopt — нет строки или NULL («не выбрано»).
std::optional<std::string> find_eq_currency(db::Database& db, const std::string& user_id);

enum class WriteError {
    kOk,
    kUnknownCurrency, // кода нет среди живых валют, видимых леджеру
};

// Сохранить код (eq_currency задан) или сбросить (nullopt). Код должен быть
// среди живых валют, видимых леджеру ledger_id: общие (ledger_id IS NULL) и
// свои — как GET /api/reports/currencies в wallet-report. ledger_id пуст —
// у пользователя нет леджера, годятся только общие. При kUnknownCurrency
// ничего не меняется. email — только чтобы завести app_user, если его ещё
// нет (FK user_settings → app_user), тем же upsert, что в provisioning.
WriteError save_eq_currency(db::Database& db, const std::string& user_id, const std::string& email,
                            const std::string& ledger_id, const std::optional<std::string>& eq_currency);

} // namespace user_settings_repo
