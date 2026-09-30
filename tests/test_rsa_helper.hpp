// Тестовый RSA-ключ + сборка JWT/JWKS вручную — для юнит-тестов session.cpp
// (см. test_session.cpp), которым нужен настоящий RS256-токен, но своего
// RsaSigningKey/sign_rs256 в этом сервисе нет (см. util/crypto.hpp,
// util/jwt.hpp — только verify, wallet-api ничего не подписывает).
//
// Генерация ключа — тем же приёмом, что TempRsaKeyFile в google-auth/tests
// (EVP_PKEY_CTX, не EVP_PKEY_Q_keygen — ради совместимости со всеми
// поддерживаемыми версиями OpenSSL, не только 3.0+), но ключ остаётся в
// памяти: этому сервису не нужен RsaSigningKey из PEM-файла, только сырые
// модуль/экспонента (как их отдаёт JWKS) и сама подпись.
#pragma once

#include <stdexcept>
#include <string>
#include <vector>

#include <openssl/core_names.h>
#include <openssl/evp.h>
#include <openssl/rsa.h>

#include "nlohmann/json.hpp"
#include "util/base64.hpp"

class TestRsaKey {
public:
    TestRsaKey() {
        EVP_PKEY_CTX* ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, nullptr);
        if (ctx == nullptr || EVP_PKEY_keygen_init(ctx) <= 0 ||
            EVP_PKEY_CTX_set_rsa_keygen_bits(ctx, 2048) <= 0) {
            if (ctx != nullptr) EVP_PKEY_CTX_free(ctx);
            throw std::runtime_error("TestRsaKey: не удалось инициализировать генерацию ключа");
        }
        if (EVP_PKEY_keygen(ctx, &pkey_) <= 0) {
            EVP_PKEY_CTX_free(ctx);
            throw std::runtime_error("TestRsaKey: не удалось сгенерировать ключ");
        }
        EVP_PKEY_CTX_free(ctx);
    }

    ~TestRsaKey() {
        if (pkey_ != nullptr) EVP_PKEY_free(pkey_);
    }

    TestRsaKey(const TestRsaKey&) = delete;
    TestRsaKey& operator=(const TestRsaKey&) = delete;

    // Сырые big-endian байты — ровно формат, в котором jwks::Cache::refresh()
    // ожидает n/e после base64url-декодирования (см. util/jwks.cpp).
    std::vector<unsigned char> modulus() const { return bn_param(OSSL_PKEY_PARAM_RSA_N); }
    std::vector<unsigned char> exponent() const { return bn_param(OSSL_PKEY_PARAM_RSA_E); }

    // RSASSA-PKCS1-v1_5 SHA-256 — то же самое, что проверяет
    // crypto::rsa_sha256_verify (RS256, обычный PKCS1-padding по умолчанию
    // для RSA в EVP_DigestSign, отдельно PSS не запрашивается).
    std::vector<unsigned char> sign(const std::string& data) const {
        EVP_MD_CTX* mdctx = EVP_MD_CTX_new();
        if (mdctx == nullptr) throw std::runtime_error("TestRsaKey::sign: EVP_MD_CTX_new failed");

        std::vector<unsigned char> sig;
        size_t sig_len = 0;
        bool ok = EVP_DigestSignInit(mdctx, nullptr, EVP_sha256(), nullptr, pkey_) == 1 &&
                  EVP_DigestSign(mdctx, nullptr, &sig_len,
                                 reinterpret_cast<const unsigned char*>(data.data()), data.size()) == 1;
        if (ok) {
            sig.resize(sig_len);
            ok = EVP_DigestSign(mdctx, sig.data(), &sig_len,
                                 reinterpret_cast<const unsigned char*>(data.data()), data.size()) == 1;
            sig.resize(sig_len);
        }
        EVP_MD_CTX_free(mdctx);
        if (!ok) throw std::runtime_error("TestRsaKey::sign: подпись не удалась");
        return sig;
    }

private:
    std::vector<unsigned char> bn_param(const char* name) const {
        BIGNUM* bn = nullptr;
        if (EVP_PKEY_get_bn_param(pkey_, name, &bn) != 1 || bn == nullptr) {
            throw std::runtime_error(std::string("TestRsaKey: не удалось прочитать параметр ") + name);
        }
        std::vector<unsigned char> out(static_cast<size_t>(BN_num_bytes(bn)));
        BN_bn2bin(bn, out.data());
        BN_free(bn);
        return out;
    }

    EVP_PKEY* pkey_ = nullptr;
};

// Собирает access-токен вручную (header.payload.signature, base64url без
// padding) — тот же формат, что issue_access_token в google-auth, но здесь
// не нужен весь auth-сервис ради одного тестового токена.
inline std::string make_test_jwt(const TestRsaKey& key, const std::string& kid,
                                  nlohmann::json payload) {
    nlohmann::json header = {{"alg", "RS256"}, {"typ", "JWT"}, {"kid", kid}};
    std::string signing_input = b64::encode(header.dump()) + "." + b64::encode(payload.dump());
    std::string signature = b64::encode(key.sign(signing_input));
    return signing_input + "." + signature;
}

// GET /.well-known/jwks.json — ровно то, что реально отдаёт google-auth (см.
// его auth.cpp), только с тестовым ключом.
inline std::string make_test_jwks(const TestRsaKey& key, const std::string& kid) {
    nlohmann::json jwk = {
        {"kty", "RSA"}, {"kid", kid},          {"use", "sig"},
        {"alg", "RS256"}, {"n", b64::encode(key.modulus())}, {"e", b64::encode(key.exponent())},
    };
    return nlohmann::json{{"keys", nlohmann::json::array({jwk})}}.dump();
}
