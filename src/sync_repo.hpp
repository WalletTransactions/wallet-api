// Протокол синка (org/docs/TODO_mobile_sync.md, Фаза 2, п. 5) — push/pull по
// всем синхронизируемым таблицам домена (wallet-api/schema/table/), выведенным
// через ОДНО табличное описание (TableSpec), а не девятью написанными вручную
// функциями: все эти таблицы устроены одинаково (uuid/ledger_id/seq/
// deleted_at/updated_at/updated_by + бизнес-колонки, см.
// wallet-api/schema/table/README.md, "Общий набор колонок") — разница только в
// именах колонок и в том, бывает ли у таблицы общая (ledger_id IS NULL)
// область видимости.
//
// Push `icon` (org/docs/TODO_mobile_sync.md, "Иконки") реализован здесь как
// обычная синхронизируемая таблица — но сама загрузка/выдача СОДЕРЖИМОГО
// (байт изображения) в этот протокол не входит: это отдельные эндпоинты
// POST/GET /sync/blobs(/:sha256) (см. blob.hpp), контент-адресуемые по
// SHA-256 (wallet-api/schema/table/blob.sql). Порядок для клиента обязателен:
// сначала залить содержимое через /sync/blobs, ПОТОМ прислать строку
// `icon` с полученным `content_sha256` — иначе `icon.content_sha256`
// сошлётся на ещё не существующий blob и упадёт `409 missing_reference`
// (см. push_batch), тем же путём, что и любой другой внешний ключ. Pull `icon` при этом есть — это чтение
// уже существующих строк, от push независимо.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "db.hpp"
#include "nlohmann/json.hpp"

namespace sync_repo {

// ReferenceOrLedger — таблица бывает и общей (ledger_id IS NULL), и своей
// (заполненный ledger_id — то, что пользователь добавил себе сам); при push
// клиент никогда не пишет общую строку — сервер всегда подставляет
// АУТЕНТИФИЦИРОВАННЫЙ ledger_id, что бы ни прислал клиент (см. push_batch).
// LedgerOnly — общих строк не бывает вообще (данные леджера).
enum class Scope { LedgerOnly, ReferenceOrLedger };

struct TableSpec {
    std::string name;
    Scope scope;
    // Бизнес-колонки (без uuid/ledger_id/seq/deleted_at/updated_at/updated_by
    // — эти пять общие для всех и выставляются push_batch сам). Имя JSON-поля
    // в теле запроса совпадает с именем колонки.
    std::vector<std::string> columns;
    // Подмножество columns типа numeric (operation.amount,
    // currency_pair_rate.rate) — при pull ЭТИ поля отдаются JSON-строками, а
    // не числами: `to_jsonb()` сериализует numeric как голое число, и ровно
    // это на клиенте вернуло бы ту же погрешность двоичной дроби, ради
    // которой на сервере вообще завели numeric (см. README wallet-api/schema,
    // "Деньги — numeric"). Пусто у всех остальных таблиц.
    std::vector<std::string> numeric_columns;
    // Подмножество columns типа bytea, закодированное как hex-строка на
    // границе протокола (сейчас — только icon.content_sha256). При push
    // клиент присылает hex, upsert_row оборачивает параметр в
    // decode($n,'hex'); при pull to_jsonb() сериализовал бы bytea как
    // "\x..." — та же jsonb_build_object-патч-техника, что и у
    // numeric_columns, только encode(col,'hex') вместо col::text. Пусто у
    // всех таблиц без bytea-колонок.
    std::vector<std::string> hex_columns;
    // Подмножество columns типа date (сейчас — только
    // currency_pair_rate.date) — при push upsert_row обрезает входящую
    // строку до первых 10 символов ("yyyy-MM-dd") ЯВНО, а не полагается на
    // неявный CAST Postgres text->date (тот молча отбрасывает время сам, но
    // именно поэтому два локальных дубля одной календарной даты с разным
    // временем — разные uuid клиента — коллидируют на uq_currency_pair_rate_*
    // при вставке, см. org/docs/TODO_mobile_sync.md и README, "Синхронизация").
    // Явное обрезание здесь — вторая линия обороны поверх клиентской (см.
    // Android SyncEngine.collectDirty) на случай старых клиентов/данных,
    // где в "date" ещё осталось время. Пусто у всех колонок без date-типа —
    // operation.date НАРОЧНО не входит сюда: это timestamp, время там
    // значащее (см. wallet-api/schema/table/operation.sql).
    std::vector<std::string> date_only_columns;
    // Естественный ключ для ON CONFLICT ВМЕСТО uuid — сегодня только у
    // currency_pair_rate. Клиент не гарантирует uuid уникальным по (пара,
    // дата): локально у этой таблицы PRIMARY KEY (currency_pair_id, date),
    // а uuid — не более чем непрозрачная метка строки (см.
    // android-wallet/schema/table/currency_pair_rate.sql), генерируемая заново
    // КАЖДЫЙ раз, когда клиент не находит существующую локальную строку на
    // эту (пара, дата) — а найти чужую, ещё не долетевшую с другого
    // устройства, локально попросту неоткуда. Поэтому два офлайн-устройства
    // могут независимо прислать РАЗНЫЕ uuid на одну и ту же (ledger, пара,
    // дата): `ON CONFLICT (uuid)` их не поймает — своя строка на этот uuid
    // ещё не существует — и INSERT падает прямо на
    // uq_currency_pair_rate_ledger (23505), не доходя до ON CONFLICT
    // вообще (реальный кейс, POST /sync/push, см. org/docs/TODO_mobile_sync.md,
    // "Открытые вопросы"). Решение: конфликт резолвится по (ledger_id,
    // currency_pair_uuid, date) — тот же естественный ключ, что уже
    // применяет сам клиент (WalletDbCRUD.InsertOrReplaceRate: не трогает
    // uuid, обновляет найденную по (пара, дата) строку) — последний
    // применённый push побеждает, включая uuid. Пусто у всех остальных
    // таблиц — там конфликт по-прежнему резолвится по uuid (см. Scope
    // выше и upsert_row).
    std::vector<std::string> conflict_columns;
    // WHERE-предикат ON CONFLICT, СИНТАКСИЧЕСКИ идентичный предикату
    // частичного уникального индекса-арбитра — Postgres требует точного
    // совпадения текста предиката, иначе частичный индекс не примет роль
    // arbiter (см. wallet-api/schema/table/currency_pair_rate.sql,
    // uq_currency_pair_rate_ledger). Пусто, если conflict_columns не задан
    // либо целевой индекс не частичный.
    std::string conflict_where;
};

// Все таблицы, которые клиент может ОТПРАВИТЬ — включая icon (метаданные;
// само содержимое — отдельные /sync/blobs, см. шапку файла).
const std::vector<TableSpec>& push_tables();

// Все таблицы, которые клиент может ПОЛУЧИТЬ. Сегодня буквально совпадает с
// push_tables() — раньше (до добавления push для icon) отличалось на одну
// таблицу, отдельная функция осталась ради явного смыслового различия
// push/pull в остальном коде (sync.cpp, тесты), а не потому что множества
// сейчас разные.
const std::vector<TableSpec>& pull_tables();

struct Conflict {
    std::string table;
    std::string reason;         // "duplicate_name" — единственная причина с осмысленным existing_uuid
    std::string uuid;           // uuid, который прислал КЛИЕНТ в этой строке — без него клиенту
                                 // нечем понять, какую свою локальную строку переклеивать на existing_uuid
                                 // (несколько строк одной таблицы могут конфликтовать в одном батче)
    std::string existing_uuid;  // uuid выжившей строки; пусто, если неприменимо
};

// Итог push — уже готовые http-код и тело ответа (не отдельные поля,
// которые пришлось бы дальше пересобирать в sync.cpp) — при успехе и при
// повторе того же batch_id это ОДИН И ТОТ ЖЕ текст, взятый из
// sync_push_batch.response, см. push_batch.
struct PushOutcome {
    int http_status = 200;
    std::string response_body;
};

// Одна транзакция на батч (см. TableSpec выше, почему это не 7 отдельных
// функций): все таблицы, что нашлись в `changes`, применяются вместе — если
// упадёт хоть одна строка (кроме дубля имени счёта, для него отдельный,
// осмысленный 409 с uuid выжившей строки), откатывается весь батч целиком.
// Внешний ключ (23503) — тоже отдельный, по возможности осмысленный 409:
// {"error":"missing_reference","table":..,"uuid":..,"detail":..} — table/uuid
// (см. parse_missing_reference в .cpp) называют строку, которой сервер не
// нашёл, так что клиент может сам пометить её dirty и повторить попытку
// следующим циклом, не разбирая текст ошибки Postgres (реальный инцидент
// 2026-09-13 — currency_pair раньше своей currency, см. Android
// SyncEngine.pushDirty). Присутствуют не всегда (составной FK не
// разбирается) — тогда это по-прежнему фатально для клиента.
// Идемпотентность по batch_id — см. sync_push_batch.sql; в кэш кладётся
// только УСПЕШНЫЙ исход — конфликт всегда пересчитывается заново на повтор
// (дёшево и детерминированно, в отличие от успешного применения, которое
// нельзя повторить без двойного расхода seq).
//
// PushMode::CreateOperationsOnly — токен бота со scope expense:write
// (org/docs/TODO_telegram_tokens.md, «Скоупы»): в changes только operation,
// только новые строки. Состав батча проверяет create_only_violation (403 до
// транзакции), а «новая» — сама вставка: ON CONFLICT DO NOTHING RETURNING,
// строка с таким (ledger_id, uuid) уже есть — 403 operation_exists, батч
// откатывается целиком. Атомарно: два параллельных батча с одним uuid не
// перезапишут друг друга. Повтор того же batch_id отвечает сохранённым
// результатом, как и в полном режиме.
enum class PushMode { Full, CreateOperationsOnly };

PushOutcome push_batch(db::Database& db, const std::string& ledger_id, const std::string& device_id,
                        const std::string& batch_id, const nlohmann::json& changes,
                        PushMode mode = PushMode::Full);

// Состав батча для PushMode::CreateOperationsOnly — чистая функция ради
// юнит-тестов. Пустая строка — годится; иначе код ошибки для тела 403:
// "only_operation" (в changes есть что-то кроме operation или operation не
// массив), "delete_not_allowed" (строка с deleted: true).
std::string create_only_violation(const nlohmann::json& changes);

struct PullResult {
    int64_t next_seq;
    nlohmann::json changes; // {"account": [...], "operation": [...], ...}
};

// Курсор — bigint клиента, лимит — сколько строк добирать (страница может
// оказаться БОЛЬШЕ limit — см. README wallet-api/schema, "Курсор и страницы":
// группа с одинаковым seq никогда не разрезается).
PullResult pull_ledger_stream(db::Database& db, const std::string& ledger_id, int64_t cursor, int limit);
PullResult pull_reference_stream(db::Database& db, int64_t cursor, int limit);

} // namespace sync_repo
