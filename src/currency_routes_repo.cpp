#include "currency_routes_repo.hpp"

#include <algorithm>
#include <map>
#include <set>

#include "util/uuid.hpp"

using nlohmann::json;

namespace currency_routes_repo {

namespace {

struct Step {
    int num = 0;
    std::string pair_uuid;
    std::string symbol;
    bool is_reverse = false;
    std::string step_from; // начало шага — выводится из пары и is_reverse
    std::string step_to;
};

// Валюты, видимые леджеру (своя или общая, не удалённая): uuid -> iso_code.
std::map<std::string, std::string> visible_currencies(db::Database& db, const std::string& ledger_id) {
    auto res = db.exec("SELECT uuid, iso_code FROM currency "
                       "WHERE deleted_at IS NULL AND (ledger_id IS NULL OR ledger_id = $1)",
                       {ledger_id});
    std::map<std::string, std::string> out;
    for (const auto& row : res.rows) out[row.fields.at(0)] = row.fields.at(1);
    return out;
}

json currency_json(const std::map<std::string, std::string>& iso, const std::string& uuid) {
    return json{{"uuid", uuid}, {"iso_code", iso.at(uuid)}};
}

json step_json(const Step& s) {
    return json{{"num", s.num}, {"currency_pair_uuid", s.pair_uuid}, {"symbol", s.symbol},
                {"is_reverse", s.is_reverse}};
}

json route_json(const std::map<std::string, std::string>& iso, const std::vector<std::string>& path,
                const std::vector<Step>& steps) {
    json path_json = json::array();
    for (const auto& uuid : path) path_json.push_back(currency_json(iso, uuid));
    json steps_json = json::array();
    for (const auto& s : steps) steps_json.push_back(step_json(s));
    return json{{"from", currency_json(iso, path.front())},
                {"to", currency_json(iso, path.back())},
                {"path", std::move(path_json)},
                {"steps", std::move(steps_json)}};
}

// Структурная проверка цепочки (то же правило, что chains во вьюхе курса):
// номера подряд с 1, шаг 1 начинается в from, каждый следующий — где закончился
// предыдущий, последний заканчивается в to, все валюты пути живы и видны.
bool chain_is_valid(const std::map<std::string, std::string>& iso, const std::string& from,
                    const std::string& to, const std::vector<Step>& steps) {
    if (steps.empty() || iso.count(from) == 0) return false;
    std::string at = from;
    for (std::size_t i = 0; i < steps.size(); ++i) {
        const Step& s = steps[i];
        if (s.num != static_cast<int>(i) + 1) return false;
        if (s.step_from != at || iso.count(s.step_to) == 0) return false;
        at = s.step_to;
    }
    return at == to;
}

struct RawRoute {
    std::string from;
    std::string to;
    std::vector<Step> steps;
};

// Все живые шаги леджера с живой видимой парой, сгруппированные в маршруты
// (from, to) и упорядоченные по num. Валидность здесь не проверяется.
std::vector<RawRoute> load_routes(db::Database& db, const std::string& ledger_id) {
    auto res = db.exec(
        "SELECT s.from_currency_uuid, s.to_currency_uuid, s.num, s.currency_pair_uuid, s.is_reverse, "
        "       cp.base_currency_uuid, cp.quote_currency_uuid, cp.symbol "
        "FROM currency_conversion s "
        "JOIN currency_pair cp ON cp.uuid = s.currency_pair_uuid AND cp.deleted_at IS NULL "
        "                     AND (cp.ledger_id IS NULL OR cp.ledger_id = $1) "
        "WHERE s.ledger_id = $1 AND s.deleted_at IS NULL "
        "ORDER BY s.from_currency_uuid, s.to_currency_uuid, s.num",
        {ledger_id});
    std::vector<RawRoute> routes;
    for (const auto& row : res.rows) {
        const std::string& from = row.fields.at(0);
        const std::string& to = row.fields.at(1);
        if (routes.empty() || routes.back().from != from || routes.back().to != to) {
            routes.push_back({from, to, {}});
        }
        Step s;
        s.num = std::stoi(row.fields.at(2));
        s.pair_uuid = row.fields.at(3);
        s.is_reverse = row.fields.at(4) == "t";
        const std::string& base = row.fields.at(5);
        const std::string& quote = row.fields.at(6);
        s.symbol = row.fields.at(7);
        s.step_from = s.is_reverse ? quote : base;
        s.step_to = s.is_reverse ? base : quote;
        routes.back().steps.push_back(std::move(s));
    }
    return routes;
}

// Видимая живая пара с base -> quote; своя предпочтительнее общей.
bool find_pair(db::Database& db, const std::string& ledger_id, const std::string& base,
               const std::string& quote, std::string& pair_uuid, std::string& symbol) {
    auto res = db.exec("SELECT uuid, symbol FROM currency_pair "
                       "WHERE deleted_at IS NULL AND (ledger_id IS NULL OR ledger_id = $1) "
                       "AND base_currency_uuid = $2 AND quote_currency_uuid = $3 "
                       "ORDER BY (ledger_id IS NULL) LIMIT 1",
                       {ledger_id, base, quote});
    if (res.rows.empty()) return false;
    pair_uuid = res.rows[0].fields.at(0);
    symbol = res.rows[0].fields.at(1);
    return true;
}

} // namespace

json list_routes(db::Database& db, const std::string& ledger_id) {
    auto iso = visible_currencies(db, ledger_id);
    struct Item {
        std::string key;
        json route;
    };
    std::vector<Item> items;
    for (const auto& raw : load_routes(db, ledger_id)) {
        if (!chain_is_valid(iso, raw.from, raw.to, raw.steps)) continue;
        std::vector<std::string> path = {raw.from};
        for (const auto& s : raw.steps) path.push_back(s.step_to);
        items.push_back({iso.at(raw.from) + "\x1f" + iso.at(raw.to) + "\x1f" + raw.from + raw.to,
                         route_json(iso, path, raw.steps)});
    }
    std::sort(items.begin(), items.end(), [](const Item& a, const Item& b) { return a.key < b.key; });
    json out = json::array();
    for (auto& item : items) out.push_back(std::move(item.route));
    return out;
}

CreateRouteResult create_route(db::Database& db, const std::string& ledger_id,
                               const std::vector<std::string>& currency_uuids) {
    CreateRouteResult result;
    if (currency_uuids.size() < 3 || currency_uuids.size() > 4) {
        result.error = CreateRouteError::kBadLength;
        return result;
    }
    std::set<std::string> distinct(currency_uuids.begin(), currency_uuids.end());
    if (distinct.size() != currency_uuids.size()) {
        result.error = CreateRouteError::kDuplicateCurrency;
        return result;
    }

    // Чужая приватная валюта неотличима от несуществующей: леджер не должен
    // узнать о ней по коду ошибки (тот же довод, что у create_pair).
    auto iso = visible_currencies(db, ledger_id);
    for (const auto& uuid : currency_uuids) {
        if (iso.count(uuid) == 0) {
            result.error = CreateRouteError::kCurrencyNotFound;
            result.detail = uuid;
            return result;
        }
    }

    std::vector<Step> steps;
    for (std::size_t i = 0; i + 1 < currency_uuids.size(); ++i) {
        const std::string& a = currency_uuids[i];
        const std::string& b = currency_uuids[i + 1];
        Step s;
        s.num = static_cast<int>(i) + 1;
        s.step_from = a;
        s.step_to = b;
        if (find_pair(db, ledger_id, a, b, s.pair_uuid, s.symbol)) {
            s.is_reverse = false;
        } else if (find_pair(db, ledger_id, b, a, s.pair_uuid, s.symbol)) {
            s.is_reverse = true;
        } else {
            result.error = CreateRouteError::kNoPairForStep;
            result.detail = iso.at(a) + "→" + iso.at(b);
            return result;
        }
        steps.push_back(std::move(s));
    }

    const std::string& from = currency_uuids.front();
    const std::string& to = currency_uuids.back();

    // Живой маршрут между теми же валютами (в любом порядке) — конфликт. Но
    // оборванный (его пару или валюту удалили на телефоне, шаги остались) в
    // списке не виден и из веба не удаляется — такой замещаем: гасим его шаги
    // той же группой, иначе пользователь упёрся бы в 409 без выхода. Гасим по
    // ключу (from, to), а не по найденным маршрутам: шаг без живой пары
    // load_routes не видит (JOIN), но индекс уникальности он всё равно занимает.
    for (const auto& raw : load_routes(db, ledger_id)) {
        bool same_pair = (raw.from == from && raw.to == to) || (raw.from == to && raw.to == from);
        if (same_pair && chain_is_valid(iso, raw.from, raw.to, raw.steps)) {
            result.error = CreateRouteError::kAlreadyExists;
            return result;
        }
    }

    auto tx = db.begin_transaction();
    std::string seq = tx.exec("SELECT next_seq($1)", {ledger_id}).rows.at(0).fields.at(0);
    tx.exec("UPDATE currency_conversion SET deleted_at = now(), seq = $1 "
            "WHERE ledger_id = $2 AND deleted_at IS NULL "
            "AND ((from_currency_uuid = $3 AND to_currency_uuid = $4) "
            "  OR (from_currency_uuid = $4 AND to_currency_uuid = $3))",
            {seq, ledger_id, from, to});
    for (const auto& s : steps) {
        tx.exec("INSERT INTO currency_conversion "
                "(uuid, ledger_id, seq, from_currency_uuid, to_currency_uuid, num, currency_pair_uuid, is_reverse) "
                "VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
                {uuidgen::v4(), ledger_id, seq, from, to, std::to_string(s.num), s.pair_uuid,
                 s.is_reverse ? "t" : "f"});
    }
    tx.commit();

    result.route = route_json(iso, currency_uuids, steps);
    return result;
}

bool delete_route(db::Database& db, const std::string& ledger_id, const std::string& from_uuid,
                  const std::string& to_uuid) {
    auto tx = db.begin_transaction();
    std::string seq = tx.exec("SELECT next_seq($1)", {ledger_id}).rows.at(0).fields.at(0);
    auto res = tx.exec("UPDATE currency_conversion SET deleted_at = now(), seq = $1 "
                       "WHERE ledger_id = $2 AND from_currency_uuid = $3 AND to_currency_uuid = $4 "
                       "AND deleted_at IS NULL RETURNING uuid",
                       {seq, ledger_id, from_uuid, to_uuid});
    if (res.rows.empty()) return false; // транзакция откатывается деструктором
    tx.commit();
    return true;
}

} // namespace currency_routes_repo
