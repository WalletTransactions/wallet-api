// Флаг приёма своих иконок леджера (change optional-icon-upload,
// LEDGER_ICON_UPLOAD, AppState::ledger_icon_upload). Здесь только чистые
// решения — без HTTP и базы, чтобы их проверяли юнит-тесты; применяют их
// blob.cpp (POST /sync/blobs), sync.cpp (push/pull) и sync_repo.cpp (ответ push).
#pragma once

#include <string>
#include <vector>

#include "nlohmann/json.hpp"

namespace icon_upload {

// Один код для 403 blob и для icons_rejected в ответе push: клиент отключает
// отправку по коду, а не по тексту.
inline constexpr const char* kDisabledError = "icon_upload_disabled";

// Значение переменной окружения: on/true/1 включают, остальное — выкл.
inline bool parse_flag(const std::string& value) { return value == "on" || value == "true" || value == "1"; }

// Админ грузит содержимое общих иконок тем же POST /sync/blobs (веб,
// createReferenceIcon), поэтому флаг его не ограничивает.
inline bool allowed(bool flag, const std::string& global_role) { return flag || global_role == "admin"; }

// Убирает строки `icon` из батча push и возвращает их uuid (строка без uuid
// тоже убирается, в список не попадает). Без таблицы `icon` батч не меняется.
inline std::vector<std::string> take_icon_rows(nlohmann::json& changes) {
    std::vector<std::string> uuids;
    if (!changes.is_object() || !changes.contains("icon")) return uuids;
    const auto& rows = changes.at("icon");
    if (rows.is_array()) {
        for (const auto& row : rows) {
            if (row.is_object() && row.contains("uuid") && row.at("uuid").is_string()) {
                uuids.push_back(row.at("uuid").get<std::string>());
            }
        }
    }
    changes.erase("icon");
    return uuids;
}

} // namespace icon_upload
