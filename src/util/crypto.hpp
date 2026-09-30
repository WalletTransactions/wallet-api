// Изначально урезанная копия util/crypto.hpp из google-auth: этот сервис
// только ПРОВЕРЯЕТ подпись access-токена (RS256, по публичному ключу с JWKS
// auth-сервиса — см. util/jwks.hpp) — своих токенов не подписывает. Фаза 6
// (org/docs/TODO_mobile_sync.md, приглашения в леджер) впервые заводит
// секрет, который генерирует САМ этот сервис (invite-токен) — отсюда
// random_bytes ниже, скопированная из google-auth/src/util/crypto.cpp
// (там она нужна для refresh-токенов) дословно.
#pragma once

#include <cstddef>
#include <string>
#include <vector>

namespace crypto {

// SHA-256 содержимого — используется для адресации blob по хешу (см.
// wallet-api/schema/table/blob.sql, org/docs/TODO_mobile_sync.md, "Иконки"):
// сервер сам считает хеш загруженных байт, не доверяя тому, что мог бы
// прислать клиент. Копия google-auth/src/util/crypto.hpp::sha256 (та нужна
// там для PKCE) — не общий заголовок между сервисами: каждый С++-сервис в
// этом проекте самодостаточен, без общей библиотеки-прослойки.
std::vector<unsigned char> sha256(const std::string& data);

// n криптографически стойких случайных байт (OpenSSL RAND_bytes) — сырой
// invite-токен (Фаза 6): попадает в ссылку и в ответ на создание, в БД не
// хранится вообще (только его sha256, см. wallet-api/schema/table/
// ledger_invite.sql). Бросает std::runtime_error, если ОС не смогла отдать
// достаточно энтропии (крайне маловероятно, но тихо продолжать с плохим
// генератором для секрета, дающего доступ к чужому кошельку, нельзя).
std::vector<unsigned char> random_bytes(std::size_t n);

// Проверяет подпись RSASSA-PKCS1-v1_5 SHA-256 по сырым модулю/экспоненте
// RSA-ключа — ровно в том формате, в котором их отдаёт JWKS (base64url,
// уже декодированный в байты вызывающим кодом). Возвращает false при любой
// ошибке (битый ключ, неверная подпись и т.п.), исключений не бросает.
bool rsa_sha256_verify(const std::vector<unsigned char>& n,
                        const std::vector<unsigned char>& e,
                        const std::string& signed_data,
                        const std::vector<unsigned char>& signature);

} // namespace crypto
