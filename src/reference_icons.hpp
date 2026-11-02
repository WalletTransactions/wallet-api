// Общий набор иконок для администратора (change server-managed-icons, spec
// reference-icons-admin) — HTTP-слой поверх reference_icons_repo.hpp:
// POST /api/admin/icons, PATCH/DELETE /api/admin/icons/:uuid.
//
// Доступ: scope wallet:write проверяет гейт (access.cpp), роль admin из
// claim'а role — здесь (design D3, как handle_admin_icons в wallet-report).
// Обычная сессия (session::current_user): device_id не нужен, леджер и
// устройство не провизионируются — общий набор ничей.
//
// Путь /api/admin/* (не /admin/*: тот у гейтвея уходит на google-auth) —
// гейтвей ведёт его на wallet-api общим правилом /api/*.
#pragma once

#include "app_state.hpp"
#include "httplib.h"

namespace reference_icons_api {

void register_routes(httplib::Server& svr, AppState& state);

} // namespace reference_icons_api
