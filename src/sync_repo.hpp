// Протокол синка (org/docs/TODO_mobile_sync.md, Фаза 2, п. 5) — push/pull по
// всем синхронизируемым таблицам домена (wallet-api/schema/table/), выведенным
// через ОДНО табличное описание (TableSpec), а не десятью написанными вручную
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
#include <optional>
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
    // Подмножество columns, которое строка push вправе НЕ нести (change
    // currency-ui-tweaks, сегодня только currency.show_in_equivalent). Нет
    // ключа — колонки нет ни в INSERT (работает DEFAULT таблицы), ни в
    // DO UPDATE SET, ни в UPDATE по uuid (прежнее значение остаётся): «нет
    // ключа» значит «клиент о колонке не знает». Ключ есть — значение обязано
    // быть JSON-boolean (все необязательные колонки сегодня boolean), иначе
    // invalid_row с именем поля. Обязательные колонки (account.kind и т. п.)
    // сюда не входят: у них нет безопасного значения по умолчанию, см.
    // README, «Необязательные колонки push».
    std::vector<std::string> optional_columns;
};

// Строка push не годится (сейчас — необязательная колонка не того типа).
// push_batch отвечает на неё тем же 400 invalid_row, что и на json::exception.
struct InvalidRow {
    std::string detail;
};

// SQL одной строки push — чистая функция ради юнит-тестов (tests/
// test_sync_repo.cpp), исполняет её upsert_row в sync_repo.cpp.
// insert_sql — `INSERT … ON CONFLICT <target>` без DO-части (её дописывает
// upsert_row по режиму), update_set — тело `DO UPDATE SET`,
// update_by_uuid_set — тело `UPDATE <table> SET` для пути по uuid (только у
// таблиц с conflict_columns). params — $1…$n для всех трёх текстов.
// Бросает json::exception (нет обязательного поля) и InvalidRow.
struct UpsertSql {
    std::string insert_sql;
    std::string update_set;
    std::string update_by_uuid_set;
    std::vector<std::string> params;
};

UpsertSql build_upsert(const TableSpec& spec, const std::string& ledger_id, const std::string& device_id,
                       int64_t seq, const nlohmann::json& row);

// Все таблицы, которые клиент может ОТПРАВИТЬ — включая icon (метаданные;
// само содержимое — отдельные /sync/blobs, см. шапку файла).
const std::vector<TableSpec>& push_tables();

// Все таблицы, которые клиент может ПОЛУЧИТЬ. Сегодня буквально совпадает с
// push_tables() — раньше (до добавления push для icon) отличалось на одну
// таблицу, отдельная функция осталась ради явного смыслового различия
// push/pull в остальном коде (sync.cpp, тесты), а не потому что множества
// сейчас разные.
const std::vector<TableSpec>& pull_tables();

// Порядок ПРИМЕНЕНИЯ push-батча: таблица идёт после всех, на которые
// ссылается (см. kApplyOrder в sync_repo.cpp). Наружу — ради юнит-теста
// порядка; совпадает с TABLE_ORDER Android SyncEngine.
const std::vector<std::string>& apply_order();

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
    // Курсор клиента оказался ДАЛЬШЕ головы потока (change_stream.seq) —
    // такого seq сервер никогда не выдавал: курсор остался от другого
    // леджера/пересозданной базы. Страница тогда отдана с нуля, клиенту
    // нужно заменить курсор на next_seq как обычно (применение — upsert по
    // uuid, повтор безопасен). Без этого pull молча возвращал бы пустоту
    // навсегда — реальный случай 2026-09-30: курсор 146 при голове 13.
    //
    // Второй повод сброса (change purge-synced-tombstones) — курсор отстал
    // от чистки: 0 < cursor < change_stream.purged_seq, часть удалений,
    // которых клиент ещё не видел, физически вычищена. Причина — в
    // reset_reason.
    bool reset = false;
    // "ahead" | "purged" при reset, пусто без сброса (в ответ поле тогда не
    // попадает, см. sync.cpp).
    std::string reset_reason;
    // purged_seq потока на момент чтения — в ответ не идёт; sync.cpp пишет его
    // в device.*_load_base_seq, когда устройство начинает поток с нуля.
    int64_t purged_seq = 0;
};

// Причина сброса курсора — чистая функция ради юнит-тестов. head — голова
// потока, purged_seq — до какого seq он вычищен. Курсор 0 — не отставание:
// клиент и так читает с нуля. Впереди головы — "ahead" (проверяется первым:
// такой курсор вообще не от этого потока).
//
// load_base — purged_seq потока, когда устройство последний раз начинало его
// с нуля (device.*_load_base_seq). Пока purged_seq не вырос дальше load_base,
// курсор ниже purged_seq — граница страницы загрузки с нуля, а не отставание:
// без этого загрузка, которой нужно больше одной страницы, после первой же
// чистки зацикливалась (13 < 77 -> "purged" -> снова 0 -> снова 13).
enum class ResetReason { None, Ahead, Purged };
ResetReason reset_reason_for(int64_t cursor, int64_t head, int64_t purged_seq,
                             std::optional<int64_t> load_base = std::nullopt);
const char* reset_reason_name(ResetReason reason); // "" | "ahead" | "purged"

// Курсор — bigint клиента, лимит — сколько строк добирать (страница может
// оказаться БОЛЬШЕ limit — см. README wallet-api/schema, "Курсор и страницы":
// группа с одинаковым seq никогда не разрезается). Сброс курсора — см.
// PullResult::reset.
// load_base — см. reset_reason_for.
PullResult pull_ledger_stream(db::Database& db, const std::string& ledger_id, int64_t cursor, int limit,
                              std::optional<int64_t> load_base = std::nullopt);
PullResult pull_reference_stream(db::Database& db, int64_t cursor, int limit,
                                 std::optional<int64_t> load_base = std::nullopt);

// --- Срок хранения tombstone (change purge-synced-tombstones) ---------------

// Константный id потока справочников — см. schema/table/change_stream.sql.
extern const char* const kReferenceStreamId;

// Подтверждение устройства: курсоры запроса pull — всё до них устройство
// применило и сохранило (Android сохраняет курсор только после применения
// страницы). Пишется как есть, в том числе меньше прежнего. ledger_cursor =
// nullopt — подтверждение леджера не трогается (ledger_id запроса не совпал
// с текущим леджером, см. sync.cpp).
//
// *_load_base — purged_seq потока, если устройство в этом запросе начало его с
// нуля (курсор 0 или сброс): пишется в device.*_load_base_seq; nullopt — не
// трогается.
void record_ack(db::Database& db, const std::string& device_id, std::optional<int64_t> ledger_cursor,
                int64_t reference_cursor, std::optional<int64_t> ledger_load_base = std::nullopt,
                std::optional<int64_t> reference_load_base = std::nullopt);

// device.ledger_load_base_seq / reference_load_base_seq (NULL -> nullopt).
struct LoadBases {
    std::optional<int64_t> ledger;
    std::optional<int64_t> reference;
};
LoadBases device_load_bases(db::Database& db, const std::string& device_id);

// Горизонт чистки потока: минимум подтверждений устройств, у которых
// подтверждение есть и last_seen_at не старше device_ttl_days. Поток
// леджера — устройства этого леджера (stream_id = ledger_id), поток
// справочников (kReferenceStreamId) — все устройства. Нет таких устройств —
// голова потока. Никогда не больше головы.
int64_t stream_horizon(db::Database& db, const std::string& stream_id, int device_ttl_days);

// Ссылка одной таблицы синка на другую: child.child_columns ->
// parent.parent_columns. Только ссылки МЕЖДУ таблицами синка (ledger/device/
// blob сюда не входят — их строки чистка не удаляет). Тип ссылки (CASCADE
// или NO ACTION) неважен: tombstone, на который ссылается хоть одна строка
// (живая или удалённая), не удаляется вовсе.
struct TableRef {
    std::string child;
    std::vector<std::string> child_columns;
    std::string parent;
    std::vector<std::string> parent_columns;
};
const std::vector<TableRef>& sync_table_refs();

// Порядок удаления — от листьев к корням: таблица идёт раньше всех, на
// которые ссылается, так что в одной транзакции удалённый лист освобождает
// свой удалённый корень. Совпадает по составу с pull_tables() (юнит-тест).
const std::vector<std::string>& purge_order();

// Тексты DELETE для чистки одного потока, по purge_order() — чистая функция
// ради юнит-тестов. Параметры: поток леджера — $1 ledger_id, $2 горизонт;
// поток справочников — $1 горизонт (только строки ledger_id IS NULL, только
// таблицы Scope::ReferenceOrLedger).
struct PurgeStatement {
    std::string table;
    std::string sql;
};
std::vector<PurgeStatement> build_purge_statements(bool ledger_stream);

struct PurgeStats {
    int64_t horizon = 0;
    int64_t purged_seq = 0;      // change_stream.purged_seq после чистки
    int64_t deleted_rows = 0;    // всего по всем таблицам
};

// Удаляет tombstone потока с seq <= horizon, на которые никто не ссылается,
// и поднимает purged_seq до max(purged_seq, horizon) — одной транзакцией.
// Без троттлинга — его делает maybe_purge_stream.
PurgeStats purge_stream(db::Database& db, const std::string& stream_id, int64_t horizon);

// Чистка после pull: атомарно занимает слот (purged_at старше часа или
// NULL), считает горизонт и чистит. nullopt — слот занят (чистка была
// меньше часа назад или идёт параллельно). Ошибки — исключением, вызывающий
// пишет их в лог и ответ pull не меняет.
std::optional<PurgeStats> maybe_purge_stream(db::Database& db, const std::string& stream_id,
                                             int device_ttl_days);

} // namespace sync_repo
