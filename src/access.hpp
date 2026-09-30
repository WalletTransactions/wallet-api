// Проверка iss/aud/scope access-токена до хендлеров
// (org/docs/TODO_telegram_tokens.md, шаг 2). Вызывается из pre-routing
// (main.cpp) и отвечает сама, только если токен С ВЕРНОЙ ПОДПИСЬЮ адресован
// не этому сервису (401) или не даёт нужного scope (403). Во всех остальных
// случаях (токена нет, подпись битая, всё в порядке) — пропускает дальше:
// 401 за отсутствующий/битый токен по-прежнему отвечает сам хендлер через
// session::current_user, как и раньше.
#pragma once

#include <string>

#include "httplib.h"
#include "util/jwks.hpp"

// authz, а не access: access() — POSIX-функция из <unistd.h>, имя занято.
namespace authz {

inline constexpr const char* kAudience = "wallet-api";

// Какой scope нужен запросу. Пустая строка — эндпоинт без токена
// (/healthz, /docs, ...) или не наш путь: проверять нечего.
std::string required_scope(const std::string& method, const std::string& path);

// Второй допустимый scope вместо required_scope, пусто — нет. Сейчас только
// POST /sync/push: expense:write токена Telegram-бота — узкое право «только
// новая операция», его границы проверяет сам хендлер (sync.cpp,
// PushMode::CreateOperationsOnly).
std::string alternative_scope(const std::string& method, const std::string& path);

httplib::Server::HandlerResponse gate(const httplib::Request& req, httplib::Response& res, jwks::Cache& jwks_cache);

} // namespace authz
