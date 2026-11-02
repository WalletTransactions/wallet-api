// Общий набор иконок (icon.ledger_id IS NULL) — запись администратором с
// веба (change server-managed-icons, spec reference-icons-admin). Логика
// отдельно от HTTP-слоя (reference_icons.cpp), тот же приём, что у
// currencies_repo: разбор тела — чистые функции (юнит-тест
// tests/test_reference_icons.cpp), записи — интеграционный тест
// tests_integration/test_reference_icons.cpp.
//
// Создание двухшаговое (design D1): байты картинки уже загружены через
// POST /sync/blobs, сюда приходит только их content_sha256. Картинку у
// существующей иконки не меняем (телефон не перекачивает байты известной
// иконки) — для новой картинки заводится новая иконка.
//
// Каждое изменение — одна транзакция с одним next_seq() потока справочников
// (00000000-0000-0000-0000-000000000001), updated_by = NULL (устройства у
// веб-сессии нет): телефоны получают его обычным GET /sync/pull, раздел
// reference. Роль admin здесь не проверяется — это дело HTTP-слоя.
#pragma once

#include <cstdint>
#include <optional>
#include <string>

#include "db.hpp"
#include "nlohmann/json.hpp"

namespace reference_icons_repo {

// Константный id потока справочников — см. schema/table/change_stream.sql.
inline constexpr const char* kReferenceStreamId = "00000000-0000-0000-0000-000000000001";

// Пределы имени (design D6): после обрезки краёв 1..64 символа (кодовых
// точек UTF-8, не байт).
inline constexpr std::size_t kMaxNameLength = 64;
// icon.icon_type — smallint с CHECK (icon_type >= 0): верхняя граница —
// предел типа, иначе 500 на приведении вместо понятного 400.
inline constexpr int kMaxIconType = 32767;

// Разобранное тело POST/PATCH: заданы только присланные поля, name уже
// обрезан, content_sha256 — в нижнем регистре.
struct IconInput {
    std::optional<std::string> name;
    std::optional<int> icon_type;
    std::optional<std::string> content_sha256;
};

// error пусто — тело годится; иначе текст для 400 и имя поля (field, может
// быть пустым — например, тело не объект).
struct ParseResult {
    std::string error;
    std::string field;
    IconInput input;
};

// POST: name, icon_type, content_sha256 обязательны.
ParseResult parse_create(const nlohmann::json& body);
// PATCH: непустое подмножество name/icon_type; content_sha256 — 400
// (картинка этой ручкой не меняется).
ParseResult parse_update(const nlohmann::json& body);

enum class WriteError {
    kOk,
    kNotFound,     // нет живой ОБЩЕЙ иконки с таким uuid (своя иконка леджера — тоже сюда)
    kBlobMissing,  // content_sha256 не загружен через POST /sync/blobs
    kDuplicate,    // живая общая иконка с тем же name уже есть
    kInUse,        // удаление иконки, на которую ссылаются живые account/currency
};

struct WriteResult {
    WriteError error = WriteError::kOk;
    nlohmann::json icon;  // только при kOk у create/update: uuid, name, icon_type, content_sha256
    int64_t in_use = 0;   // только при kInUse: число живых ссылок
};

// Живая общая иконка в форме ответа ручек — nullopt, если её нет.
std::optional<nlohmann::json> find_icon(db::Database& db, const std::string& uuid);

WriteResult create_icon(db::Database& db, const IconInput& input);
WriteResult update_icon(db::Database& db, const std::string& uuid, const IconInput& input);
// kOk / kNotFound / kInUse; icon в результате пуст. blob не удаляется.
WriteResult delete_icon(db::Database& db, const std::string& uuid);

} // namespace reference_icons_repo
