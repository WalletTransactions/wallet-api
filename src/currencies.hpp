// Свои валюты с веба (change currency-ui-tweaks, тег currencies в
// openapi.yaml): POST /api/currencies, PATCH/DELETE /api/currencies/:uuid —
// HTTP-слой поверх currencies_repo.hpp, по образцу currency_pairs.hpp:
// сессионная аутентификация без device_id, ledger_id только из леджера
// пользователя. POST при необходимости заводит личный леджер
// (provisioning::ensure_personal_ledger), PATCH/DELETE без леджера — 404.
// Чтение справочника — в wallet-report (GET /api/reports/currencies).
#pragma once

#include "app_state.hpp"
#include "httplib.h"

namespace currencies_api {

void register_routes(httplib::Server& svr, AppState& state);

} // namespace currencies_api
