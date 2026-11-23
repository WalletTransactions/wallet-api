// Личные настройки пользователя (change user-eq-currency, spec
// user-settings-api, тег settings в openapi.yaml): GET/PUT /api/settings —
// HTTP-слой поверх user_settings_repo.hpp. Сессионная аутентификация без
// device_id; scope account проверяет authz::gate (access.cpp), роль в
// леджере значения не имеет. Леджер не провизионируется: без него код
// проверяется только по общему справочнику валют.
#pragma once

#include "app_state.hpp"
#include "httplib.h"

namespace user_settings_api {

void register_routes(httplib::Server& svr, AppState& state);

} // namespace user_settings_api
