// POST/GET /sync/blobs(/:sha256) (org/docs/TODO_mobile_sync.md, "Иконки") —
// контент-адресуемое хранилище двоичного содержимого (сейчас только
// изображения иконок, см. wallet-api/schema/table/blob.sql). Префикс "/sync/" —
// НЕ потому что это часть протокола push/pull (это отдельные, независимые
// от батчей эндпоинты), а потому что wallet-gateway уже маршрутизирует
// "/sync/*" на wallet-api с JWT-гейтом (см. его main.cpp, find_route) —
// заводить здесь новый префикс означало бы ещё и править таблицу
// маршрутизации гейтвея.
//
// Обычная сессионная аутентификация (session::current_user), БЕЗ
// authenticate_and_provision из sync.cpp — blob "ничей" (нет ledger_id,
// см. wallet-api/schema/table/blob.sql, "Строки намеренно ничьи"), устройство
// синка ему не нужно, поэтому браузерный вход тут тоже годится, не только
// мобильный.
#pragma once

#include "app_state.hpp"
#include "httplib.h"

namespace blobapi {

void register_routes(httplib::Server& svr, AppState& state);

} // namespace blobapi
