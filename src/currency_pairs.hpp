// "Курсы валют" (по прямому запросу пользователя — веб-аналог Android-экранов
// CurrencyPairListActivity/CurrencyPairRateListActivity/RateEditDialog) —
// HTTP-слой поверх currency_pairs_repo.hpp. Обычная сессионная аутентификация
// (session::current_user, БЕЗ device_id — см. её комментарий), не
// authenticate_and_provision, как у /sync/* (sync.hpp): это веб-путь, у
// браузерной сессии device_id нет claim'а вовсе (тот же довод, что у
// invites.hpp/reports.hpp). `ledger_id` НИКОГДА не приходит от клиента (тот
// же принцип, что и везде в этом сервисе) — резолвится из леджера текущего
// пользователя, при необходимости заводя его (см. provisioning::
// ensure_personal_ledger).
#pragma once

#include "app_state.hpp"
#include "httplib.h"

namespace currency_pairs_api {

void register_routes(httplib::Server& svr, AppState& state);

} // namespace currency_pairs_api
