// Состояние процесса wallet-api. Гибрид двух соседних сервисов: своя БД, как
// у google-auth (но только с таблицей wallets — без users/roles/
// refresh_tokens, см. db.hpp), и проверка чужого токена по JWKS, как у
// wallet-gateway (никакого OAuth и выпуска токенов тут нет — этим
// целиком занимается auth-сервис).
#pragma once

#include <memory>
#include <string>

#include "db.hpp"
#include "util/jwks.hpp"

struct AppState {
    // Публичные ключи auth-сервиса (RS256, GET /.well-known/jwks.json) —
    // ими проверяется подпись access-токена. Никакого общего секрета в
    // конфиге — см. README google-auth, "Как убрали общий секрет".
    std::unique_ptr<jwks::Cache> jwks;

    // wallets — в СВОЕЙ Postgres, отдельной от базы auth-сервиса (см.
    // README, "Своя БД"). Пул соединений (DATABASE_POOL_SIZE, по умолчанию
    // 8, см. src/db.hpp::Pool) — по прямому запросу ("правь все пункты по
    // нагрузке"), взамен единственного соединения на весь процесс: сервис
    // синка держит несколько одновременных запросов уже с одного устройства
    // (push + подгрузка блобов), не говоря про несколько устройств одного
    // леджера параллельно. unique_ptr — тот же приём, что и в google-auth:
    // конструктор Pool требует строку подключения, а AppState собирается в
    // main() уже после чтения .env.
    std::unique_ptr<db::Pool> db_pool;

    // Чистка tombstone синка (change purge-synced-tombstones, README,
    // "Срок хранения удалённых строк"). SYNC_TOMBSTONE_PURGE — выключатель,
    // по умолчанию off: включать только после релиза Android с вычисткой
    // при старте с нуля. Подтверждения устройств пишутся при любом значении.
    // SYNC_TOMBSTONE_DEVICE_TTL_DAYS — устройство без pull дольше этого
    // срока в горизонт не входит.
    bool tombstone_purge = false;
    int tombstone_device_ttl_days = 90;
};
