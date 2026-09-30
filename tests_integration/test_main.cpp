// Тот же цикл, что в ../tests/test_main.cpp — независимая копия (см. её
// шапку в test_framework.hpp этого каталога). Если DATABASE_URL не задан,
// fixture::open() (см. fixture.hpp) бросит понятное исключение — оно
// попадёт сюда же, в обычный catch, и будет показано как FAIL с текстом
// причины на каждом тесте; отдельного preflight-выхода нарочно нет, чтобы
// не заводить второй, слегка другой main() ради одной проверки.
//
// От ../tests/test_main.cpp дальше отличается только JUnit XML (см. main()
// ниже) — тот же приём, что и wallet-report/tests_integration/test_main.cpp
// (BuildPlatform/jobs/wallet-api-integration-tests/Jenkinsfile, "junit"
// step): у ../tests/ своего Jenkins-job нет, JUnit XML там некому читать.
#include "test_framework.hpp"

#include <chrono>
#include <cstdlib>
#include <exception>
#include <fstream>

namespace {

// Минимальное экранирование для XML-атрибутов (имя теста/сообщение об
// ошибке — произвольный текст, включая кавычки/угловые скобки из CHECK_EQ).
std::string xml_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size());
    for (char c : s) {
        switch (c) {
            case '&': out += "&amp;"; break;
            case '<': out += "&lt;"; break;
            case '>': out += "&gt;"; break;
            case '"': out += "&quot;"; break;
            case '\'': out += "&apos;"; break;
            default: out += c;
        }
    }
    return out;
}

struct TestResult {
    std::string name;
    double seconds;
    std::vector<std::string> failures; // пусто — тест прошёл
};

} // namespace

int main() {
    int total = 0;
    int failed_tests = 0;
    std::vector<TestResult> results;
    double total_seconds = 0;

    for (auto& t : testing::registry()) {
        ++total;
        testing::current_test_name() = t.name;
        testing::current_test_failures().clear();
        int before = testing::failed_checks();

        const auto started = std::chrono::steady_clock::now();
        try {
            t.fn();
        } catch (const testing::RequireFailed&) {
            // Уже залогировано в report_failure() в момент самого REQUIRE.
        } catch (const std::exception& e) {
            testing::report_failure(std::string("необработанное исключение: ") + e.what(), __FILE__,
                                     __LINE__);
        } catch (...) {
            testing::report_failure("необработанное исключение неизвестного типа", __FILE__, __LINE__);
        }
        const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
        total_seconds += seconds;
        results.push_back(TestResult{t.name, seconds, testing::current_test_failures()});

        if (testing::failed_checks() == before) {
            std::cout << "  [ OK ] " << t.name << "\n";
        } else {
            ++failed_tests;
        }
    }

    std::cout << "\n" << total << " тестов, упало " << failed_tests << " ("
               << testing::failed_checks() << " проваленных проверок)\n";

    // JUnit XML — для Jenkins ("junit" step, стандартный Test Result UI:
    // тренд по билдам, список тестов, длительность каждого). Пишем только
    // если задан путь — ничего не меняется для локального запуска без
    // Jenkins (см. tests_integration/README.md).
    if (const char* xml_path = std::getenv("JUNIT_XML_PATH")) {
        std::ofstream f(xml_path);
        f << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n";
        f << "<testsuite name=\"wallet_api_integration_tests\" tests=\"" << total << "\" failures=\""
          << failed_tests << "\" time=\"" << total_seconds << "\">\n";
        for (const auto& r : results) {
            f << "  <testcase classname=\"wallet_api_integration_tests\" name=\""
              << xml_escape(r.name) << "\" time=\"" << r.seconds << "\"";
            if (r.failures.empty()) {
                f << "/>\n";
                continue;
            }
            f << ">\n";
            for (const auto& msg : r.failures) {
                f << "    <failure message=\"" << xml_escape(msg) << "\"/>\n";
            }
            f << "  </testcase>\n";
        }
        f << "</testsuite>\n";
    }

    return failed_tests == 0 ? 0 : 1;
}
