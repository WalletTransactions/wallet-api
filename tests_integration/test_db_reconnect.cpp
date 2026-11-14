// Переподключение db::Database к Postgres против ЖИВОЙ базы: backend убивается
// из второго соединения через pg_terminate_backend — ровно то, что делает
// рестарт Postgres или обрыв сети (общий код — util/pg_recover.hpp).
//
// Регрессия на 2026-11-13 (wallet-docs, `/api/docs/ask` -> 503 после рестарта
// БД): `if (PQstatus(conn_) != CONNECTION_OK) PQreset(conn_)` не видит умерший
// сокет, пока клиент не попробует в него писать, и первый запрос после
// рестарта падал «server closed the connection unexpectedly».
#include <chrono>
#include <exception>
#include <string>
#include <thread>

#include "db.hpp"
#include "fixture.hpp"
#include "test_framework.hpp"
#include "util/uuid.hpp"

namespace {

std::string backend_pid(db::Database& d) { return d.exec("SELECT pg_backend_pid()").rows.at(0).fields.at(0); }

void terminate_backend(db::Database& admin, const std::string& pid) {
    admin.exec("SELECT pg_terminate_backend($1::int)", {pid});
}

void settle() { std::this_thread::sleep_for(std::chrono::milliseconds(300)); }

} // namespace

TEST(reconnect_first_query_after_backend_terminated_succeeds) {
    auto victim = fixture::open();
    auto admin = fixture::open();
    std::string before = backend_pid(*victim);
    terminate_backend(*admin, before);
    settle(); // FIN от сервера успевает дойти до сокета victim

    // Раньше: PQstatus == CONNECTION_OK, а запрос падал «server closed the connection unexpectedly».
    auto res = victim->exec("SELECT 1");
    CHECK_EQ(res.rows.at(0).fields.at(0), std::string("1"));
    CHECK(backend_pid(*victim) != before); // соединение действительно новое
}

TEST(reconnect_read_survives_termination_in_the_middle_of_query) {
    auto victim = fixture::open();
    auto admin = fixture::open();
    std::string pid = backend_pid(*victim);

    std::thread killer([&] {
        std::this_thread::sleep_for(std::chrono::milliseconds(700));
        terminate_backend(*admin, pid);
    });
    // Чтение повторяется один раз на новом соединении.
    auto res = victim->exec("SELECT pg_sleep(2), 42::text");
    killer.join();
    CHECK_EQ(res.rows.at(0).fields.at(1), std::string("42"));
}

TEST(reconnect_write_is_not_retried_when_connection_dies_mid_query) {
    auto victim = fixture::open();
    auto admin = fixture::open();
    std::string pid = backend_pid(*victim);
    std::string sha = fixture::detail::random_hex64();

    std::thread killer([&] {
        std::this_thread::sleep_for(std::chrono::milliseconds(700));
        terminate_backend(*admin, pid);
    });
    // Клиент не знает, выполнил ли сервер запись до обрыва, — автоповтора нет:
    // одна ошибка вместо риска дубля операции.
    CHECK_THROWS(victim->exec("INSERT INTO blob (sha256, bytes) "
                              "SELECT decode($1, 'hex'), decode('00', 'hex') FROM pg_sleep(2)",
                              {sha}));
    killer.join();

    auto count = admin->exec("SELECT count(*) FROM blob WHERE sha256 = decode($1, 'hex')", {sha});
    CHECK_EQ(count.rows.at(0).fields.at(0), std::string("0")); // ни применена, ни продублирована

    // А следующий запрос на этом же объекте уже работает.
    CHECK_EQ(victim->exec("SELECT 1").rows.at(0).fields.at(0), std::string("1"));
}

TEST(reconnect_inside_transaction_reports_error_instead_of_silent_reset) {
    auto victim = fixture::open();
    auto admin = fixture::open();
    {
        auto tx = victim->begin_transaction();
        std::string pid = tx.exec("SELECT pg_backend_pid()").rows.at(0).fields.at(0);
        terminate_backend(*admin, pid);
        settle();
        // PQreset внутри транзакции молча потерял бы BEGIN, и следующие запросы
        // продолжились бы вне транзакции.
        CHECK_THROWS(tx.exec("SELECT 1"));
    }
    CHECK_EQ(victim->exec("SELECT 1").rows.at(0).fields.at(0), std::string("1"));
}
