#include "reference_icons_repo.hpp"

#include <cctype>

#include "util/hex.hpp"
#include "util/uuid.hpp"

using nlohmann::json;

namespace reference_icons_repo {

namespace {

std::string trim(const std::string& s) {
    const char* ws = " \t\r\n\f\v";
    auto begin = s.find_first_not_of(ws);
    if (begin == std::string::npos) return {};
    auto end = s.find_last_not_of(ws);
    return s.substr(begin, end - begin + 1);
}

// Кодовые точки UTF-8: не считаем байты продолжения 10xxxxxx. Корректность
// UTF-8 уже проверил json::parse.
std::size_t utf8_length(const std::string& s) {
    std::size_t n = 0;
    for (unsigned char c : s) {
        if ((c & 0xC0) != 0x80) ++n;
    }
    return n;
}

std::string ascii_lower(std::string s) {
    for (char& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

ParseResult fail(ParseResult r, const std::string& field, const std::string& message) {
    r.field = field;
    r.error = field + ": " + message;
    return r;
}

ParseResult parse_fields(const json& body, bool create) {
    ParseResult r;
    if (!body.is_object()) {
        r.error = "тело запроса должно быть JSON-объектом";
        return r;
    }
    IconInput& in = r.input;

    if (auto it = body.find("name"); it != body.end()) {
        if (!it->is_string()) return fail(r, "name", "ожидается строка");
        std::string v = trim(it->get<std::string>());
        if (v.empty()) return fail(r, "name", "не может быть пустым");
        if (utf8_length(v) > kMaxNameLength) {
            return fail(r, "name", "не длиннее " + std::to_string(kMaxNameLength) + " символов");
        }
        in.name = std::move(v);
    }

    if (auto it = body.find("icon_type"); it != body.end()) {
        // 1.5 и "0" — не целое число; беззнаковое сверх int64 — тоже мимо.
        const std::string message = "ожидается целое число от 0 до " + std::to_string(kMaxIconType);
        if (!it->is_number_integer()) return fail(r, "icon_type", message);
        if (it->is_number_unsigned()) {
            auto v = it->get<std::uint64_t>();
            if (v > static_cast<std::uint64_t>(kMaxIconType)) return fail(r, "icon_type", message);
            in.icon_type = static_cast<int>(v);
        } else {
            auto v = it->get<std::int64_t>();
            if (v < 0 || v > kMaxIconType) return fail(r, "icon_type", message);
            in.icon_type = static_cast<int>(v);
        }
    }

    if (auto it = body.find("content_sha256"); it != body.end()) {
        if (!create) {
            return fail(r, "content_sha256", "картинка общей иконки не меняется — создайте новую иконку");
        }
        if (!it->is_string() || !hex::looks_like_sha256(it->get<std::string>())) {
            return fail(r, "content_sha256", "ожидается SHA-256, 64 hex-символа");
        }
        in.content_sha256 = ascii_lower(it->get<std::string>());
    }

    if (create) {
        if (!in.name) return fail(r, "name", "обязательное поле");
        if (!in.icon_type) return fail(r, "icon_type", "обязательное поле");
        if (!in.content_sha256) return fail(r, "content_sha256", "обязательное поле");
    } else if (!in.name && !in.icon_type) {
        r.error = "нет полей для изменения (name, icon_type)";
        return r;
    }
    return r;
}

std::string next_reference_seq(db::Database::Transaction& tx) {
    return tx.exec("SELECT next_seq($1)", {kReferenceStreamId}).rows.at(0).fields.at(0);
}

// Живая общая иконка под FOR UPDATE: блокирует и параллельную правку, и
// вставку account/currency со ссылкой на неё (проверка FK берёт FOR KEY
// SHARE на эту строку) — подсчёт ссылок в delete_icon не устаревает до commit.
bool lock_live_reference_icon(db::Database::Transaction& tx, const std::string& uuid, db::Row* out = nullptr) {
    auto res = tx.exec(
        "SELECT name, icon_type FROM icon WHERE uuid = $1 AND ledger_id IS NULL AND deleted_at IS NULL FOR UPDATE",
        {uuid});
    if (res.rows.empty()) return false;
    if (out) *out = res.rows[0];
    return true;
}

json icon_row_to_json(const db::Row& row) {
    return json{{"uuid", row.fields.at(0)},
                {"name", row.fields.at(1)},
                {"icon_type", std::stoi(row.fields.at(2))},
                {"content_sha256", row.fields.at(3)}};
}

constexpr const char* kReturning = " RETURNING uuid, name, icon_type, encode(content_sha256, 'hex')";

bool is_duplicate_name(const db::QueryError& e) {
    return e.sqlstate == "23505" && e.constraint_name == "uq_icon_name_reference";
}

} // namespace

ParseResult parse_create(const json& body) { return parse_fields(body, true); }
ParseResult parse_update(const json& body) { return parse_fields(body, false); }

std::optional<json> find_icon(db::Database& db, const std::string& uuid) {
    auto res = db.exec(
        "SELECT uuid, name, icon_type, encode(content_sha256, 'hex') FROM icon "
        "WHERE uuid = $1 AND ledger_id IS NULL AND deleted_at IS NULL",
        {uuid});
    if (res.rows.empty()) return std::nullopt;
    return icon_row_to_json(res.rows[0]);
}

WriteResult create_icon(db::Database& db, const IconInput& input) {
    const std::string uuid = uuidgen::v4();
    try {
        auto tx = db.begin_transaction();
        // Явная проверка вместо FK icon_content_sha256_fkey: тот дал бы ту же
        // гарантию, но 23503 с невнятным для веба текстом (design D1).
        auto blob = tx.exec("SELECT 1 FROM blob WHERE sha256 = decode($1, 'hex')", {input.content_sha256.value()});
        if (blob.rows.empty()) return {WriteError::kBlobMissing, {}, 0};

        std::string seq = next_reference_seq(tx);
        auto res = tx.exec(std::string("INSERT INTO icon (uuid, ledger_id, seq, updated_by, name, content_sha256, "
                                       "icon_type) VALUES ($1, NULL, $2, NULL, $3, decode($4, 'hex'), $5)") +
                               kReturning,
                           {uuid, seq, input.name.value(), input.content_sha256.value(),
                            std::to_string(input.icon_type.value())});
        tx.commit();
        return {WriteError::kOk, icon_row_to_json(res.rows.at(0)), 0};
    } catch (const db::QueryError& e) {
        if (!is_duplicate_name(e)) throw;
        return {WriteError::kDuplicate, {}, 0};
    }
}

WriteResult update_icon(db::Database& db, const std::string& uuid, const IconInput& input) {
    try {
        auto tx = db.begin_transaction();
        db::Row current;
        if (!lock_live_reference_icon(tx, uuid, &current)) return {WriteError::kNotFound, {}, 0};

        std::string name = input.name.value_or(current.fields.at(0));
        std::string icon_type = input.icon_type ? std::to_string(*input.icon_type) : current.fields.at(1);
        std::string seq = next_reference_seq(tx);
        auto res = tx.exec(std::string("UPDATE icon SET name = $2, icon_type = $3, seq = $4, updated_by = NULL "
                                       "WHERE uuid = $1 AND ledger_id IS NULL") +
                               kReturning,
                           {uuid, name, icon_type, seq});
        tx.commit();
        return {WriteError::kOk, icon_row_to_json(res.rows.at(0)), 0};
    } catch (const db::QueryError& e) {
        if (!is_duplicate_name(e)) throw;
        return {WriteError::kDuplicate, {}, 0};
    }
}

WriteResult delete_icon(db::Database& db, const std::string& uuid) {
    auto tx = db.begin_transaction();
    if (!lock_live_reference_icon(tx, uuid)) return {WriteError::kNotFound, {}, 0};

    // Ссылки во всех леджерах (design D4): tombstone используемой иконки
    // заставил бы новое устройство пропустить ссылающиеся счета при pull.
    auto refs = tx.exec(
        "SELECT (SELECT count(*) FROM account  WHERE icon_uuid = $1 AND deleted_at IS NULL) + "
        "       (SELECT count(*) FROM currency WHERE icon_uuid = $1 AND deleted_at IS NULL)",
        {uuid});
    int64_t in_use = std::stoll(refs.rows.at(0).fields.at(0));
    if (in_use > 0) return {WriteError::kInUse, {}, in_use};

    std::string seq = next_reference_seq(tx);
    tx.exec("UPDATE icon SET deleted_at = now(), seq = $2, updated_by = NULL WHERE uuid = $1 AND ledger_id IS NULL",
            {uuid, seq});
    tx.commit();
    return {WriteError::kOk, {}, 0};
}

} // namespace reference_icons_repo
