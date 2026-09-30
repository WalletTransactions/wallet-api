// Логика "Курсы валют" (по прямому запросу пользователя — веб-аналог
// Android-экранов CurrencyPairListActivity/CurrencyPairRateListActivity/
// RateEditDialog: просмотр валютных пар и их истории курса, добавление/
// изменение/удаление пары и её курса). Отделена от HTTP-слоя
// (currency_pairs.hpp/.cpp) тем же приёмом, что sync_repo/reports_repo/
// invites_repo отделены от своих — без httplib, проверяется интеграционным
// тестом напрямую.
//
// В отличие от Android (чистая локальная SQLite, без разделения "общее/
// своё") — здесь currency_pair/currency_pair_rate имеют ту же область
// видимости Scope::ReferenceOrLedger, что и у синка (см. sync_repo.hpp):
// строка либо общая (ledger_id IS NULL, видна всем), либо личная копия
// этого леджера. Веб всегда СОЗДАЁТ личные строки (см. create_pair ниже) —
// тот же принцип, что и push с мобильного (см. TODO_mobile_sync.md, Фаза 2,
// п. 5, "Реальная находка": клиент физически не может создать общую
// строку). Редактировать/удалять можно только СВОИ строки — общие (заведены
// не этим леджером) в списке видны, но недоступны для мутаций (см. `is_own`
// в JSON-ответах).
//
// Роль участника леджера (owner/member/reader) НЕ проверяется — тот же
// принцип, что и у самого /sync/push (см. sync.cpp/provisioning.cpp: там
// роль вообще не смотрится ни для одной таблицы) — вводить её только здесь
// значило бы рассинхронизировать политику с остальными путями записи.
//
// seq/change_stream: каждая мутация — одна транзакция с ОДНИМ next_seq()
// на все её строки (создание пары, правка precision, мягкое удаление пары +
// каскад её курсов, апсерт/удаление курса) — тот же протокол версий, что и
// у /sync/push (см. wallet-api/schema/README.md, "Курсор и страницы"): мобильные
// устройства получат эти изменения обычным /sync/pull, для этого протокола
// правки с веба неотличимы от правок с телефона. updated_by (устройство) —
// НЕ проставляется (остаётся NULL): у веб-сессии нет device_id (см.
// session::User, google-auth README "Мобильный вход") — колонка и так
// nullable, только диагностика.
#pragma once

#include <optional>
#include <string>

#include "db.hpp"
#include "nlohmann/json.hpp"

namespace currency_pairs_repo {

// Видимые этому леджеру валютные пары — DISTINCT ON (symbol): своя пара
// перекрывает общую с тем же символом (тот же приоритет, что у
// reports_repo::list_currencies). Каждая строка несёт последний известный
// курс и курс ПЕРЕД ним (latest_rate/prev_rate, obе строкой — "деньги как
// строка", см. wallet-api/schema/README.md) — веб считает % изменения сам, тем
// же приёмом, что Android (CurrencyPairListAdapter) или renderOverviewKpis
// на этом же сайте: сервер не обязан знать формат стрелки/цвета. Пустая
// строка (не null) — курса ещё нет вовсе, тот же принцип, что eq_value у
// отчётов.
nlohmann::json list_pairs(db::Database& db, const std::string& ledger_id);

// Одна пара по uuid, ТОЛЬКО если видна этому леджеру (своя или общая,
// deleted_at IS NULL) — nullopt иначе. Без курсов (используется как
// подтверждение после create/update, список — list_pairs выше).
std::optional<nlohmann::json> find_pair(db::Database& db, const std::string& ledger_id,
                                         const std::string& pair_uuid);

enum class CreatePairError { kOk, kSameCurrency, kBaseNotFound, kQuoteNotFound };

struct CreatePairResult {
    CreatePairError error = CreatePairError::kOk;
    nlohmann::json pair; // заполнено только при kOk
};

// base_uuid/quote_uuid обязаны быть валютами, ВИДИМЫМИ этому леджеру (своя
// или общая) — иначе kBaseNotFound/kQuoteNotFound, не 500 на чужом FK:
// леджер Б не должен даже узнать о существовании приватной валюты леджера
// А через код ошибки. Символ пары ("EURUSD") строится из iso_code обеих
// валют — тот же формат, что WalletDbCRUD.InsertCurrencyPair на клиенте.
// Дубль символа СВОЕЙ пары (уже есть такая) — не отдельный CreatePairError,
// а db::QueryError с sqlstate 23505 (см. .cpp, тот же приём, что у
// push_batch в sync_repo.cpp) — HTTP-слой ловит его сам.
CreatePairResult create_pair(db::Database& db, const std::string& ledger_id,
                              const std::string& base_uuid, const std::string& quote_uuid,
                              int precision);

// nullopt — пары с таким uuid СРЕДИ СВОИХ (ledger_id = ledger_id) нет:
// правка/удаление доступны только своим парам, общие — read-only для веба
// (см. шапку файла). Не отличает "не найдена" от "это общая пара" — тот же
// приём, что set_member_role в invites_repo (0 совпавших строк — 404, не
// отдельная диагностика).
std::optional<nlohmann::json> update_pair_precision(db::Database& db, const std::string& ledger_id,
                                                      const std::string& pair_uuid, int precision);

// true — пара (и все её ещё живые курсы, см. шапку файла) мягко удалены.
// false — своей пары с таким uuid нет (не найдена или это общая пара).
bool delete_pair(db::Database& db, const std::string& ledger_id, const std::string& pair_uuid);

enum class RateWriteError { kOk, kPairNotFound };

struct UpsertRateResult {
    RateWriteError error = RateWriteError::kOk;
    nlohmann::json rate; // заполнено только при kOk
};

// date — "YYYY-MM-DD" (проверяется HTTP-слоем перед вызовом, см.
// currency_pairs.cpp), rate — строка десятичного числа > 0 ("Деньги —
// numeric", см. wallet-api/schema/README.md — как и в протоколе синка, без
// разбора в double и обратно). pair_uuid обязан быть видим этому леджеру
// (своя или общая) — иначе kPairNotFound. Апсерт СВОЕЙ строки по
// естественному ключу (ledger_id,
// currency_pair_uuid, date) — тот же арбитр конфликта, что уже действует
// для мобильного push (см. wallet-api/schema/table/currency_pair_rate.sql,
// uq_currency_pair_rate_ledger) — редактирование существующего курса не
// плодит новую строку и не трогает её uuid (тот же принцип, что у
// WalletDbCRUD.InsertOrReplaceRate на клиенте). Своя строка СОСУЩЕСТВУЕТ с
// общим курсом той же пары на ту же дату — обе таблицы это допускают
// намеренно (см. комментарий колонки в схеме).
UpsertRateResult upsert_rate(db::Database& db, const std::string& ledger_id,
                              const std::string& pair_uuid, const std::string& date,
                              const std::string& rate);

// Видимые этому леджеру курсы пары (своя строка перекрывает общую на ту же
// дату — тот же приоритет, что list_pairs), по убыванию даты; from/to —
// включительно, пустая строка — без этой границы. nullopt — пары с таким
// uuid, видимой этому леджеру, нет (тот же смысл, что у upsert_rate выше).
std::optional<nlohmann::json> list_rates(db::Database& db, const std::string& ledger_id,
                                          const std::string& pair_uuid, const std::string& from,
                                          const std::string& to);

// true — СВОЯ (не общая) строка курса на эту дату мягко удалена. false —
// её нет: либо курса на эту дату у этого леджера вообще нет, либо есть
// только ОБЩИЙ (не своей строки нечего удалять — сам общий курс этим путём
// недоступен, см. шапку файла).
bool delete_rate(db::Database& db, const std::string& ledger_id, const std::string& pair_uuid,
                  const std::string& date);

} // namespace currency_pairs_repo
