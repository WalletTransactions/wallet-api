#include "user_settings_repo.hpp"

#include <cctype>

using nlohmann::json;

namespace user_settings_repo {

namespace {

std::string trim(const std::string& s) {
    const char* ws = " \t\r\n\f\v";
    auto begin = s.find_first_not_of(ws);
    if (begin == std::string::npos) return {};
    auto end = s.find_last_not_of(ws);
    return s.substr(begin, end - begin + 1);
}

// ISO-коды и коды крипты — ASCII; байты UTF-8 вне ASCII не трогаем (как
// currencies_repo).
std::string ascii_upper(std::string s) {
    for (char& c : s) {
        unsigned char u = static_cast<unsigned char>(c);
        if (u < 0x80) c = static_cast<char>(std::toupper(u));
    }
    return s;
}

// Живая валюта с таким кодом видна леджеру: общая или своя. Без леджера —
// отдельный текст запроса без $2, как list_currencies в wallet-report:
// пустая строка не приводится к uuid.
bool currency_visible(db::Database::Transaction& tx, const std::string& ledger_id, const std::string& iso) {
    auto res = ledger_id.empty()
        ? tx.exec("SELECT 1 FROM currency WHERE deleted_at IS NULL AND ledger_id IS NULL "
                  "AND upper(iso_code) = $1 LIMIT 1",
                  {iso})
        : tx.exec("SELECT 1 FROM currency WHERE deleted_at IS NULL "
                  "AND (ledger_id IS NULL OR ledger_id = $2) AND upper(iso_code) = $1 LIMIT 1",
                  {iso, ledger_id});
    return !res.rows.empty();
}

} // namespace

ParseResult parse_put(const json& body) {
    ParseResult r;
    if (!body.is_object()) {
        r.error = "тело запроса должно быть JSON-объектом";
        return r;
    }
    auto it = body.find("eq_currency");
    if (it == body.end()) {
        r.error = "eq_currency: обязательное поле (строка или null)";
        return r;
    }
    if (it->is_null()) return r;
    if (!it->is_string()) {
        r.error = "eq_currency: ожидается строка или null";
        return r;
    }
    std::string code = trim(it->get<std::string>());
    if (code.empty()) {
        r.error = "eq_currency: не может быть пустым (для сброса — null)";
        return r;
    }
    r.eq_currency = ascii_upper(code);
    return r;
}

std::optional<std::string> find_eq_currency(db::Database& db, const std::string& user_id) {
    auto res = db.exec("SELECT eq_currency_iso FROM user_settings WHERE user_id = $1", {user_id});
    // SQL NULL драйвер отдаёт пустой строкой (db::Row) — пустой код не пишется.
    if (res.rows.empty() || res.rows[0].fields.at(0).empty()) return std::nullopt;
    return res.rows[0].fields.at(0);
}

WriteError save_eq_currency(db::Database& db, const std::string& user_id, const std::string& email,
                            const std::string& ledger_id, const std::optional<std::string>& eq_currency) {
    auto tx = db.begin_transaction();
    if (!eq_currency) {
        // Сброс: нет строки и NULL значат одно и то же — app_user не нужен.
        tx.exec("UPDATE user_settings SET eq_currency_iso = NULL WHERE user_id = $1", {user_id});
        tx.commit();
        return WriteError::kOk;
    }
    if (!currency_visible(tx, ledger_id, *eq_currency)) return WriteError::kUnknownCurrency; // ROLLBACK

    // Веб-пользователь без леджера мог ещё не попасть в app_user (провизионирует
    // только первое действие с леджером) — заводим, не трогая существующую строку.
    tx.exec("INSERT INTO app_user (id, email) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING", {user_id, email});
    tx.exec("INSERT INTO user_settings (user_id, eq_currency_iso) VALUES ($1, $2) "
            "ON CONFLICT (user_id) DO UPDATE SET eq_currency_iso = EXCLUDED.eq_currency_iso",
            {user_id, *eq_currency});
    tx.commit();
    return WriteError::kOk;
}

} // namespace user_settings_repo
