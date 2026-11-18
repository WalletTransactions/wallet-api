// Маршруты пересчёта валют (change currency-conversion-routes, тег
// `currency-routes` в openapi.yaml) — HTTP-слой поверх currency_routes_repo.hpp.
// Обычная сессионная аутентификация (session::current_user, БЕЗ device_id), как у
// currency_pairs.hpp: это веб-путь. ledger_id никогда не приходит от клиента —
// резолвится из леджера текущего пользователя; создание маршрута при
// необходимости заводит леджер, список — нет (пустой список вместо 404).
#pragma once

#include "app_state.hpp"
#include "httplib.h"

namespace currency_routes_api {

void register_routes(httplib::Server& svr, AppState& state);

} // namespace currency_routes_api
