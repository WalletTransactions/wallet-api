#include "currencies_repo.hpp"

#include <cctype>
#include <regex>

#include "util/uuid.hpp"

using nlohmann::json;

namespace currencies_repo {

namespace {

std::string trim(const std::string& s) {
    const char* ws = " \t\r\n\f\v";
    auto begin = s.find_first_not_of(ws);
    if (begin == std::string::npos) return {};
    auto end = s.find_last_not_of(ws);
    return s.substr(begin, end - begin + 1);
}

// ISO-коды и коды крипты — ASCII; байты UTF-8 вне ASCII не трогаем.
std::string ascii_upper(std::string s) {
    for (char& c : s) {
        unsigned char u = static_cast<unsigned char>(c);
        if (u < 0x80) c = static_cast<char>(std::toupper(u));
    }
    return s;
}

ParseResult fail(ParseResult r, const std::string& field, const std::string& message) {
    r.field = field;
    r.error = field + ": " + message;
    return r;
}

// Строковое поле: нет ключа — nullopt; есть — обязано быть строкой; края
// обрезаются; пустое значение допустимо только при allow_empty.
// Возвращает текст ошибки или пустую строку.
std::string read_string(const json& body, const char* key, bool allow_empty, std::optional<std::string>& out) {
    auto it = body.find(key);
    if (it == body.end()) return {};
    if (!it->is_string()) return "ожидается строка";
    std::string v = trim(it->get<std::string>());
    if (v.empty() && !allow_empty) return "не может быть пустым";
    out = std::move(v);
    return {};
}

ParseResult parse_fields(const json& body, bool create) {
    ParseResult r;
    if (!body.is_object()) {
        r.error = "тело запроса должно быть JSON-объектом";
        return r;
    }
    CurrencyInput& in = r.input;
    if (auto e = read_string(body, "name", false, in.name); !e.empty()) return fail(r, "name", e);
    if (auto e = read_string(body, "iso_code", false, in.iso_code); !e.empty()) return fail(r, "iso_code", e);
    if (in.iso_code) in.iso_code = ascii_upper(*in.iso_code);
    if (auto e = read_string(body, "symbol", true, in.symbol); !e.empty()) return fail(r, "symbol", e);
    if (auto e = read_string(body, "icon_uuid", false, in.icon_uuid); !e.empty()) return fail(r, "icon_uuid", e);
    if (in.icon_uuid && !is_uuid(*in.icon_uuid)) return fail(r, "icon_uuid", "ожидается uuid");

    if (auto it = body.find("precision"); it != body.end()) {
        // is_number_integer: 2.5 и "2" — не целое число (CHECK 0..8 таблицы).
        if (!it->is_number_integer()) return fail(r, "precision", "ожидается целое число от 0 до 8");
        long long p = it->get<long long>();
        if (p < 0 || p > 8) return fail(r, "precision", "ожидается целое число от 0 до 8");
        in.precision = static_cast<int>(p);
    }
    if (auto it = body.find("show_in_equivalent"); it != body.end()) {
        if (!it->is_boolean()) return fail(r, "show_in_equivalent", "ожидается boolean");
        in.show_in_equivalent = it->get<bool>();
    }

    if (create) {
        if (!in.name) return fail(r, "name", "обязательное поле");
        if (!in.iso_code) return fail(r, "iso_code", "обязательное поле");
        if (!in.icon_uuid) return fail(r, "icon_uuid", "обязательное поле");
    } else if (!in.name && !in.iso_code && !in.symbol && !in.precision && !in.icon_uuid &&
               !in.show_in_equivalent) {
        r.error = "нет полей для изменения";
        return r;
    }
    return r;
}

bool icon_visible(db::Database::Transaction& tx, const std::string& ledger_id, const std::string& icon_uuid) {
    auto res = tx.exec(
        "SELECT 1 FROM icon WHERE uuid = $1 AND deleted_at IS NULL "
        "AND (ledger_id IS NULL OR ledger_id = $2)",
        {icon_uuid, ledger_id});
    return !res.rows.empty();
}

// Дубль кода или названия среди всех видимых живых валют, кроме self —
// своих и общих (design D5). Пусто — дубля нет, иначе имя поля.
std::string find_duplicate(db::Database::Transaction& tx, const std::string& ledger_id,
                           const std::string& self_uuid, const std::string& iso_code, const std::string& name) {
    auto res = tx.exec(
        "SELECT "
        "  EXISTS (SELECT 1 FROM currency WHERE deleted_at IS NULL AND uuid <> $2 "
        "          AND (ledger_id IS NULL OR ledger_id = $1) AND upper(iso_code) = $3), "
        "  EXISTS (SELECT 1 FROM currency WHERE deleted_at IS NULL AND uuid <> $2 "
        "          AND (ledger_id IS NULL OR ledger_id = $1) AND name = $4)",
        {ledger_id, self_uuid, iso_code, name});
    if (res.rows.at(0).fields.at(0) == "t") return "iso_code";
    if (res.rows.at(0).fields.at(1) == "t") return "name";
    return {};
}

bool in_live_pair(db::Database::Transaction& tx, const std::string& currency_uuid) {
    auto res = tx.exec(
        "SELECT 1 FROM currency_pair WHERE deleted_at IS NULL "
        "AND (base_currency_uuid = $1 OR quote_currency_uuid = $1) LIMIT 1",
        {currency_uuid});
    return !res.rows.empty();
}

bool in_live_wallet(db::Database::Transaction& tx, const std::string& currency_uuid) {
    auto res = tx.exec(
        "SELECT 1 FROM account_operating ao "
        "JOIN account a ON a.ledger_id = ao.ledger_id AND a.uuid = ao.uuid AND a.deleted_at IS NULL "
        "WHERE ao.currency_uuid = $1 AND ao.deleted_at IS NULL LIMIT 1",
        {currency_uuid});
    return !res.rows.empty();
}

std::string next_seq(db::Database::Transaction& tx, const std::string& ledger_id) {
    return tx.exec("SELECT next_seq($1)", {ledger_id}).rows.at(0).fields.at(0);
}

// Гонка двух записей мимо find_duplicate — индексы своей области видимости.
std::string duplicate_field_of(const db::QueryError& e) {
    if (e.sqlstate != "23505") return {};
    if (e.constraint_name == "uq_currency_iso_ledger") return "iso_code";
    if (e.constraint_name == "uq_currency_name_ledger") return "name";
    return {};
}

} // namespace

bool is_uuid(const std::string& s) {
    static const std::regex kUuid(
        "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$");
    return std::regex_match(s, kUuid);
}

ParseResult parse_create(const json& body) { return parse_fields(body, true); }
ParseResult parse_update(const json& body) { return parse_fields(body, false); }

std::optional<json> find_currency(db::Database& db, const std::string& ledger_id, const std::string& currency_uuid) {
    auto res = db.exec(
        "SELECT c.uuid, c.name, c.iso_code, c.symbol, c.\"precision\", c.icon_uuid, "
        "encode(i.content_sha256, 'hex'), c.show_in_equivalent, COALESCE(c.ledger_id = $2, false) "
        "FROM currency c JOIN icon i ON i.uuid = c.icon_uuid "
        "WHERE c.uuid = $1 AND c.deleted_at IS NULL AND (c.ledger_id IS NULL OR c.ledger_id = $2)",
        {currency_uuid, ledger_id});
    if (res.rows.empty()) return std::nullopt;
    const auto& f = res.rows[0].fields;
    return json{{"uuid", f.at(0)},
                {"name", f.at(1)},
                {"iso_code", f.at(2)},
                {"symbol", f.at(3)},
                {"precision", std::stoi(f.at(4))},
                {"icon_uuid", f.at(5)},
                {"icon_sha256", f.at(6)},
                {"show_in_equivalent", f.at(7) == "t"},
                {"is_own", f.at(8) == "t"}};
}

WriteResult create_currency(db::Database& db, const std::string& ledger_id, const CurrencyInput& input) {
    const std::string uuid = uuidgen::v4();
    const std::string& iso = input.iso_code.value();
    const std::string& name = input.name.value();
    std::string symbol = input.symbol.value_or("");
    if (symbol.empty()) symbol = iso;
    int precision = input.precision.value_or(2);
    bool show = input.show_in_equivalent.value_or(true);

    // tx в своей области видимости: find_currency ниже сам берёт соединение
    // (см. currency_pairs_repo::create_pair, самозаклин mutex_).
    try {
        auto tx = db.begin_transaction();
        if (!icon_visible(tx, ledger_id, input.icon_uuid.value())) return {WriteError::kIconNotFound, {}, {}};
        if (auto field = find_duplicate(tx, ledger_id, uuid, iso, name); !field.empty()) {
            return {WriteError::kDuplicate, field, {}};
        }
        std::string seq = next_seq(tx, ledger_id);
        tx.exec(
            "INSERT INTO currency (uuid, ledger_id, seq, name, iso_code, icon_uuid, symbol, \"precision\", "
            "show_in_equivalent) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
            {uuid, ledger_id, seq, name, iso, input.icon_uuid.value(), symbol, std::to_string(precision),
             show ? "t" : "f"});
        tx.commit();
    } catch (const db::QueryError& e) {
        auto field = duplicate_field_of(e);
        if (field.empty()) throw;
        return {WriteError::kDuplicate, field, {}};
    }
    return {WriteError::kOk, {}, *find_currency(db, ledger_id, uuid)};
}

WriteResult update_currency(db::Database& db, const std::string& ledger_id, const std::string& currency_uuid,
                            const CurrencyInput& input) {
    try {
        auto tx = db.begin_transaction();
        // Только своя живая: общая и чужая — тот же 404, что «не найдена».
        auto cur = tx.exec(
            "SELECT name, iso_code, symbol, \"precision\", icon_uuid, show_in_equivalent FROM currency "
            "WHERE uuid = $1 AND ledger_id = $2 AND deleted_at IS NULL FOR UPDATE",
            {currency_uuid, ledger_id});
        if (cur.rows.empty()) return {WriteError::kNotFound, {}, {}};
        const auto& f = cur.rows[0].fields;

        std::string name = input.name.value_or(f.at(0));
        std::string iso = input.iso_code.value_or(f.at(1));
        std::string symbol = input.symbol ? *input.symbol : f.at(2);
        if (symbol.empty()) symbol = iso;
        std::string precision = input.precision ? std::to_string(*input.precision) : f.at(3);
        std::string icon_uuid = input.icon_uuid.value_or(f.at(4));
        bool show = input.show_in_equivalent.value_or(f.at(5) == "t");

        // Символ пары — склейка кодов её валют (design D6).
        if (iso != f.at(1) && in_live_pair(tx, currency_uuid)) return {WriteError::kInPair, {}, {}};
        if (input.icon_uuid && !icon_visible(tx, ledger_id, icon_uuid)) return {WriteError::kIconNotFound, {}, {}};
        if (auto field = find_duplicate(tx, ledger_id, currency_uuid, iso, name); !field.empty()) {
            return {WriteError::kDuplicate, field, {}};
        }
        std::string seq = next_seq(tx, ledger_id);
        tx.exec(
            "UPDATE currency SET name = $3, iso_code = $4, symbol = $5, \"precision\" = $6, icon_uuid = $7, "
            "show_in_equivalent = $8, seq = $9, updated_by = NULL WHERE uuid = $1 AND ledger_id = $2",
            {currency_uuid, ledger_id, name, iso, symbol, precision, icon_uuid, show ? "t" : "f", seq});
        tx.commit();
    } catch (const db::QueryError& e) {
        auto field = duplicate_field_of(e);
        if (field.empty()) throw;
        return {WriteError::kDuplicate, field, {}};
    }
    return {WriteError::kOk, {}, *find_currency(db, ledger_id, currency_uuid)};
}

WriteResult delete_currency(db::Database& db, const std::string& ledger_id, const std::string& currency_uuid) {
    auto tx = db.begin_transaction();
    auto cur = tx.exec(
        "SELECT 1 FROM currency WHERE uuid = $1 AND ledger_id = $2 AND deleted_at IS NULL FOR UPDATE",
        {currency_uuid, ledger_id});
    if (cur.rows.empty()) return {WriteError::kNotFound, {}, {}};
    if (in_live_wallet(tx, currency_uuid) || in_live_pair(tx, currency_uuid)) return {WriteError::kInUse, {}, {}};
    std::string seq = next_seq(tx, ledger_id);
    tx.exec("UPDATE currency SET deleted_at = now(), seq = $3, updated_by = NULL WHERE uuid = $1 AND ledger_id = $2",
            {currency_uuid, ledger_id, seq});
    tx.commit();
    return {WriteError::kOk, {}, {}};
}

} // namespace currencies_repo
