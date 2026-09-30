// Доступ и приглашения в леджер (org/docs/TODO_mobile_sync.md, Фаза 6, п. 9.3)
// — HTTP-слой поверх invites_repo.hpp. `ledger_id` НИКОГДА не приходит от
// клиента (тот же принцип, что у /sync/push — см. openapi.yaml, "ledger_id
// клиент никогда не присылает"): резолвится из леджера ТЕКУЩЕГО
// аутентифицированного пользователя, поэтому в путях нет `{ledger_id}` —
// только `/api/ledger/...` (MVP — один леджер на пользователя, п. 1.3).
#pragma once

#include "app_state.hpp"
#include "httplib.h"

namespace invitesapi {

void register_routes(httplib::Server& svr, AppState& state);

} // namespace invitesapi
