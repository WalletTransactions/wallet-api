#include "util/crypto.hpp"

#include <stdexcept>

#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/rsa.h>

namespace crypto {

namespace {

// DER-длина в определённой форме (definite form, ASN.1 BER/DER).
std::string der_length(size_t len) {
    if (len < 0x80) {
        return std::string(1, static_cast<char>(len));
    }
    std::vector<unsigned char> bytes;
    size_t l = len;
    while (l > 0) {
        bytes.insert(bytes.begin(), static_cast<unsigned char>(l & 0xFF));
        l >>= 8;
    }
    std::string out;
    out += static_cast<char>(0x80 | bytes.size());
    out.append(reinterpret_cast<char*>(bytes.data()), bytes.size());
    return out;
}

// Минимальный DER-кодировщик INTEGER для неотрицательного big-endian числа.
std::string der_integer(std::vector<unsigned char> v) {
    size_t skip = 0;
    while (skip + 1 < v.size() && v[skip] == 0x00) ++skip;
    v.erase(v.begin(), v.begin() + skip);
    if (v.empty()) v.push_back(0x00);
    if (v[0] & 0x80) v.insert(v.begin(), 0x00); // не даём спутать со знаковым числом
    std::string out;
    out += static_cast<char>(0x02); // тег INTEGER
    out += der_length(v.size());
    out.append(reinterpret_cast<char*>(v.data()), v.size());
    return out;
}

// Кодирует RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent
// INTEGER } (PKCS#1, RFC 8017 A.1.1) прямо из сырых n/e JWK — именно то, что
// ожидает d2i_RSAPublicKey. Специально не используем RSA_set0_key/
// OSSL_PARAM_BLD: их доступность и поведение отличаются между OpenSSL 1.1 и
// 3.x, а d2i_RSAPublicKey + EVP_PKEY_assign_RSA стабильны в обеих ветках.
std::vector<unsigned char> encode_rsa_public_key_der(const std::vector<unsigned char>& n,
                                                      const std::vector<unsigned char>& e) {
    std::string content = der_integer(n) + der_integer(e);
    std::string seq;
    seq += static_cast<char>(0x30); // тег SEQUENCE
    seq += der_length(content.size());
    seq += content;
    return std::vector<unsigned char>(seq.begin(), seq.end());
}

} // namespace

std::vector<unsigned char> sha256(const std::string& data) {
    std::vector<unsigned char> out(EVP_MAX_MD_SIZE);
    unsigned int len = 0;
    EVP_Digest(data.data(), data.size(), out.data(), &len, EVP_sha256(), nullptr);
    out.resize(len);
    return out;
}

std::vector<unsigned char> random_bytes(std::size_t n) {
    std::vector<unsigned char> out(n);
    if (RAND_bytes(out.data(), static_cast<int>(n)) != 1) {
        throw std::runtime_error("RAND_bytes: не удалось получить случайные байты у ОС/OpenSSL");
    }
    return out;
}

bool rsa_sha256_verify(const std::vector<unsigned char>& n,
                        const std::vector<unsigned char>& e,
                        const std::string& signed_data,
                        const std::vector<unsigned char>& signature) {
    auto der = encode_rsa_public_key_der(n, e);
    const unsigned char* p = der.data();
    RSA* rsa = d2i_RSAPublicKey(nullptr, &p, static_cast<long>(der.size()));
    if (!rsa) return false;

    EVP_PKEY* pkey = EVP_PKEY_new();
    if (!pkey || !EVP_PKEY_assign_RSA(pkey, rsa)) {
        RSA_free(rsa);
        if (pkey) EVP_PKEY_free(pkey);
        return false;
    }
    // С этого момента pkey владеет rsa — RSA_free отдельно вызывать нельзя.

    bool ok = false;
    EVP_MD_CTX* ctx = EVP_MD_CTX_new();
    if (ctx != nullptr &&
        EVP_DigestVerifyInit(ctx, nullptr, EVP_sha256(), nullptr, pkey) == 1 &&
        EVP_DigestVerifyUpdate(ctx, signed_data.data(), signed_data.size()) == 1) {
        ok = EVP_DigestVerifyFinal(ctx, signature.data(), signature.size()) == 1;
    }
    if (ctx != nullptr) EVP_MD_CTX_free(ctx);
    EVP_PKEY_free(pkey); // освобождает и rsa

    return ok;
}

} // namespace crypto
