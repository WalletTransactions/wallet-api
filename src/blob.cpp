#include "blob.hpp"

#include "nlohmann/json.hpp"
#include "session.hpp"
#include "util/crypto.hpp"
#include "util/hex.hpp"
#include "util/log.hpp"

using nlohmann::json;

namespace blobapi {

namespace {

constexpr const char* kJsonContentType = "application/json";
// См. wallet-api/schema/table/blob.sql: CHECK (octet_length(bytes) BETWEEN 1 AND 1048576).
constexpr std::size_t kMinBlobSize = 1;
constexpr std::size_t kMaxBlobSize = 1024 * 1024;

void json_error(httplib::Response& res, int status, const std::string& message) {
    res.status = status;
    res.set_content(json{{"error", message}}.dump(), kJsonContentType);
}

// POST /sync/blobs — тело запроса КАК ЕСТЬ (сырые байты, любой Content-Type
// не разбирается) — сервер сам считает SHA-256, не доверяя тому, что мог бы
// прислать клиент (иначе "загрузка чужого содержимого под чужим хешем" была
// бы тривиальной атакой на дедупликацию). ON CONFLICT DO NOTHING —
// идемпотентно: повторная заливка того же содержимого просто ничего не
// меняет, тот же sha256 возвращается снова.
void handle_upload(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("POST /sync/blobs"); // литерал из register_routes ниже
    auto user = session::current_user(req, *state.jwks);
    if (!user) {
        json_error(res, 401, "unauthenticated");
        return;
    }

    if (req.body.size() < kMinBlobSize || req.body.size() > kMaxBlobSize) {
        json_error(res, 400,
                   "тело запроса должно быть от 1 байта до 1 МиБ (см. "
                   "wallet-api/schema/table/blob.sql)");
        return;
    }

    auto digest = crypto::sha256(req.body);
    std::string sha256_hex =
        hex::encode(std::string(reinterpret_cast<const char*>(digest.data()), digest.size()));
    std::string body_hex = hex::encode(req.body);

    state.db_pool->acquire()->exec(
        "INSERT INTO blob (sha256, bytes) VALUES (decode($1,'hex'), decode($2,'hex')) "
        "ON CONFLICT (sha256) DO NOTHING",
        {sha256_hex, body_hex});

    res.set_content(json{{"sha256", sha256_hex}}.dump(), kJsonContentType);
}

// GET /sync/blobs/:sha256 — отдаёт сырые байты как есть. Право прочитать
// КОНКРЕТНЫЙ blob сознательно не проверяется по видимости иконки в леджере
// вызывающего (см. wallet-api/schema/table/blob.sql, "Строки намеренно ничьи") —
// только факт аутентификации; contentSha256 — не секрет и не персональные
// данные, полноценная ACL-проверка "видна ли эта иконка МОЕМУ леджеру" — не
// сделана в этом заходе (см. org/docs/TODO_mobile_sync.md, "Открытые вопросы").
void handle_download(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("GET /sync/blobs/:sha256"); // литерал из register_routes ниже
    auto user = session::current_user(req, *state.jwks);
    if (!user) {
        json_error(res, 401, "unauthenticated");
        return;
    }

    auto it = req.path_params.find("sha256");
    std::string sha256_hex = it != req.path_params.end() ? it->second : std::string();
    if (!hex::looks_like_sha256(sha256_hex)) {
        json_error(res, 400, "sha256 должен быть 64 hex-символами");
        return;
    }

    auto result = state.db_pool->acquire()->exec(
        "SELECT encode(bytes,'hex') FROM blob WHERE sha256 = decode($1,'hex')", {sha256_hex});
    if (result.rows.empty()) {
        json_error(res, 404, "blob не найден");
        return;
    }

    res.set_content(hex::decode(result.rows[0].fields.at(0)), "application/octet-stream");
}

} // namespace

void register_routes(httplib::Server& svr, AppState& state) {
    svr.Post("/sync/blobs", [&state](const httplib::Request& req, httplib::Response& res) {
        handle_upload(state, req, res);
    });
    svr.Get("/sync/blobs/:sha256", [&state](const httplib::Request& req, httplib::Response& res) {
        handle_download(state, req, res);
    });
}

} // namespace blobapi
