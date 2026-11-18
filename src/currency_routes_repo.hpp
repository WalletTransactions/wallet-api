// Логика маршрутов пересчёта валют (change currency-conversion-routes): веб
// заводит маршрут ПУТЁМ ИЗ ВАЛЮТ («BTC, EUR, RUB»), сервер сам подбирает для
// каждой соседней пары валют видимую пару и направление и пишет шаги в
// currency_conversion (миграция 000043). Отделена от HTTP-слоя
// (currency_routes.hpp/.cpp) тем же приёмом, что currency_pairs_repo — без
// httplib, проверяется интеграционным тестом напрямую.
//
// Маршрут принадлежит леджеру (общих маршрутов нет): ручки видят и меняют только
// маршруты леджера вызывающего, чужие неотличимы от несуществующих. Курс по
// маршруту считает вьюха v_currency_conversion_rate, не этот код.
//
// seq/change_stream — тот же протокол, что у currency_pairs_repo: создание и
// удаление — одна транзакция с ОДНИМ next_seq() на все шаги маршрута, поэтому
// телефон получает маршрут целиком одной группой обычным /sync/pull. updated_by
// не проставляется (у веб-сессии нет device_id). Роль участника не проверяется —
// как у /sync/push и у currency_pairs_repo.
#pragma once

#include <string>
#include <vector>

#include "db.hpp"
#include "nlohmann/json.hpp"

namespace currency_routes_repo {

// Живые СТРУКТУРНО валидные маршруты леджера (цепочка шагов без разрывов, пары
// и валюты живы и видны леджеру). Недостроенные и оборванные маршруты в список
// не попадают — их нельзя ни показать, ни дочинить из веба. Форма элемента:
//   {"from": {uuid, iso_code}, "to": {uuid, iso_code},
//    "path": [{uuid, iso_code}, ...],
//    "steps": [{"num", "currency_pair_uuid", "symbol", "is_reverse"}, ...]}
// Порядок — по ISO-кодам from/to.
nlohmann::json list_routes(db::Database& db, const std::string& ledger_id);

enum class CreateRouteError {
    kOk,
    kBadLength,         // валют не 3–4
    kDuplicateCurrency, // валюта в пути дважды
    kCurrencyNotFound,  // нет такой валюты или она не видна леджеру (detail — uuid)
    kNoPairForStep,     // нет видимой живой пары для соседних валют (detail — «EUR→RUB»)
    kAlreadyExists,     // живой маршрут между теми же from/to (в любом порядке)
};

struct CreateRouteResult {
    CreateRouteError error = CreateRouteError::kOk;
    std::string detail;   // уточнение к ошибке; пусто при kOk
    nlohmann::json route; // форма элемента list_routes; заполнено только при kOk
};

// currency_uuids — путь из 3–4 попарно различных валют, видимых леджеру (своя или
// общая, не удалённая). Для соседних валют (a, b) берётся пара с базовой валютой
// a (шаг прямой), иначе пара с базовой валютой b (шаг is_reverse); при нескольких
// подходящих своя пара предпочтительнее общей. Все шаги и from/to пишутся одной
// транзакцией с одним next_seq(). Гонка двух одинаковых POST заканчивается
// db::QueryError 23505 на uq_currency_conversion_* — HTTP-слой отвечает 409.
CreateRouteResult create_route(db::Database& db, const std::string& ledger_id,
                               const std::vector<std::string>& currency_uuids);

// true — все живые шаги СВОЕГО маршрута (from, to) мягко удалены одной группой.
// false — такого маршрута у леджера нет. Курсы и пары шагов не меняются.
bool delete_route(db::Database& db, const std::string& ledger_id, const std::string& from_uuid,
                  const std::string& to_uuid);

} // namespace currency_routes_repo
