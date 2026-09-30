// Тонкая обёртка над libpq (C API Postgres) — без vcpkg/libpqxx, в том же
// стиле, что и util/crypto.hpp поверх OpenSSL: прямой вызов C-библиотеки без
// лишней прослойки. Database сама по себе — по-прежнему одно постоянное
// соединение + мьютекс, как и была; пул из НЕСКОЛЬКИХ таких Database — это
// Pool ниже (по прямому запросу — "правь все пункты по нагрузке", тот же
// класс, что уже выправил ровно эту болезнь в wallet-report, см. её db.hpp).
#pragma once

#include <condition_variable>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <unordered_set>
#include <vector>

// Форвард-декларация вместо #include <libpq-fe.h> здесь — чтобы этот
// заголовок (а с ним и libpq-fe.h) не тянулся во все .cpp, которые просто
// хотят типы db::Database/Result. Полный <libpq-fe.h> нужен только db.cpp.
// Typedef ровно повторяет объявление в libpq-fe.h, поэтому конфликта нет.
extern "C" {
typedef struct pg_conn PGconn;
}

namespace db {

struct Row {
    // SQL NULL -> "" — наша схема их не производит (везде NOT NULL/DEFAULT),
    // поэтому различать NULL и пустую строку здесь не нужно.
    std::vector<std::string> fields;
};

struct Result {
    std::vector<Row> rows;
};

// Раньше exec() при ошибке SQL бросал голый std::runtime_error с текстом
// сообщения Postgres — этого хватало, пока вызывающему коду было всё равно,
// КАКАЯ именно ошибка произошла (единственный обработчик — main(), падает и
// печатает текст). Фаза 2 (org/docs/TODO_mobile_sync.md) впервые заводит код,
// которому это важно: POST /sync/push обязан отличить "дубль имени счёта"
// (штатный конфликт двух офлайн-устройств, 409 клиенту) от любой другой
// ошибки (500) — парсить локализуемый текст сообщения для этого ненадёжно,
// а SQLSTATE и имя нарушенного constraint Postgres отдаёт готовыми, отдельными
// полями ответа (PQresultErrorField), незачем их из текста выковыривать.
struct QueryError : std::runtime_error {
    std::string sqlstate;        // 5 символов, напр. "23505" — unique_violation
    std::string constraint_name; // имя нарушенного constraint, пусто, если неприменимо
    // PG_DIAG_MESSAGE_DETAIL — для foreign_key_violation (23503) Postgres
    // кладёт сюда стабильно оформленный текст вида
    // "Key (base_currency_uuid)=(...) is not present in table \"currency\"."
    // (тот же формат уже вручную читал человек в момент диагностики реального
    // инцидента 2026-09-13 — см. sync_repo.cpp, missing_reference). Отдельное
    // поле вместо вычленения из message (std::runtime_error::what()) — тот
    // же довод, что у sqlstate/constraint_name выше: готовое поле Postgres
    // надёжнее, чем парсинг склеенного текста ошибки.
    std::string message_detail;

    QueryError(const std::string& message, std::string sqlstate_in, std::string constraint_in,
               std::string message_detail_in = "")
        : std::runtime_error(message),
          sqlstate(std::move(sqlstate_in)),
          constraint_name(std::move(constraint_in)),
          message_detail(std::move(message_detail_in)) {}
};

class Database {
public:
    // log_params — писать ли значения параметров запроса ($1, $2, ...) в
    // structured-лог (см. exec() ниже). По умолчанию false: параметры — это
    // произвольные данные приложения (email, суммы кошельков и т.п.), и
    // логировать их вслепую значило бы решать за вызывающий код, что можно
    // писать в лог, а что нет (см. README, "Логирование" — включается через
    // LOG_SQL_PARAMS, только для локальной отладки). Сам SQL-текст логируется
    // всегда — он безопасен по построению: это plain PQexecParams с $N
    // плейсхолдерами, литеральных значений в нём нет независимо от флага.
    //
    // mask_param_names — доп. имена параметров (сверх встроенного набора
    // password/token/secret/... — см. builtin_mask_param_names() в db.cpp),
    // чьё значение exec() заменит на "***" в логе, если вызывающий код указал
    // это имя для параметра через param_names (см. exec() ниже) — расширяет
    // встроенный набор, а не заменяет (см. LOG_SQL_MASK_PARAMS в README.md/
    // .env.example). Работает независимо от log_params_: секрет не должен
    // осесть в логе в открытом виде, даже когда параметры логируются
    // намеренно для отладки.
    explicit Database(const std::string& conninfo, bool log_params = false,
                       const std::unordered_set<std::string>& mask_param_names = {});
    ~Database();
    Database(const Database&) = delete;
    Database& operator=(const Database&) = delete;

    // НЕ создаёт схему (в отличие от прежнего migrate()) — роль, которой
    // подключается сервис, лишена DDL (см. infra/db/README.md в корне репозитория,
    // "Три роли"): CREATE TABLE ей запрещён, даже IF NOT EXISTS, даже если
    // таблица уже есть (Postgres проверяет право CREATE на схему раньше,
    // чем факт существования объекта — не короткое замыкание). Схему
    // накатывает отдельная роль-мигратор — см. infra/db/init-db.sh. Здесь —
    // быстрая проверка "а она вообще накачена", чтобы упасть сразу с
    // понятной ошибкой при старте, а не на первом реальном запросе.
    // Бросает std::runtime_error, если чего-то не хватает.
    void verify_schema();

    // params — текстовые значения; libpq сам кастует их к типу колонки по
    // контексту запроса ($1, $2, ... без явных типов). Бросает QueryError
    // при ошибке SQL (наследник std::runtime_error — старый код, ловящий
    // его как runtime_error, продолжит работать без изменений).
    //
    // param_names — имена параметров ИЗ params, в том же порядке; можно
    // короче params или вовсе пусто — недостающие позиции просто не участвуют
    // в маскировке. Нужны, только если среди params есть значение, которое
    // нельзя писать в лог в открытом виде (см. mask_param_names у
    // конструктора выше) — тогда exec() заменит его на "***" при
    // log_params_ == true. Сейчас ни один вызывающий код в этом сервисе не
    // передаёт в Postgres секретов (свой JWT сервис только проверяет, не
    // хранит — см. README, "Как проверяется токен"), поэтому везде пусто;
    // передавайте явно, как только появится такая колонка.
    Result exec(const std::string& sql, const std::vector<std::string>& params = {},
                const std::vector<std::string>& param_names = {});

    // Многошаговая транзакция (Фаза 2, org/docs/TODO_mobile_sync.md —
    // POST /sync/push обязан примениться одной транзакцией, иначе вторая
    // нога перевода/комиссия может доехать отдельно от первой, см. README
    // "Что реализовано"). Одиночные exec() выше берут mutex_ только на время
    // ОДНОГО запроса — если бы push делал несколько независимых exec()
    // (BEGIN, INSERT, INSERT, ..., COMMIT), между ними мьютекс освобождался
    // бы, и чужой запрос с другого потока мог вклиниться в это же соединение
    // ПОСЕРЕДИНЕ транзакции (соединение у Database одно на весь процесс —
    // см. класс выше). Transaction держит lock на всё время своей жизни,
    // так что весь батч выполняется как один непрерывный кусок работы на
    // соединении.
    //
    // RAII: не вызвали commit() до разрушения объекта — ROLLBACK сам, без
    // явного вызова на каждом пути ошибки (тем более что кидающий exec()
    // исключением и так пропускает остаток функции, включая любой явный
    // rollback()).
    class Transaction {
    public:
        ~Transaction();
        Transaction(Transaction&&) = delete;
        Transaction(const Transaction&) = delete;
        Transaction& operator=(const Transaction&) = delete;

        Result exec(const std::string& sql, const std::vector<std::string>& params = {},
                    const std::vector<std::string>& param_names = {});
        void commit();

    private:
        friend class Database;
        explicit Transaction(Database& db);

        Database& db_;
        std::unique_lock<std::mutex> lock_;
        bool committed_ = false;
    };

    Transaction begin_transaction() { return Transaction(*this); }

private:
    // Общее тело exec()/Transaction::exec() — предполагает, что mutex_ уже
    // захвачен вызывающим (сам exec() берёт его на время одного вызова,
    // Transaction — на всю свою жизнь, см. выше).
    Result exec_locked(const std::string& sql, const std::vector<std::string>& params = {},
                        const std::vector<std::string>& param_names = {});

    PGconn* conn_;
    std::mutex mutex_;
    bool log_params_;
    std::unordered_set<std::string> mask_param_names_;
};

// Пул из N постоянных соединений — вместо ЕДИНСТВЕННОЙ Database на весь
// процесс (см. AppState::db_pool). wallet-api — сервис синка (`/sync/push`/
// `/sync/pull`), приглашений, курсов валют и блобов: одно открытие "Отчётов"
// или простое использование приложения уже даёт НЕСКОЛЬКО одновременных
// запросов с одного устройства (синк + подгрузка иконок/блобов), плюс
// несколько устройств одного леджера синкаются параллельно. На одном
// соединении они сериализовались бы через её mutex_ целиком — любой
// достаточно долгий push (батч побольше, INSERT-конфликт с ретраем) держал
// бы мьютекс всё это время и блокировал вообще все остальные запросы, в том
// числе от ДРУГИХ пользователей: один медленный push превращался бы в "весь
// сервис встал", а не просто "у этого пользователя один запрос подождал".
//
// Pool не меняет саму Database (по-прежнему одно соединение + мьютекс
// внутри каждого экземпляра) — просто держит N её экземпляров и раздаёт их
// запросам по одному через acquire(): конкуренция теперь упирается в N, а не
// в 1. Транзакции (Database::Transaction) по-прежнему безопасны — каждый
// вызывающий код (см. sync.cpp/invites.cpp/currency_pairs.cpp/blob.cpp)
// делает РОВНО ОДИН acquire() на весь хендлер одного HTTP-запроса и передаёт
// *lease дальше как обычный db::Database& — ни один internal-код (*_repo.cpp,
// provisioning.cpp) сам из пула не тянет, поэтому вложенного acquire()
// (а с ним и риска взаимной блокировки — держим лизу и ждём вторую, пока кто-то
// другой держит вторую и ждёт первую) в рамках одного запроса попросту НЕТ:
// PQBEGIN...COMMIT транзакции всегда целиком укладывается в один такой вызов,
// начинается и заканчивается на ОДНОМ и том же соединении.
class Pool {
public:
    // conninfo/log_params/mask_param_names — те же смыслы, что у конструктора
    // Database выше: ВСЕ size соединений пула открываются с ОДИНАКОВЫМИ
    // параметрами. Бросает то же std::runtime_error, что и Database, если
    // хотя бы одно из size соединений не открылось — падаем при старте
    // процесса, а не на первом реальном запросе.
    Pool(const std::string& conninfo, std::size_t size, bool log_params = false,
         const std::unordered_set<std::string>& mask_param_names = {});
    ~Pool() = default;
    Pool(const Pool&) = delete;
    Pool& operator=(const Pool&) = delete;

    // Схема одна на все size соединений (та же Postgres-база) — проверяем
    // один раз, на первом же соединении пула, а не на каждом: если её нет,
    // остальные size-1 провалились бы ровно тем же способом, лишний шум.
    void verify_schema();

    // RAII-обёртка вокруг ОДНОГО соединения "на время одного вызова" —
    // получена из acquire(), возвращается в пул автоматически в деструкторе
    // (в т.ч. если вызывающий код кинул исключение — тот же приём, что и у
    // Transaction выше). Некопируема (владение одним соединением должно быть
    // ровно у одного Lease одновременно), но перемещаема — только так
    // acquire() может вернуть её по значению.
    class Lease {
    public:
        Lease(Lease&& other) noexcept;
        Lease(const Lease&) = delete;
        Lease& operator=(const Lease&) = delete;
        Lease& operator=(Lease&&) = delete;
        ~Lease();

        Database& operator*() const { return *conn_; }
        Database* operator->() const { return conn_; }

    private:
        friend class Pool;
        Lease(Pool* pool, Database* conn) : pool_(pool), conn_(conn) {}

        Pool* pool_;
        Database* conn_;
    };

    // Блокирует вызывающий поток, если все size соединений заняты — до тех
    // пор, пока какой-нибудь Lease не разрушится и не вернёт своё соединение
    // (см. release() ниже). httplib сам ограничивает число потоков,
    // обрабатывающих запросы, так что это не бесконечная очередь, а обычное
    // ожидание своей очереди за общим ресурсом, которого раньше (при size=1,
    // без пула вовсе) тоже приходилось ждать — просто ЗА ОДНИМ, а не за
    // одним из N.
    Lease acquire();

private:
    void release(Database* conn);

    // conns_ — владение: N экземпляров Database, живут всё время жизни
    // пула. idle_ — подмножество СВОБОДНЫХ СЕЙЧАС из них, сырыми указателями
    // (не владение — оно у conns_).
    std::vector<std::unique_ptr<Database>> conns_;
    std::vector<Database*> idle_;
    std::mutex mutex_;
    std::condition_variable cv_;

    friend class Lease;
};

} // namespace db
