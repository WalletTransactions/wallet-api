#include "currency_pairs_repo.hpp"

#include "util/uuid.hpp"

using nlohmann::json;

namespace currency_pairs_repo {

namespace {

// currency, видимая этому леджеру (своя или общая), не удалённая — nullopt,
// если такой uuid не существует ИЛИ существует, но принадлежит ЧУЖОМУ
// леджеру (леджер Б не должен даже отличить эти два случая по коду ошибки
// от несуществующего uuid — см. currency_pairs_repo.hpp, create_pair).
std::optional<std::string> find_visible_currency_iso(db::Database& db, const std::string& ledger_id,
                                                       const std::string& currency_uuid) {
    auto res = db.exec(
        "SELECT iso_code FROM currency "
        "WHERE uuid = $1 AND deleted_at IS NULL AND (ledger_id IS NULL OR ledger_id = $2)",
        {currency_uuid, ledger_id});
    if (res.rows.empty()) return std::nullopt;
    return res.rows[0].fields.at(0);
}

// Одна валюта пары (base/quote) в форме JSON-объекта для list_pairs/find_pair
// ниже — та же тройка полей (uuid/iso_code/name/icon_sha256), что уже
// возвращает reports_repo::list_currencies (веб знает, как её нарисовать).
json currency_to_json(const db::Row& row, std::size_t offset) {
    return json{
        {"uuid", row.fields.at(offset)},
        {"iso_code", row.fields.at(offset + 1)},
        {"name", row.fields.at(offset + 2)},
        {"icon_sha256", row.fields.at(offset + 3)},
    };
}

// Общий SELECT одной или всех видимых леджеру пар — совместный код list_pairs/
// find_pair (единственная разница — WHERE p.uuid = $2 и наличие DISTINCT ON).
// LEFT JOIN LATERAL дважды (latest/prev) — не array_agg: два отдельных
// одностроковых подзапроса читаются проще, чем распаковка индексов массива,
// а цена (лишний скан) не имеет значения на масштабе этого приложения
// (личный/семейный леджер, не биржа).
constexpr const char* kPairSelectColumns =
    "p.uuid, p.symbol, p.\"precision\", (p.ledger_id = $1) AS is_own, "
    "bc.uuid, bc.iso_code, bc.name, encode(bi.content_sha256,'hex'), "
    "qc.uuid, qc.iso_code, qc.name, encode(qi.content_sha256,'hex'), "
    "latest.date::text, latest.rate::text, prev.date::text, prev.rate::text";

constexpr const char* kPairFromJoins =
    "FROM currency_pair p "
    "JOIN currency bc ON bc.uuid = p.base_currency_uuid "
    "JOIN icon bi ON bi.uuid = bc.icon_uuid "
    "JOIN currency qc ON qc.uuid = p.quote_currency_uuid "
    "JOIN icon qi ON qi.uuid = qc.icon_uuid "
    "LEFT JOIN LATERAL ("
    "  SELECT date, rate FROM ("
    "    SELECT DISTINCT ON (date) date, rate FROM currency_pair_rate r"
    "    WHERE r.currency_pair_uuid = p.uuid AND r.deleted_at IS NULL"
    "      AND (r.ledger_id IS NULL OR r.ledger_id = $1)"
    "    ORDER BY date DESC, (r.ledger_id IS NULL) ASC"
    "  ) x ORDER BY date DESC LIMIT 1"
    ") latest ON true "
    "LEFT JOIN LATERAL ("
    "  SELECT date, rate FROM ("
    "    SELECT DISTINCT ON (date) date, rate FROM currency_pair_rate r"
    "    WHERE r.currency_pair_uuid = p.uuid AND r.deleted_at IS NULL"
    "      AND (r.ledger_id IS NULL OR r.ledger_id = $1)"
    "    ORDER BY date DESC, (r.ledger_id IS NULL) ASC"
    "  ) x ORDER BY date DESC OFFSET 1 LIMIT 1"
    ") prev ON true ";

json pair_row_to_json(const db::Row& row) {
    return json{
        {"uuid", row.fields.at(0)},
        {"symbol", row.fields.at(1)},
        {"precision", std::stoi(row.fields.at(2))},
        {"is_own", row.fields.at(3) == "t"},
        {"base_currency", currency_to_json(row, 4)},
        {"quote_currency", currency_to_json(row, 8)},
        {"latest_date", row.fields.at(12)},
        {"latest_rate", row.fields.at(13)},
        {"prev_rate", row.fields.at(15)},
    };
}

} // namespace

nlohmann::json list_pairs(db::Database& db, const std::string& ledger_id) {
    std::string sql = std::string("SELECT DISTINCT ON (p.symbol) ") + kPairSelectColumns + " " +
                       kPairFromJoins +
                       "WHERE p.deleted_at IS NULL AND (p.ledger_id IS NULL OR p.ledger_id = $1) "
                       "ORDER BY p.symbol, (p.ledger_id IS NULL) ASC";
    auto res = db.exec(sql, {ledger_id});
    json out = json::array();
    for (const auto& row : res.rows) out.push_back(pair_row_to_json(row));
    return out;
}

std::optional<nlohmann::json> find_pair(db::Database& db, const std::string& ledger_id,
                                         const std::string& pair_uuid) {
    std::string sql = std::string("SELECT ") + kPairSelectColumns + " " + kPairFromJoins +
                       "WHERE p.uuid = $2 AND p.deleted_at IS NULL "
                       "AND (p.ledger_id IS NULL OR p.ledger_id = $1)";
    auto res = db.exec(sql, {ledger_id, pair_uuid});
    if (res.rows.empty()) return std::nullopt;
    return pair_row_to_json(res.rows[0]);
}

CreatePairResult create_pair(db::Database& db, const std::string& ledger_id,
                              const std::string& base_uuid, const std::string& quote_uuid,
                              int precision) {
    // Проверка ДО похода в транзакцию — тот же порядок, что в остальном
    // коде файла: дешёвые, часто срабатывающие проверки первыми.
    if (base_uuid == quote_uuid) return {CreatePairError::kSameCurrency, {}};

    auto base_iso = find_visible_currency_iso(db, ledger_id, base_uuid);
    if (!base_iso) return {CreatePairError::kBaseNotFound, {}};
    auto quote_iso = find_visible_currency_iso(db, ledger_id, quote_uuid);
    if (!quote_iso) return {CreatePairError::kQuoteNotFound, {}};

    std::string symbol = *base_iso + *quote_iso;
    std::string uuid = uuidgen::v4();

    // tx — в своей области видимости, а не до конца функции: db::Database::
    // Transaction держит mutex_ соединения ВСЁ время своей жизни, не только
    // до commit() (см. db.hpp) — find_pair() ниже сам зовёт db.exec(), и
    // если бы tx была ещё жива на этой строке, второй запрос ждал бы тот же
    // неповторно входимый mutex_, который держит первый же — тот самый
    // самозаклин, что уже был найден и исправлен в push_batch (sync_repo.cpp,
    // 2026-09-04, см. org/docs/TODO_mobile_sync.md, Фаза 2). Здесь он же был
    // реально пойман интеграционным тестом (2026-09-10) — то же лекарство.
    {
        auto tx = db.begin_transaction();
        auto seq_res = tx.exec("SELECT next_seq($1)", {ledger_id});
        std::string seq = seq_res.rows.at(0).fields.at(0);
        // Дубль символа СВОЕЙ пары — 23505 на uq_currency_pair_symbol_ledger,
        // db::QueryError долетает до вызывающего HTTP-слоя как есть (см.
        // currency_pairs.cpp) — не ловим здесь, тот же приём, что push_batch.
        tx.exec(
            "INSERT INTO currency_pair (uuid, ledger_id, seq, symbol, base_currency_uuid, "
            "quote_currency_uuid, \"precision\") VALUES ($1,$2,$3,$4,$5,$6,$7)",
            {uuid, ledger_id, seq, symbol, base_uuid, quote_uuid, std::to_string(precision)});
        tx.commit();
    } // tx разрушена здесь — mutex_ отпущен, find_pair ниже может брать его сам

    CreatePairResult result;
    result.error = CreatePairError::kOk;
    result.pair = *find_pair(db, ledger_id, uuid); // только что создана — гарантированно найдётся
    return result;
}

std::optional<nlohmann::json> update_pair_precision(db::Database& db, const std::string& ledger_id,
                                                      const std::string& pair_uuid, int precision) {
    // Область видимости tx — та же причина, что и в create_pair выше (см.
    // её комментарий): find_pair() после блока сам зовёт db.exec(), tx уже
    // должна быть разрушена к этому моменту, не просто закоммичена.
    {
        auto tx = db.begin_transaction();
        auto seq_res = tx.exec("SELECT next_seq($1)", {ledger_id});
        std::string seq = seq_res.rows.at(0).fields.at(0);
        // RETURNING uuid — тот же приём, что set_member_role в invites_repo.cpp:
        // 0 совпавших строк отличить от "обновили" можно только так, UPDATE
        // сам не сообщает число задетых строк через этот тонкий слой над libpq.
        auto res = tx.exec(
            "UPDATE currency_pair SET \"precision\" = $1, seq = $2 "
            "WHERE uuid = $3 AND ledger_id = $4 AND deleted_at IS NULL RETURNING uuid",
            {std::to_string(precision), seq, pair_uuid, ledger_id});
        if (res.rows.empty()) return std::nullopt; // не своя пара/не найдена — tx просто не коммитится
        tx.commit();
    }
    return find_pair(db, ledger_id, pair_uuid);
}

bool delete_pair(db::Database& db, const std::string& ledger_id, const std::string& pair_uuid) {
    auto tx = db.begin_transaction();
    auto seq_res = tx.exec("SELECT next_seq($1)", {ledger_id});
    std::string seq = seq_res.rows.at(0).fields.at(0);
    auto res = tx.exec(
        "UPDATE currency_pair SET deleted_at = now(), seq = $1 "
        "WHERE uuid = $2 AND ledger_id = $3 AND deleted_at IS NULL RETURNING uuid",
        {seq, pair_uuid, ledger_id});
    if (res.rows.empty()) return false; // не своя пара или не найдена
    // Каскад — ТЕМ ЖЕ seq (см. currency_pairs_repo.hpp, шапка файла, почему
    // один seq на всю группу): курсы, которые могли ссылаться на эту пару,
    // могли быть заведены только этим же леджером (никто другой её не видит
    // и не мог на неё сослаться), поэтому фильтр по ledger_id здесь не
    // нужен — достаточно currency_pair_uuid.
    tx.exec(
        "UPDATE currency_pair_rate SET deleted_at = now(), seq = $1 "
        "WHERE currency_pair_uuid = $2 AND deleted_at IS NULL",
        {seq, pair_uuid});
    tx.commit();
    return true;
}

UpsertRateResult upsert_rate(db::Database& db, const std::string& ledger_id,
                              const std::string& pair_uuid, const std::string& date,
                              const std::string& rate) {
    // Пара обязана быть видима (своя или общая) — свою строку курса на
    // невидимую/несуществующую пару заводить нечему сослаться (23503
    // случился бы и без этой проверки, но 404 честнее, чем "внешний ключ").
    auto visible = db.exec(
        "SELECT 1 FROM currency_pair WHERE uuid = $1 AND deleted_at IS NULL "
        "AND (ledger_id IS NULL OR ledger_id = $2)",
        {pair_uuid, ledger_id});
    if (visible.rows.empty()) return {RateWriteError::kPairNotFound, {}};

    std::string uuid = uuidgen::v4();
    auto tx = db.begin_transaction();
    auto seq_res = tx.exec("SELECT next_seq($1)", {ledger_id});
    std::string seq = seq_res.rows.at(0).fields.at(0);
    // ON CONFLICT (ledger_id, currency_pair_uuid, date) WHERE ledger_id IS
    // NOT NULL AND deleted_at IS NULL — тот же арбитр (uq_currency_pair_rate_
    // ledger), что уже резолвит этот конфликт для мобильного push (см.
    // wallet-api/schema/table/currency_pair_rate.sql и sync_repo.cpp,
    // currency_pair_rate_conflicts_on_natural_key_not_uuid). uuid НЕ входит
    // в SET — правка существующего курса не меняет его идентичность (тот же
    // принцип, что WalletDbCRUD.InsertOrReplaceRate на клиенте). deleted_at
    // = NULL в SET — тот же курс мог быть перед этим мягко удалён и теперь
    // восстанавливается новым значением, а не остаётся невидимым тенью
    // под свежим rate.
    auto res = tx.exec(
        "INSERT INTO currency_pair_rate (uuid, ledger_id, seq, currency_pair_uuid, date, rate) "
        "VALUES ($1,$2,$3,$4,$5,$6) "
        "ON CONFLICT (ledger_id, currency_pair_uuid, date) "
        "WHERE ledger_id IS NOT NULL AND deleted_at IS NULL "
        "DO UPDATE SET rate = EXCLUDED.rate, seq = EXCLUDED.seq, deleted_at = NULL "
        "RETURNING uuid, date::text, rate::text",
        {uuid, ledger_id, seq, pair_uuid, date, rate});
    tx.commit();

    UpsertRateResult result;
    result.error = RateWriteError::kOk;
    const auto& row = res.rows.at(0);
    result.rate = json{{"uuid", row.fields.at(0)},
                        {"date", row.fields.at(1)},
                        {"rate", row.fields.at(2)},
                        {"is_own", true}};
    return result;
}

std::optional<nlohmann::json> list_rates(db::Database& db, const std::string& ledger_id,
                                          const std::string& pair_uuid, const std::string& from,
                                          const std::string& to) {
    auto visible = db.exec(
        "SELECT 1 FROM currency_pair WHERE uuid = $1 AND deleted_at IS NULL "
        "AND (ledger_id IS NULL OR ledger_id = $2)",
        {pair_uuid, ledger_id});
    if (visible.rows.empty()) return std::nullopt;

    // Текст запроса выбирается по наличию границ, не по пустому параметру
    // "date >= ''" — тот же приём, что list_currencies в reports_repo для
    // пустого ledger_id: date typed context не скастует пустую строку.
    std::string sql =
        "SELECT DISTINCT ON (date) uuid, date::text, rate::text, (ledger_id = $2) AS is_own "
        "FROM currency_pair_rate r "
        "WHERE r.currency_pair_uuid = $1 AND r.deleted_at IS NULL "
        "AND (r.ledger_id IS NULL OR r.ledger_id = $2)";
    std::vector<std::string> params = {pair_uuid, ledger_id};
    if (!from.empty()) {
        sql += " AND date >= $" + std::to_string(params.size() + 1);
        params.push_back(from);
    }
    if (!to.empty()) {
        sql += " AND date <= $" + std::to_string(params.size() + 1);
        params.push_back(to);
    }
    sql += " ORDER BY date DESC, (ledger_id IS NULL) ASC";

    auto res = db.exec(sql, params);
    json out = json::array();
    for (const auto& row : res.rows) {
        out.push_back(json{{"uuid", row.fields.at(0)},
                            {"date", row.fields.at(1)},
                            {"rate", row.fields.at(2)},
                            {"is_own", row.fields.at(3) == "t"}});
    }
    return out;
}

bool delete_rate(db::Database& db, const std::string& ledger_id, const std::string& pair_uuid,
                  const std::string& date) {
    auto tx = db.begin_transaction();
    auto seq_res = tx.exec("SELECT next_seq($1)", {ledger_id});
    std::string seq = seq_res.rows.at(0).fields.at(0);
    auto res = tx.exec(
        "UPDATE currency_pair_rate SET deleted_at = now(), seq = $1 "
        "WHERE currency_pair_uuid = $2 AND ledger_id = $3 AND date = $4 AND deleted_at IS NULL "
        "RETURNING uuid",
        {seq, pair_uuid, ledger_id, date});
    if (res.rows.empty()) return false;
    tx.commit();
    return true;
}

} // namespace currency_pairs_repo
