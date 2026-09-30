#include "util/jwt.hpp"

#include <chrono>

#include "util/base64.hpp"
#include "util/crypto.hpp"

using nlohmann::json;

namespace jwt {

namespace {

std::vector<std::string> split_token(const std::string& token) {
    std::vector<std::string> parts;
    size_t start = 0;
    for (size_t i = 0; i <= token.size(); ++i) {
        if (i == token.size() || token[i] == '.') {
            parts.push_back(token.substr(start, i - start));
            start = i + 1;
        }
    }
    return parts;
}

uint64_t now_epoch() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::seconds>(
                                      std::chrono::system_clock::now().time_since_epoch())
                                      .count());
}

std::optional<json> parse_json_part(const std::string& b64_part) {
    try {
        auto bytes = b64::decode(b64_part);
        std::string text(bytes.begin(), bytes.end());
        return json::parse(text);
    } catch (const std::exception&) {
        return std::nullopt;
    }
}

} // namespace

// В отличие от одноимённой функции в google-auth (там она общая с
// проверкой id_token Google, и exp там сознательно не проверяется — см. её
// комментарий), здесь только один потребитель — наши собственные
// access-токены, поэтому exp можно и нужно проверять прямо тут.
std::optional<json> verify_rs256(const std::string& token, const std::vector<unsigned char>& n,
                                  const std::vector<unsigned char>& e) {
    auto parts = split_token(token);
    if (parts.size() != 3) return std::nullopt;

    std::string signing_input = parts[0] + "." + parts[1];
    std::vector<unsigned char> sig;
    try {
        sig = b64::decode(parts[2]);
    } catch (const std::exception&) {
        return std::nullopt;
    }

    if (!crypto::rsa_sha256_verify(n, e, signing_input, sig)) return std::nullopt;

    auto payload = parse_json_part(parts[1]);
    if (!payload) return std::nullopt;

    if (payload->contains("exp")) {
        try {
            if (payload->at("exp").get<uint64_t>() <= now_epoch()) return std::nullopt;
        } catch (const std::exception&) {
            return std::nullopt;
        }
    }
    return payload;
}

std::optional<std::string> peek_kid(const std::string& token) {
    auto parts = split_token(token);
    if (parts.empty()) return std::nullopt;

    auto header = parse_json_part(parts[0]);
    if (!header || !header->contains("kid")) return std::nullopt;

    try {
        return header->at("kid").get<std::string>();
    } catch (const std::exception&) {
        return std::nullopt;
    }
}

} // namespace jwt
