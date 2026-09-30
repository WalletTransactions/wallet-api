// Тот же харнесс, что в ../tests/test_framework.hpp — независимая копия
// (не общий include), тот же принцип, что уже описан в
// ../tests/README.md: сервисы/тестовые каталоги друг от друга независимы.
#pragma once

#include <iostream>
#include <string>
#include <vector>

namespace testing {

struct TestCase {
    std::string name;
    void (*fn)();
};

inline std::vector<TestCase>& registry() {
    static std::vector<TestCase> tests;
    return tests;
}

struct Registrar {
    Registrar(const char* name, void (*fn)()) { registry().push_back({name, fn}); }
};

inline int& failed_checks() {
    static int n = 0;
    return n;
}

inline std::string& current_test_name() {
    static std::string name;
    return name;
}

// Сообщения упавших CHECK/REQUIRE ТЕКУЩЕГО теста — очищается в test_main.cpp
// перед каждым тестом, читается им же после, чтобы положить в JUnit XML
// (см. main() — <failure> на тест, не просто общий счётчик).
inline std::vector<std::string>& current_test_failures() {
    static std::vector<std::string> messages;
    return messages;
}

inline void report_failure(const std::string& expr, const char* file, int line) {
    ++failed_checks();
    current_test_failures().push_back(std::string(file) + ":" + std::to_string(line) + ": " + expr);
    std::cerr << "  [FAIL] " << current_test_name() << " (" << file << ":" << line << "): " << expr
               << "\n";
}

struct RequireFailed {};

} // namespace testing

#define TEST(name)                                                              \
    static void name();                                                        \
    static ::testing::Registrar registrar_##name(#name, name);                  \
    static void name()

#define CHECK(cond)                                                             \
    do {                                                                        \
        if (!(cond)) ::testing::report_failure(#cond, __FILE__, __LINE__);      \
    } while (0)

#define CHECK_EQ(a, b)                                                          \
    do {                                                                        \
        if (!((a) == (b)))                                                      \
            ::testing::report_failure(#a " == " #b, __FILE__, __LINE__);        \
    } while (0)

#define CHECK_THROWS(expr)                                                      \
    do {                                                                        \
        bool threw = false;                                                     \
        try {                                                                   \
            (void)(expr);                                                       \
        } catch (...) {                                                         \
            threw = true;                                                       \
        }                                                                       \
        if (!threw) ::testing::report_failure(#expr " should throw", __FILE__, __LINE__); \
    } while (0)

#define REQUIRE(cond)                                                           \
    do {                                                                        \
        if (!(cond)) {                                                          \
            ::testing::report_failure(#cond, __FILE__, __LINE__);               \
            throw ::testing::RequireFailed{};                                   \
        }                                                                       \
    } while (0)
