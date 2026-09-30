// Общая обвязка интеграционных тестов — живое соединение с Postgres и
// минимальные фикстуры (личность/иконка), без которых ни одна таблица
// протокола синка не примет строку (везде FK на account/icon/…, см.
// wallet-api/schema/table/README.md, "Общий набор колонок").
//
// Никакой очистки между тестами нет и не нужна: каждый TEST заводит СВОЙ
// user_id/device_id/ledger_id (случайные uuid, см. make_identity) — тесты не
// делят состояние и не мешают друг другу, сколько раз подряд ни запускай
// этот бинарь против одной и той же базы (см. README.md, "Изоляция").
#pragma once

#include <cctype>
#include <cstdlib>
#include <memory>
#include <stdexcept>
#include <string>

#include "db.hpp"
#include "provisioning.hpp"
#include "util/uuid.hpp"

namespace fixture {

inline std::string database_url() {
    const char* v = std::getenv("DATABASE_URL");
    if (v == nullptr || *v == '\0') {
        throw std::runtime_error(
            "DATABASE_URL не задан — интеграционные тесты wallet-api требуют "
            "живой Postgres с уже накаченной схемой (wallet-api/migrations/). "
            "См. tests_integration/README.md, раздел \"Как запустить\".");
    }
    return v;
}

// shared_ptr, не значение и не unique_ptr — намеренно: test_push_batch.cpp
// гоняет push_batch() в отдельном потоке с таймаутом (регрессия на дедлок
// 2026-09-04), и при срабатывании таймаута этот поток невозможно ни
// присоединить (он сам навсегда держит mutex_ данного db::Database), ни
// безопасно бросить — держать db::Database живым до конца процесса через
// разделяемое владение дешевле и безопаснее, чем гарантировать корректное
// завершение потока, который по определению не отвечает. Нормальный
// (не зависший) путь освобождает объект как обычно, когда обе копии
// shared_ptr выходят из области видимости.
inline std::shared_ptr<db::Database> open() {
    return std::make_shared<db::Database>(database_url());
}

struct TestIdentity {
    std::string user_id;
    std::string device_id;
    std::string ledger_id;
};

// Свежий пользователь+устройство+леджер на каждый вызов — см. шапку файла.
inline TestIdentity make_identity(db::Database& db) {
    TestIdentity id;
    id.user_id = uuidgen::v4();
    id.device_id = uuidgen::v4();
    // "other" — единственное из допустимых значений device.platform (см.
    // CHECK-констрейнт в миграции), которое не претендует быть настоящей
    // платформой; интеграционным тестам это неважно, только не пусто.
    auto identity = provisioning::ensure_identity(db, id.user_id, "integration-test@example.com",
                                                   id.device_id, "integration-test-device", "other");
    id.ledger_id = identity.ledger_id;
    return id;
}

namespace detail {

// 64 hex-символа = 32 байта — ровно формат blob.sha256 (см. миграцию,
// CHECK octet_length(sha256) = 32). Один uuidgen::v4() даёт 32 hex-цифры
// (16 байт), поэтому склеиваем два разных uuid, не заботясь о крипто-
// стойкости — это фикстура, не настоящий хэш содержимого.
inline std::string random_hex64() {
    std::string hex;
    for (char c : uuidgen::v4() + uuidgen::v4()) {
        if (std::isxdigit(static_cast<unsigned char>(c))) hex += c;
    }
    return hex.substr(0, 64);
}

} // namespace detail

// uuid + hex sha256 разом — нужно тестам, которые проверяют, что
// icon_sha256 в отчёте (f_expanse_by_category_for_period, 000005) реально
// совпадает с content_sha256 ИМЕННО этой иконки, не просто "похоже на hex".
// make_reference_icon() ниже — обёртка для мест, которым нужен только uuid
// (большинство существующих тестов).
struct ReferenceIcon {
    std::string uuid;
    std::string sha256_hex;
};

// Заводит ОБЩУЮ (ledger_id IS NULL) иконку напрямую SQL, в обход push_batch —
// проще фикстуры, где нужен только САМ факт существующей иконки (account/
// currency без icon_uuid не примет ни один push), не разбор push icon/blob
// как таковых (см. test_push_batch.cpp, push_then_pull_round_trips_icon_*
// — те гоняют настоящий push_batch). Один и тот же способ годится для
// любого леджера — не привязан к конкретному user_id/ledger_id, поэтому не
// входит в TestIdentity.
inline ReferenceIcon make_reference_icon_with_sha256(db::Database& db) {
    ReferenceIcon out;
    out.uuid = uuidgen::v4();
    out.sha256_hex = detail::random_hex64();

    db.exec("INSERT INTO blob (sha256, bytes) VALUES (decode($1, 'hex'), decode('00', 'hex'))",
            {out.sha256_hex});

    auto seq_res = db.exec("SELECT next_seq('00000000-0000-0000-0000-000000000001')");
    db.exec("INSERT INTO icon (uuid, seq, name, content_sha256, icon_type) "
            "VALUES ($1, $2, $3, decode($4, 'hex'), 0)",
            {out.uuid, seq_res.rows.at(0).fields.at(0), "test-icon-" + out.uuid, out.sha256_hex});

    return out;
}

inline std::string make_reference_icon(db::Database& db) {
    return make_reference_icon_with_sha256(db).uuid;
}

// Валюта — общая (ledger_id пуст) или своя данного леджера — тем же прямым
// SQL, что make_reference_icon_with_sha256 выше, в обход push_batch: нужен
// только сам факт существующей, видимой валюты для currency_pair.base_
// currency_uuid/quote_currency_uuid (см. test_currency_pairs.cpp). iso_code/
// name/symbol — из свежего uuid, НЕ фиксированная строка вроде "USD": тесты
// гоняются многократно против одной и той же базы без очистки между
// запусками (см. шапку файла), а у currency ЕСТЬ уникальные индексы на
// (ledger_id, iso_code)/(ledger_id, name) — фиксированная строка была бы
// растущим коллизионным риском при каждом повторном прогоне бинаря.
inline std::string make_currency(db::Database& db, const std::string& ledger_id,
                                  const std::string& icon_uuid) {
    std::string uuid = uuidgen::v4();
    std::string code = uuidgen::v4().substr(0, 8);
    std::string stream = ledger_id.empty() ? "00000000-0000-0000-0000-000000000001" : ledger_id;
    auto seq_res = db.exec("SELECT next_seq($1)", {stream});
    if (ledger_id.empty()) {
        db.exec("INSERT INTO currency (uuid, seq, name, iso_code, icon_uuid, symbol) "
                "VALUES ($1,$2,$3,$4,$5,$6)",
                {uuid, seq_res.rows.at(0).fields.at(0), code, code, icon_uuid, code});
    } else {
        db.exec("INSERT INTO currency (uuid, ledger_id, seq, name, iso_code, icon_uuid, symbol) "
                "VALUES ($1,$2,$3,$4,$5,$6,$7)",
                {uuid, ledger_id, seq_res.rows.at(0).fields.at(0), code, code, icon_uuid, code});
    }
    return uuid;
}

} // namespace fixture
