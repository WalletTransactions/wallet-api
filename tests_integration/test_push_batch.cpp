// Интеграционные тесты sync_repo::push_batch()/pull_ledger_stream() против
// ЖИВОГО Postgres — то, что принципиально нельзя проверить в ../tests/
// (db::Database коннектится в конструкторе, подменить нечем, см.
// ../tests/README.md, "Что сознательно НЕ покрыто здесь"). Требует
// DATABASE_URL с уже накаченной схемой wallet-api — см. README.md рядом.
//
// Главная цель — регрессия на самозаклин 2026-09-04 (см.
// org/docs/TODO_mobile_sync.md, Фаза 2, "Прогнано вживую..."): раньше, после
// tx.commit(), шёл ОТДЕЛЬНЫЙ db.exec() для sync_push_batch, пока tx (уже
// закоммиченная, но ещё не разрушенная — держит mutex_ на всё время своей
// жизни) была ещё жива на этой же строке — db.exec() пытался взять тот же
// неповторно входимый std::mutex заново и ждал сам себя навсегда.
//
// ВСЕ вызовы push_batch() в этом файле идут через push_batch_guarded() (см.
// ниже), не напрямую — при живой проверке выяснилось, что это важно не
// только для теста, названного в честь дедлока: любой из тестов ниже
// зовёт push_batch() тем же кодом, значит, уязвим к тому же классу
// регресса. Без обёртки регресс вешал бы навсегда только НЕ первый тест,
// который его словит (REQUIRE упадёт и остановит именно его), а весь
// процесс целиком, включая все тесты после него — что на практике и
// наблюдалось при обратной проверке (временно вернули баг: без обёртки
// второй тест подряд вешал весь бинарь, а не проваливался).
#include "sync_repo.hpp"

#include <chrono>
#include <future>
#include <limits>
#include <optional>
#include <thread>
#include <type_traits>

#include "fixture.hpp"
#include "nlohmann/json.hpp"
#include "provisioning.hpp"
#include "test_framework.hpp"
#include "util/uuid.hpp"

using nlohmann::json;

namespace {

constexpr auto kDeadlockTimeout = std::chrono::seconds(10);

// Гоняет f() в отдельном потоке; nullopt = не уложились в timeout — именно
// так выглядела бы регрессия дедлока (см. шапку файла) в автоматическом
// тесте: раньше это значило "процесс висит вечно", здесь — упавший CHECK и
// нормальное завершение остального набора тестов. Поток, который не
// уложился, сознательно НЕ join()-ится (после самозаклина это и невозможно
// — см. fixture::open(), почему db держится там через shared_ptr, а не по
// значению) — detach() и предоставлен сам себе; при обычном (не зависшем)
// исходе успевает завершиться и отпустить свою копию promise/аргументов
// задолго до выхода из этой функции.
template <typename F>
auto run_with_timeout(F&& f, std::chrono::seconds timeout)
    -> std::optional<std::invoke_result_t<F>> {
    using Result = std::invoke_result_t<F>;
    auto promise = std::make_shared<std::promise<Result>>();
    std::future<Result> future = promise->get_future();

    std::thread([f = std::forward<F>(f), promise]() mutable {
        try {
            promise->set_value(f());
        } catch (...) {
            promise->set_exception(std::current_exception());
        }
    }).detach();

    if (future.wait_for(timeout) != std::future_status::ready) return std::nullopt;
    return future.get();
}

// db передан по shared_ptr (не ссылкой) — та же причина, что у
// fixture::open(): если f() внутри run_with_timeout зависнет, эта копия
// shared_ptr в захвате потока — единственное, что держит db::Database
// живой после того, как REQUIRE ниже уже прервал текущий TEST.
sync_repo::PushOutcome push_batch_guarded(std::shared_ptr<db::Database> db,
                                           const std::string& ledger_id,
                                           const std::string& device_id,
                                           const std::string& batch_id, const json& changes,
                                           sync_repo::PushMode mode = sync_repo::PushMode::Full) {
    auto outcome = run_with_timeout(
        [db, ledger_id, device_id, batch_id, changes, mode] {
            return sync_repo::push_batch(*db, ledger_id, device_id, batch_id, changes, mode);
        },
        kDeadlockTimeout);
    // Провал здесь = регрессия дедлока 2026-09-04, не "медленный Postgres" —
    // весь push укладывается в одну транзакцию из пары запросов, 10 секунд
    // с огромным запасом.
    REQUIRE(outcome.has_value());
    return *outcome;
}

json make_account_row(const std::string& uuid, const std::string& icon_uuid,
                       const std::string& name) {
    // system_kind/kind — 0 (обычный счёт/категория) везде в этом файле: ни
    // один тест здесь не проверяет ни Transfer/Transfer commission, ни
    // разделение кошелёк/категория — sync_repo требует оба поля в push_batch
    // (TableSpec account), не только конкретные значения.
    return json{{"uuid", uuid},          {"name", name},         {"comment", ""},
                {"icon_uuid", icon_uuid}, {"is_archived", false}, {"system_kind", 0},
                {"kind", 0}};
}

json make_currency_row(const std::string& uuid, const std::string& icon_uuid,
                        const std::string& iso_code) {
    return json{{"uuid", uuid},        {"name", iso_code},      {"iso_code", iso_code},
                {"icon_uuid", icon_uuid}, {"symbol", iso_code}, {"precision", 2}};
}

json make_currency_pair_row(const std::string& uuid, const std::string& base_uuid,
                             const std::string& quote_uuid, const std::string& symbol) {
    return json{{"uuid", uuid},
                {"symbol", symbol},
                {"base_currency_uuid", base_uuid},
                {"quote_currency_uuid", quote_uuid},
                {"precision", 5}};
}

json make_currency_pair_rate_row(const std::string& uuid, const std::string& pair_uuid,
                                  const std::string& date, const std::string& rate) {
    return json{{"uuid", uuid}, {"currency_pair_uuid", pair_uuid}, {"date", date}, {"rate", rate}};
}

} // namespace

TEST(push_batch_returns_promptly_instead_of_deadlocking) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon_uuid = fixture::make_reference_icon(*db);

    json changes = {{"account", json::array({make_account_row(
                                     uuidgen::v4(), icon_uuid, "Deadlock check " + uuidgen::v4())})}};

    auto outcome = push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(),
                                       changes);
    CHECK_EQ(outcome.http_status, 200);
}

// Регрессия на реальный инцидент 2026-09-09 (лог: "unhandled exception: POST
// /sync/push -> [json.exception.out_of_range.403] key 'system_kind' not
// found") — APK, установленный на устройстве, ещё не отправлял колонки
// system_kind/kind, добавленные в TableSpec::columns тем же днём. upsert_row
// читает каждую колонку через row.at(col) без дефолта — раньше отсутствие
// ключа долетало необработанным исключением до глобального
// svr.set_exception_handler (main.cpp), клиент получал непрозрачный 500.
// Теперь push_batch сам ловит json::exception и отвечает внятным
// 400 {"error":"invalid_row"} — эта строка проверяет именно это, не сам факт
// отказа (тот проверялся бы 500 и раньше).
TEST(push_rejects_row_missing_required_column_with_400_not_crash) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon_uuid = fixture::make_reference_icon(*db);

    // Ровно make_account_row() без "system_kind" — воспроизводит именно тот
    // инцидент, не выдуманную нехватку произвольного поля.
    json row = {{"uuid", uuidgen::v4()},   {"name", "Missing column " + uuidgen::v4()},
                {"comment", ""},           {"icon_uuid", icon_uuid},
                {"is_archived", false},    {"kind", 0}};
    json changes = {{"account", json::array({row})}};

    auto outcome = push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(),
                                       changes);

    CHECK_EQ(outcome.http_status, 400);
    json body = json::parse(outcome.response_body);
    CHECK_EQ(body.value("error", std::string{}), std::string("invalid_row"));
    // Транзакция откатилась целиком, не только пропустила плохую строку —
    // тот же принцип "всё или ничего", что и у остальных отказов push_batch.
    auto count = db->exec("SELECT count(*) FROM account WHERE uuid = $1", {row.at("uuid")});
    CHECK_EQ(count.rows.at(0).fields.at(0), std::string("0"));
}

TEST(push_batch_replay_with_same_batch_id_is_idempotent) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon_uuid = fixture::make_reference_icon(*db);

    std::string account_uuid = uuidgen::v4();
    json changes = {{"account", json::array({make_account_row(
                                     account_uuid, icon_uuid, "Idempotent " + account_uuid)})}};
    std::string batch_id = uuidgen::v4();

    auto first = push_batch_guarded(db, identity.ledger_id, identity.device_id, batch_id, changes);
    auto second = push_batch_guarded(db, identity.ledger_id, identity.device_id, batch_id, changes);

    REQUIRE(first.http_status == 200);
    // Тот же ответ, что и в первый раз (взятый из sync_push_batch.response,
    // см. sync_repo.hpp, PushOutcome) — не пересчитанный заново (другой seq
    // означал бы повторное применение). Сравниваем РАЗОБРАННЫЙ JSON, не
    // строку целиком: response — колонка jsonb, Postgres не гарантирует ни
    // порядок ключей, ни пробелы при обратном чтении (см. доки Postgres на
    // jsonb) — второй текст может законно отличаться побайтово от первого,
    // оставаясь тем же значением.
    CHECK_EQ(json::parse(first.response_body), json::parse(second.response_body));

    auto count = db->exec("SELECT count(*) FROM account WHERE uuid = $1", {account_uuid});
    CHECK_EQ(count.rows.at(0).fields.at(0), std::string("1"));
}

TEST(push_batch_rejects_duplicate_account_name_with_existing_uuid) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon_uuid = fixture::make_reference_icon(*db);
    std::string shared_name = "Duplicate " + uuidgen::v4();

    std::string first_uuid = uuidgen::v4();
    json first_changes = {
        {"account", json::array({make_account_row(first_uuid, icon_uuid, shared_name)})}};
    auto first = push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(),
                                     first_changes);
    REQUIRE(first.http_status == 200);

    std::string second_uuid = uuidgen::v4();
    json second_changes = {
        {"account", json::array({make_account_row(second_uuid, icon_uuid, shared_name)})}};
    auto second = push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(),
                                      second_changes);

    CHECK_EQ(second.http_status, 409);
    json body = json::parse(second.response_body);
    REQUIRE(body.contains("conflicts"));
    REQUIRE(body.at("conflicts").size() == static_cast<size_t>(1));
    CHECK_EQ(body.at("conflicts")[0].at("table").get<std::string>(), std::string("account"));
    CHECK_EQ(body.at("conflicts")[0].at("reason").get<std::string>(), std::string("duplicate_name"));
    // uuid — то, что прислал ВТОРОЙ (проигравший) батч; без него клиенту
    // нечем понять, какую свою локальную строку переклеивать на existing_uuid
    // (см. wallet-api/README.md, "Конфликт имени счёта").
    CHECK_EQ(body.at("conflicts")[0].at("uuid").get<std::string>(), second_uuid);
    CHECK_EQ(body.at("conflicts")[0].at("existing_uuid").get<std::string>(), first_uuid);

    // Проваленный батч не должен был применить ничего — второй счёт не
    // существует, а не остался "наполовину применённым" (вся идея одной
    // транзакции на батч, см. push_batch).
    auto count = db->exec("SELECT count(*) FROM account WHERE uuid = $1", {second_uuid});
    CHECK_EQ(count.rows.at(0).fields.at(0), std::string("0"));
}

// Миграция 000024: имя уникально без учёта регистра, «ё» = «е» — «КАФЁ» против живой
// «Кафе» тот же конфликт с existing_uuid, а не голое нарушение индекса.
TEST(push_batch_duplicate_account_name_ignores_case_and_yo) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon_uuid = fixture::make_reference_icon(*db);
    std::string suffix = " " + uuidgen::v4();

    std::string first_uuid = uuidgen::v4();
    json first_changes = {
        {"account", json::array({make_account_row(first_uuid, icon_uuid, "Кафе" + suffix)})}};
    REQUIRE(push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(), first_changes)
                .http_status == 200);

    std::string second_uuid = uuidgen::v4();
    json second_changes = {
        {"account", json::array({make_account_row(second_uuid, icon_uuid, "КАФЁ" + suffix)})}};
    auto second = push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(),
                                      second_changes);

    CHECK_EQ(second.http_status, 409);
    json body = json::parse(second.response_body);
    REQUIRE(body.contains("conflicts"));
    REQUIRE(body.at("conflicts").size() == static_cast<size_t>(1));
    CHECK_EQ(body.at("conflicts")[0].at("reason").get<std::string>(), std::string("duplicate_name"));
    CHECK_EQ(body.at("conflicts")[0].at("existing_uuid").get<std::string>(), first_uuid);
}

TEST(push_then_pull_round_trips_amount_as_string_not_number) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon_uuid = fixture::make_reference_icon(*db);

    std::string acc_fr = uuidgen::v4();
    std::string acc_to = uuidgen::v4();
    std::string op_uuid = uuidgen::v4();
    const std::string kAmount = "500.12345678"; // 8 знаков после запятой — предел numeric(20,8)

    json changes = {
        {"account", json::array({make_account_row(acc_fr, icon_uuid, "From " + acc_fr),
                                  make_account_row(acc_to, icon_uuid, "To " + acc_to)})},
        {"operation", json::array({json{{"uuid", op_uuid},
                                         {"date", "2026-09-04T12:00:00"},
                                         {"acc_fr_uuid", acc_fr},
                                         {"acc_to_uuid", acc_to},
                                         {"amount", kAmount},
                                         {"comment", "integration test"}}})},
    };

    auto push_result = push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(),
                                           changes);
    REQUIRE(push_result.http_status == 200);

    auto pull_result = sync_repo::pull_ledger_stream(*db, identity.ledger_id, /*cursor=*/0,
                                                      /*limit=*/1000);
    REQUIRE(pull_result.changes.contains("operation"));

    bool found = false;
    for (const auto& row : pull_result.changes.at("operation")) {
        if (row.at("uuid").get<std::string>() != op_uuid) continue;
        found = true;
        // Регрессия на to_jsonb()-как-голое-число (см. sync_repo.hpp,
        // TableSpec::numeric_columns) — amount ОБЯЗАН прийти JSON-строкой,
        // иначе клиент столкнётся ровно с той погрешностью двоичной дроби,
        // ради которой на сервере вообще завели numeric.
        REQUIRE(row.at("amount").is_string());
        CHECK_EQ(row.at("amount").get<std::string>(), kAmount);
    }
    CHECK(found);
}

TEST(push_batch_applies_tables_in_dependency_order_not_alphabetical) {
    // Регрессия 2026-09-05 (найдена тестами reports_repo, seed'ящими
    // currency+account+account_operating одним батчем): push_batch раньше
    // применял таблицы changes в порядке ИТЕРАЦИИ nlohmann::json — это
    // std::map, ключи объекта отдаются АЛФАВИТНО, не в порядке вставки
    // клиентом. "account_operating" < "currency" алфавитно ("a" < "c") —
    // без явного порядка применения (см. sync_repo.cpp, kApplyOrder) INSERT
    // в account_operating ушёл бы ДО currency и падал бы на 23503, притом
    // что в самом батче обе строки есть и он логически обязан пройти целиком.
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon_uuid = fixture::make_reference_icon(*db);

    std::string currency_uuid = uuidgen::v4();
    std::string account_uuid = uuidgen::v4();
    json changes = {
        {"currency", json::array({json{{"uuid", currency_uuid},
                                        {"name", "Ordering " + currency_uuid},
                                        {"iso_code", "O" + currency_uuid.substr(0, 2)},
                                        {"icon_uuid", icon_uuid},
                                        {"symbol", "O"},
                                        {"precision", 2}}})},
        {"account",
         json::array({make_account_row(account_uuid, icon_uuid, "Ordering acc " + account_uuid)})},
        {"account_operating",
         json::array({json{{"uuid", account_uuid}, {"currency_uuid", currency_uuid}}})},
    };

    auto result =
        push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(), changes);
    CHECK_EQ(result.http_status, 200);
}

TEST(push_then_pull_round_trips_icon_content_sha256_as_hex_not_bytea_literal) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);

    // Блоб заводится напрямую SQL — сам HTTP-эндпоинт POST /sync/blobs (см.
    // blob.hpp) вне охвата этого харнеса (нужен auth/JWKS-стек, см.
    // tests_integration/README.md); push_batch/pull проверяются здесь ровно
    // так, как их видел бы клиент, УЖЕ загрузивший содержимое.
    std::string sha_hex = fixture::detail::random_hex64();
    db->exec("INSERT INTO blob (sha256, bytes) VALUES (decode($1,'hex'), decode('00','hex'))",
             {sha_hex});

    std::string icon_uuid = uuidgen::v4();
    json changes = {{"icon", json::array({json{{"uuid", icon_uuid},
                                                 {"name", "test-icon-" + icon_uuid},
                                                 {"content_sha256", sha_hex},
                                                 {"icon_type", 0}}})}};

    auto push_result =
        push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(), changes);
    REQUIRE(push_result.http_status == 200);

    // pull_LEDGER_stream, не pull_reference_stream — upsert_row всегда
    // подставляет АУТЕНТИФИЦИРОВАННЫЙ ledger_id (см. sync_repo.hpp,
    // Scope::ReferenceOrLedger: "клиент никогда не пишет общую строку"),
    // так что запушенная руками иконка становится ЛИЧНОЙ копией этого
    // леджера, а не общей (ledger_id IS NULL) — общие заводятся только в
    // обход push_batch (см. fixture::make_reference_icon).
    auto pull_result =
        sync_repo::pull_ledger_stream(*db, identity.ledger_id, /*cursor=*/0, /*limit=*/1000);
    REQUIRE(pull_result.changes.contains("icon"));

    bool found = false;
    for (const auto& row : pull_result.changes.at("icon")) {
        if (row.at("uuid").get<std::string>() != icon_uuid) continue;
        found = true;
        // Регрессия на to_jsonb()-bytea-как-"\x..." (см. TableSpec::
        // hex_columns) — content_sha256 обязан прийти чистым hex, тем же,
        // что отправил клиент, не текстовым представлением bytea Postgres.
        REQUIRE(row.at("content_sha256").is_string());
        CHECK_EQ(row.at("content_sha256").get<std::string>(), sha_hex);
    }
    CHECK(found);
}

TEST(push_rejects_icon_referencing_unknown_blob) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);

    std::string missing_sha_hex = fixture::detail::random_hex64(); // ни разу не загружен
    std::string icon_uuid = uuidgen::v4();
    json changes = {{"icon", json::array({json{{"uuid", icon_uuid},
                                                 {"name", "orphan-" + icon_uuid},
                                                 {"content_sha256", missing_sha_hex},
                                                 {"icon_type", 0}}})}};

    auto result =
        push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(), changes);
    CHECK_EQ(result.http_status, 409);
    json body = json::parse(result.response_body);
    CHECK_EQ(body.at("error").get<std::string>(), std::string("missing_reference"));
}

TEST(currency_pair_rate_from_two_devices_upserts_by_natural_key_not_uuid) {
    // Реальная находка (2026-09-05, лог POST /sync/push): два офлайн-
    // устройства независимо заводят курс на одну и ту же (пара, дата) —
    // РАЗНЫМИ uuid, клиент по нему не сверялся (см. TableSpec::
    // conflict_columns, почему). Второй push раньше падал прямо на
    // uq_currency_pair_rate_ledger (23505), не доходя до ON CONFLICT
    // (uuid) — теперь конфликт резолвится по (ledger, пара, дата), и
    // второй push должен победить: одна строка, её rate/uuid — от
    // последнего пришедшего батча.
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon_uuid = fixture::make_reference_icon(*db);

    std::string base_uuid = uuidgen::v4();
    std::string quote_uuid = uuidgen::v4();
    // Уникальный ISO-код на тест — currency общая между тестами (см.
    // resolve_eq_currency в test_reports.cpp, тот же приём).
    std::string base_iso = "B" + uuidgen::v4().substr(0, 2);
    std::string quote_iso = "Q" + uuidgen::v4().substr(0, 2);
    std::string pair_uuid = uuidgen::v4();
    std::string symbol = base_iso + quote_iso;

    json setup = {
        {"currency", json::array({make_currency_row(base_uuid, icon_uuid, base_iso),
                                   make_currency_row(quote_uuid, icon_uuid, quote_iso)})},
        {"currency_pair",
         json::array({make_currency_pair_row(pair_uuid, base_uuid, quote_uuid, symbol)})},
    };
    auto setup_result =
        push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(), setup);
    REQUIRE(setup_result.http_status == 200);

    std::string date = "2020-09-12";
    // Второе устройство ТОГО ЖЕ пользователя — provisioning::ensure_identity
    // с уже существующим user_id находит существующий леджер (см. её
    // комментарий, find_existing_ledger) и просто регистрирует ещё один
    // device под ним; изобретать uuid руками, как для device_id из
    // identity, нельзя — currency_pair_rate.updated_by ссылается на
    // реальную строку device (FK), иначе push упал бы 23503 раньше, чем
    // успел бы дойти до проверяемого здесь конфликта.
    std::string device_b = uuidgen::v4();
    provisioning::ensure_identity(*db, identity.user_id, "integration-test@example.com", device_b,
                                   "integration-test-device-b", "other");
    std::string rate_uuid_a = uuidgen::v4();
    std::string rate_uuid_b = uuidgen::v4();

    json push_a = {{"currency_pair_rate",
                     json::array({make_currency_pair_rate_row(rate_uuid_a, pair_uuid, date, "1.5")})}};
    auto result_a =
        push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(), push_a);
    REQUIRE(result_a.http_status == 200);

    json push_b = {{"currency_pair_rate",
                     json::array({make_currency_pair_rate_row(rate_uuid_b, pair_uuid, date, "1.7")})}};
    auto result_b = push_batch_guarded(db, identity.ledger_id, device_b, uuidgen::v4(), push_b);
    // Регрессия — раньше это был 500 (23505 не пойман, ON CONFLICT(uuid) не
    // применялся к arbiter'у uq_currency_pair_rate_ledger).
    CHECK_EQ(result_b.http_status, 200);

    auto rows = db->exec(
        "SELECT uuid, rate::text FROM currency_pair_rate "
        "WHERE ledger_id = $1 AND currency_pair_uuid = $2 AND date = $3 AND deleted_at IS NULL",
        {identity.ledger_id, pair_uuid, date});
    // Одна строка — не две (естественный ключ, не uuid, реально арбитр).
    REQUIRE(rows.rows.size() == static_cast<std::size_t>(1));
    // Последний push победил целиком — и rate, и uuid.
    CHECK_EQ(rows.rows.at(0).fields.at(0), rate_uuid_b);
    CHECK_EQ(rows.rows.at(0).fields.at(1), std::string("1.7000000000"));
}

TEST(currency_pair_rate_revives_soft_deleted_row_by_uuid_not_duplicate_key) {
    // Реальный инцидент (лог POST /sync/push): "duplicate key value violates
    // unique constraint currency_pair_rate_pkey ... uuid=... already exists".
    // Клиент "оживляет" СВОЙ же мягко удалённый курс — тот же uuid, deleted
    // снова false — на ту же (ledger, пара, дата). Раньше это падало: строка
    // с этим uuid уже существует (просто deleted_at IS NOT NULL), поэтому она
    // вне предиката uq_currency_pair_rate_ledger (WHERE deleted_at IS NULL) —
    // ON CONFLICT (естественный ключ, см. TableSpec::conflict_columns) её не
    // видит, а голый INSERT падает прямо на PRIMARY KEY. Теперь upsert_row
    // сначала пробует UPDATE напрямую по uuid (см. sync_repo.cpp) — эта строка
    // находится и обновляется, до ON CONFLICT дело не доходит.
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon_uuid = fixture::make_reference_icon(*db);

    std::string base_uuid = uuidgen::v4();
    std::string quote_uuid = uuidgen::v4();
    std::string base_iso = "R" + uuidgen::v4().substr(0, 2);
    std::string quote_iso = "S" + uuidgen::v4().substr(0, 2);
    std::string pair_uuid = uuidgen::v4();
    std::string symbol = base_iso + quote_iso;

    json setup = {
        {"currency", json::array({make_currency_row(base_uuid, icon_uuid, base_iso),
                                   make_currency_row(quote_uuid, icon_uuid, quote_iso)})},
        {"currency_pair",
         json::array({make_currency_pair_row(pair_uuid, base_uuid, quote_uuid, symbol)})},
    };
    auto setup_result =
        push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(), setup);
    REQUIRE(setup_result.http_status == 200);

    std::string date = "2020-09-13";
    std::string rate_uuid = uuidgen::v4();

    json create_row = make_currency_pair_rate_row(rate_uuid, pair_uuid, date, "1.5");
    auto created = push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(),
                                       json{{"currency_pair_rate", json::array({create_row})}});
    REQUIRE(created.http_status == 200);

    json delete_row = make_currency_pair_rate_row(rate_uuid, pair_uuid, date, "1.5");
    delete_row["deleted"] = true;
    auto deleted = push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(),
                                       json{{"currency_pair_rate", json::array({delete_row})}});
    REQUIRE(deleted.http_status == 200);

    json revive_row = make_currency_pair_rate_row(rate_uuid, pair_uuid, date, "1.9");
    auto revived = push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(),
                                       json{{"currency_pair_rate", json::array({revive_row})}});
    // Регрессия — раньше это был 409 duplicate_key (23505 на currency_pair_rate_pkey).
    CHECK_EQ(revived.http_status, 200);

    auto rows = db->exec(
        "SELECT rate::text FROM currency_pair_rate "
        "WHERE uuid = $1 AND ledger_id = $2 AND deleted_at IS NULL",
        {rate_uuid, identity.ledger_id});
    // Тот же uuid ожил, а не расплодился второй строкой на ту же (ledger,
    // пара, дата) — естественный ключ по-прежнему уникален среди живых строк.
    REQUIRE(rows.rows.size() == static_cast<std::size_t>(1));
    CHECK_EQ(rows.rows.at(0).fields.at(0), std::string("1.9000000000"));
}

// Регрессия/реальный инцидент 2026-09-13 (первый же синк с телефона, лог
// POST /sync/push): currency_pair (EURHRK) ушла в push раньше своей
// currency (на клиенте она оказалась dirty=0 — уже "отправленной", хотя ЭТОТ
// сервер её никогда не видел, см. Android SyncEngine.collectDirtyByTable,
// "WHERE dirty=1") — INSERT currency_pair падал на 23503
// (currency_pair_base_currency_uuid_fkey), клиент получал только текст
// ошибки Postgres и не мог сам понять, чего не хватает (см. Android
// SyncEngine.PushRejectedException — "не самовосстанавливающийся").
//
// Эти два теста проверяют именно то, чего не хватало: (1) 409 теперь несёт
// МАШИНОЧИТАЕМЫЕ table/uuid — REFERENCED таблицу и её uuid, не просто текст
// (см. sync_repo.cpp, parse_missing_reference); (2) присланных table/uuid
// достаточно клиенту, чтобы САМ починиться — второй push, довозящий именно
// эту строку вместе с исходной currency_pair, обязан пройти.
TEST(push_rejects_currency_pair_referencing_unknown_currency_with_structured_reference) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon_uuid = fixture::make_reference_icon(*db);

    // base — намеренно НЕ отправлена (это и есть сама суть инцидента:
    // currency_pair одна, без своей currency, в одном и том же батче).
    std::string missing_base_uuid = uuidgen::v4();
    std::string quote_uuid = uuidgen::v4();
    std::string pair_uuid = uuidgen::v4();

    json changes = {
        {"currency", json::array({make_currency_row(quote_uuid, icon_uuid, "Q" + uuidgen::v4().substr(0, 2))})},
        {"currency_pair", json::array({make_currency_pair_row(pair_uuid, missing_base_uuid,
                                                                quote_uuid, "EURHRK")})},
    };

    auto result =
        push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(), changes);

    CHECK_EQ(result.http_status, 409);
    json body = json::parse(result.response_body);
    CHECK_EQ(body.at("error").get<std::string>(), std::string("missing_reference"));
    // Реальная находка — table называет REFERENCED таблицу ("currency"), не
    // ту, в которую шёл INSERT ("currency_pair", она и так известна клиенту:
    // это его собственная строка) — см. sync_repo.cpp, комментарий у
    // MissingReference.
    REQUIRE(body.contains("table"));
    REQUIRE(body.contains("uuid"));
    CHECK_EQ(body.at("table").get<std::string>(), std::string("currency"));
    CHECK_EQ(body.at("uuid").get<std::string>(), missing_base_uuid);

    // Весь батч откатился целиком — тот же принцип "всё или ничего", что и у
    // остальных отказов push_batch (см. push_rejects_row_missing_required_column_with_400_not_crash).
    auto count = db->exec("SELECT count(*) FROM currency_pair WHERE uuid = $1", {pair_uuid});
    CHECK_EQ(count.rows.at(0).fields.at(0), std::string("0"));
}

TEST(push_missing_reference_self_heals_when_client_resends_referenced_row) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon_uuid = fixture::make_reference_icon(*db);

    std::string base_uuid = uuidgen::v4();
    std::string base_iso = "B" + uuidgen::v4().substr(0, 2);
    std::string quote_uuid = uuidgen::v4();
    std::string pair_uuid = uuidgen::v4();

    json first_try = {
        {"currency", json::array({make_currency_row(quote_uuid, icon_uuid, "Q" + uuidgen::v4().substr(0, 2))})},
        {"currency_pair",
         json::array({make_currency_pair_row(pair_uuid, base_uuid, quote_uuid, base_iso + "Q")})},
    };
    auto rejected =
        push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(), first_try);
    REQUIRE(rejected.http_status == 409);
    json body = json::parse(rejected.response_body);
    REQUIRE(body.at("table").get<std::string>() == std::string("currency"));
    REQUIRE(body.at("uuid").get<std::string>() == base_uuid);

    // Ровно то, что Android SyncEngine.pushDirty делает при получении этого
    // ответа: помечает локальную currency (base_uuid) dirty=1 заново и на
    // СЛЕДУЮЩЕМ цикле шлёт её ВМЕСТЕ с уже ждущей currency_pair — TABLE_ORDER
    // на клиенте (и kApplyOrder здесь) ставит currency раньше currency_pair
    // сам по себе, порядок внутри батча тут ни при чём: важно, что она
    // вообще попала в тот же push. quote_uuid — СНОВА в батче, не только
    // base_uuid: первый push — одна транзакция целиком (push_batch), провал
    // на currency_pair откатил ЕЁ ВСЮ, включая уже вставленную было currency
    // (quote_uuid) — dirty у неё в реальном клиенте так и остался бы 1 (см.
    // pushDirty: "порция не применилась, dirty остаётся как есть"), сюда это
    // переносится тем же способом: повторяем всё, что было в первом push.
    json retry = {
        {"currency", json::array({make_currency_row(base_uuid, icon_uuid, base_iso),
                                   make_currency_row(quote_uuid, icon_uuid, "Q" + pair_uuid.substr(0, 2))})},
        {"currency_pair",
         json::array({make_currency_pair_row(pair_uuid, base_uuid, quote_uuid, base_iso + "Q")})},
    };
    auto healed =
        push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(), retry);
    CHECK_EQ(healed.http_status, 200);

    auto count = db->exec("SELECT count(*) FROM currency_pair WHERE uuid = $1", {pair_uuid});
    CHECK_EQ(count.rows.at(0).fields.at(0), std::string("1"));
}

// --- PushMode::CreateOperationsOnly — токен Telegram-бота, scope expense:write
// (org/docs/TODO_telegram_tokens.md, «Скоупы»): только новые операции.

namespace {

struct TwoAccounts {
    std::string from;
    std::string to;
};

TwoAccounts seed_accounts(const std::shared_ptr<db::Database>& db, const fixture::TestIdentity& identity) {
    std::string icon_uuid = fixture::make_reference_icon(*db);
    TwoAccounts a{uuidgen::v4(), uuidgen::v4()};
    json changes = {{"account", json::array({make_account_row(a.from, icon_uuid, "From " + a.from),
                                              make_account_row(a.to, icon_uuid, "To " + a.to)})}};
    auto seeded = push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(), changes);
    REQUIRE(seeded.http_status == 200);
    return a;
}

json operation_row(const std::string& uuid, const TwoAccounts& a, const std::string& amount) {
    return json{{"uuid", uuid},          {"date", "2026-09-30 12:00:00"}, {"acc_fr_uuid", a.from},
                {"acc_to_uuid", a.to},   {"amount", amount},              {"comment", "telegram"}};
}

std::string amount_of(db::Database& db, const std::string& ledger_id, const std::string& uuid) {
    auto r = db.exec("SELECT amount::text FROM operation WHERE ledger_id = $1 AND uuid = $2", {ledger_id, uuid});
    return r.rows.empty() ? std::string{} : r.rows.at(0).fields.at(0);
}

} // namespace

TEST(create_only_push_inserts_new_operation_and_replays_by_batch_id) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    auto accounts = seed_accounts(db, identity);
    std::string op = uuidgen::v4();
    std::string batch = uuidgen::v4();
    json changes = {{"operation", json::array({operation_row(op, accounts, "350")})}};

    auto first = push_batch_guarded(db, identity.ledger_id, identity.device_id, batch, changes,
                                    sync_repo::PushMode::CreateOperationsOnly);
    REQUIRE(first.http_status == 200);
    CHECK_EQ(amount_of(*db, identity.ledger_id, op), std::string("350.00000000"));

    // Тот же batch_id (повторная доставка апдейта, двойной клик) — сохранённый
    // ответ, не 403 «уже есть».
    auto replay = push_batch_guarded(db, identity.ledger_id, identity.device_id, batch, changes,
                                     sync_repo::PushMode::CreateOperationsOnly);
    CHECK_EQ(replay.http_status, 200);
    // Разобранный JSON, не текст: response — jsonb (см. push_batch_replay_*).
    CHECK_EQ(json::parse(replay.response_body), json::parse(first.response_body));
    auto count = db->exec("SELECT count(*) FROM operation WHERE uuid = $1", {op});
    CHECK_EQ(count.rows.at(0).fields.at(0), std::string("1"));
}

TEST(create_only_push_rejects_existing_operation_and_rolls_back_batch) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    auto accounts = seed_accounts(db, identity);
    std::string existing = uuidgen::v4();
    json phone = {{"operation", json::array({operation_row(existing, accounts, "100")})}};
    REQUIRE(push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(), phone).http_status == 200);

    // Новый batch_id, но uuid существующей операции — правка запрещена. Новая
    // операция в том же батче тоже не остаётся: откат целиком.
    std::string fresh = uuidgen::v4();
    json bot = {{"operation", json::array({operation_row(fresh, accounts, "1"),
                                            operation_row(existing, accounts, "999")})}};
    auto rejected = push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(), bot,
                                       sync_repo::PushMode::CreateOperationsOnly);
    REQUIRE(rejected.http_status == 403);
    json body = json::parse(rejected.response_body);
    CHECK_EQ(body.at("error").get<std::string>(), std::string("operation_exists"));
    CHECK_EQ(body.at("uuid").get<std::string>(), existing);
    CHECK_EQ(amount_of(*db, identity.ledger_id, existing), std::string("100.00000000"));
    CHECK(amount_of(*db, identity.ledger_id, fresh).empty());
}

TEST(create_only_push_rejects_other_tables_and_deletes) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    auto accounts = seed_accounts(db, identity);
    std::string icon_uuid = fixture::make_reference_icon(*db);

    json account = {{"account", json::array({make_account_row(uuidgen::v4(), icon_uuid, "Bot " + uuidgen::v4())})}};
    auto a = push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(), account,
                                sync_repo::PushMode::CreateOperationsOnly);
    CHECK_EQ(a.http_status, 403);
    CHECK(a.response_body.find("only_operation") != std::string::npos);

    json row = operation_row(uuidgen::v4(), accounts, "5");
    row["deleted"] = true;
    json del = {{"operation", json::array({row})}};
    auto d = push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(), del,
                                sync_repo::PushMode::CreateOperationsOnly);
    CHECK_EQ(d.http_status, 403);
    CHECK(d.response_body.find("delete_not_allowed") != std::string::npos);
}

TEST(provisioning_keeps_email_when_token_has_none_and_reports_role) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db); // email integration-test@example.com
    // Токен бота без email — провижининг не должен затирать сохранённый.
    auto bot = provisioning::ensure_identity(*db, identity.user_id, "", uuidgen::v4(), "", "telegram");
    CHECK_EQ(bot.ledger_id, identity.ledger_id);
    CHECK_EQ(bot.role, std::string("owner"));
    auto email = db->exec("SELECT email FROM app_user WHERE id = $1", {identity.user_id});
    CHECK_EQ(email.rows.at(0).fields.at(0), std::string("integration-test@example.com"));
}

TEST(browser_device_provisions_as_web_and_pushes_operation) {
    // Веб пишет трату через /sync/push токеном браузерной сессии: google-auth
    // выдаёт ей свой device_id на каждый вход (add-ai-expense-text, D1) —
    // провижининг заводит устройство platform=web в том же леджере, а
    // операция получает updated_by этого устройства.
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    auto accounts = seed_accounts(db, identity);

    std::string web_device = uuidgen::v4();
    auto web = provisioning::ensure_identity(*db, identity.user_id, "integration-test@example.com", web_device,
                                             "Веб-браузер", "web");
    CHECK_EQ(web.ledger_id, identity.ledger_id);

    std::string op = uuidgen::v4();
    json changes = {{"operation", json::array({operation_row(op, accounts, "450")})}};
    auto pushed = push_batch_guarded(db, web.ledger_id, web_device, uuidgen::v4(), changes);
    REQUIRE(pushed.http_status == 200);
    CHECK_EQ(amount_of(*db, identity.ledger_id, op), std::string("450.00000000"));

    auto device = db->exec("SELECT platform, ledger_id::text FROM device WHERE id = $1", {web_device});
    REQUIRE(device.rows.size() == 1);
    CHECK_EQ(device.rows.at(0).fields.at(0), std::string("web"));
    CHECK_EQ(device.rows.at(0).fields.at(1), identity.ledger_id);
    auto by = db->exec("SELECT updated_by::text FROM operation WHERE uuid = $1", {op});
    CHECK_EQ(by.rows.at(0).fields.at(0), web_device);
}

TEST(pull_with_cursor_ahead_of_stream_head_rewinds_to_zero) {
    // Регрессия 2026-09-30: телефон пришёл с курсором 146 от прежнего
    // леджера при голове 13 — pull отдавал пустоту с next_seq=146 навсегда,
    // и операции, записанные ботом, на устройство не доезжали.
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon_uuid = fixture::make_reference_icon(*db);

    std::string acc_uuid = uuidgen::v4();
    json changes = {{"account", json::array({make_account_row(acc_uuid, icon_uuid, "Ahead " + acc_uuid)})}};
    auto push_result = push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(), changes);
    REQUIRE(push_result.http_status == 200);
    int64_t head = json::parse(push_result.response_body).at("seq").get<int64_t>();

    auto ahead = sync_repo::pull_ledger_stream(*db, identity.ledger_id, /*cursor=*/head + 100, /*limit=*/1000);
    CHECK(ahead.reset);
    CHECK_EQ(ahead.next_seq, head);
    REQUIRE(ahead.changes.contains("account"));

    // Курсор ровно на голове — обычный «догнали», без сброса.
    auto caught_up = sync_repo::pull_ledger_stream(*db, identity.ledger_id, head, /*limit=*/1000);
    CHECK(!caught_up.reset);
    CHECK_EQ(caught_up.next_seq, head);
    CHECK(caught_up.changes.empty());

    auto reference = sync_repo::pull_reference_stream(*db, /*cursor=*/std::numeric_limits<int64_t>::max() / 2,
                                                      /*limit=*/1);
    CHECK(reference.reset);
}

TEST(push_does_not_overwrite_shared_reference_row_with_same_uuid) {
    // Регрессия 2026-10-10: телефон вернул push'ем скачанные общие иконки —
    // ON CONFLICT (uuid) DO UPDATE переписал им seq номером потока леджера
    // (21 при голове справочников 14), и каждый pull справочников с тех пор
    // видел курсор «впереди головы» и начинал поток с нуля.
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    auto shared = fixture::make_reference_icon_with_sha256(*db);

    auto before = db->exec("SELECT seq, name, ledger_id IS NULL FROM icon WHERE uuid = $1", {shared.uuid});
    REQUIRE(before.rows.size() == 1);

    json changes = {{"icon", json::array({json{{"uuid", shared.uuid},
                                                 {"name", "hijacked-" + shared.uuid},
                                                 {"content_sha256", shared.sha256_hex},
                                                 {"icon_type", 0}}})}};
    auto push_result = push_batch_guarded(db, identity.ledger_id, identity.device_id, uuidgen::v4(), changes);
    REQUIRE(push_result.http_status == 200);

    auto after = db->exec("SELECT seq, name, ledger_id IS NULL FROM icon WHERE uuid = $1", {shared.uuid});
    REQUIRE(after.rows.size() == 1);
    CHECK_EQ(after.rows.at(0).fields.at(0), before.rows.at(0).fields.at(0));
    CHECK_EQ(after.rows.at(0).fields.at(1), before.rows.at(0).fields.at(1));
    CHECK_EQ(after.rows.at(0).fields.at(2), std::string("t"));

    // Голова справочников не ниже ни одной общей строки — иначе pull сбросится.
    auto stream = db->exec(
        "SELECT (SELECT seq FROM change_stream WHERE id = '00000000-0000-0000-0000-000000000001') "
        ">= (SELECT max(seq) FROM icon WHERE ledger_id IS NULL)");
    CHECK_EQ(stream.rows.at(0).fields.at(0), std::string("t"));
}
