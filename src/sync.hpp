// POST /sync/push и GET /sync/pull (org/docs/TODO_mobile_sync.md, Фаза 2) —
// синхронизация локальной SQLite Android-клиента с этим сервисом. Только
// мобильный вход даёт токен с claim'ом device_id (см. README google-auth,
// "Мобильный вход") — без него сюда обращаться нет смысла, см.
// authenticate_and_provision в sync.cpp.
#pragma once

#include "app_state.hpp"
#include "httplib.h"

namespace syncapi {

void register_routes(httplib::Server& svr, AppState& state);

} // namespace syncapi
