// Интеграционные тесты currency_pairs_repo (по прямому запросу пользователя
// — веб-аналог Android CurrencyPairListActivity/CurrencyPairRateListActivity/
// RateEditDialog: просмотр пар и их истории курса, добавление/изменение/
// удаление пары и её курса) против ЖИВОГО Postgres — тот же принцип, что и у
// test_push_batch.cpp/test_invites.cpp: собственная область видимости
// (Scope::ReferenceOrLedger — своя копия перекрывает общую) и next_seq/
// change_stream реально проверяются только на настоящей базе.
#include "currency_pairs_repo.hpp"

#include "fixture.hpp"
#include "nlohmann/json.hpp"
#include "test_framework.hpp"
#include "util/uuid.hpp"

TEST(create_pair_rejects_same_currency) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string cur = fixture::make_currency(*db, identity.ledger_id, icon);

    auto result = currency_pairs_repo::create_pair(*db, identity.ledger_id, cur, cur, 5);
    CHECK(result.error == currency_pairs_repo::CreatePairError::kSameCurrency);
}

TEST(create_pair_rejects_currency_not_visible_to_this_ledger) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    auto other = fixture::make_identity(*db); // другой леджер
    std::string icon = fixture::make_reference_icon(*db);
    std::string own_currency = fixture::make_currency(*db, identity.ledger_id, icon);
    // Приватная валюта ЧУЖОГО леджера — identity не должен её видеть вовсе.
    std::string foreign_currency = fixture::make_currency(*db, other.ledger_id, icon);

    auto result = currency_pairs_repo::create_pair(*db, identity.ledger_id, own_currency,
                                                     foreign_currency, 5);
    CHECK(result.error == currency_pairs_repo::CreatePairError::kQuoteNotFound);
}

TEST(create_pair_then_list_pairs_shows_it_as_own) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string base = fixture::make_currency(*db, identity.ledger_id, icon);
    std::string quote = fixture::make_currency(*db, "", icon); // общая валюта

    auto created = currency_pairs_repo::create_pair(*db, identity.ledger_id, base, quote, 4);
    REQUIRE(created.error == currency_pairs_repo::CreatePairError::kOk);
    CHECK_EQ(created.pair.value("precision", -1), 4);
    CHECK_EQ(created.pair.value("is_own", false), true);
    std::string pair_uuid = created.pair.at("uuid").get<std::string>();

    auto pairs = currency_pairs_repo::list_pairs(*db, identity.ledger_id);
    bool found = false;
    for (const auto& p : pairs) {
        if (p.at("uuid").get<std::string>() == pair_uuid) found = true;
    }
    CHECK(found);
}

TEST(create_pair_rejects_duplicate_symbol_for_the_same_ledger) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string base = fixture::make_currency(*db, identity.ledger_id, icon);
    std::string quote = fixture::make_currency(*db, identity.ledger_id, icon);

    auto first = currency_pairs_repo::create_pair(*db, identity.ledger_id, base, quote, 5);
    REQUIRE(first.error == currency_pairs_repo::CreatePairError::kOk);

    // Второй раз — та же пара (тот же символ) для того же леджера: 23505 на
    // uq_currency_pair_symbol_ledger, db::QueryError долетает как есть (см.
    // currency_pairs_repo.hpp, create_pair — намеренно не ловится внутри).
    bool caught_expected_sqlstate = false;
    try {
        currency_pairs_repo::create_pair(*db, identity.ledger_id, base, quote, 5);
    } catch (const db::QueryError& e) {
        caught_expected_sqlstate = e.sqlstate == "23505";
    }
    CHECK(caught_expected_sqlstate);
}

TEST(update_pair_precision_only_affects_own_pair) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    auto other = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string base = fixture::make_currency(*db, identity.ledger_id, icon);
    std::string quote = fixture::make_currency(*db, identity.ledger_id, icon);

    auto created = currency_pairs_repo::create_pair(*db, identity.ledger_id, base, quote, 5);
    REQUIRE(created.error == currency_pairs_repo::CreatePairError::kOk);
    std::string pair_uuid = created.pair.at("uuid").get<std::string>();

    // Чужой леджер не может её править — 0 совпавших строк, nullopt.
    auto foreign_attempt =
        currency_pairs_repo::update_pair_precision(*db, other.ledger_id, pair_uuid, 2);
    CHECK(!foreign_attempt.has_value());

    auto updated = currency_pairs_repo::update_pair_precision(*db, identity.ledger_id, pair_uuid, 2);
    REQUIRE(updated.has_value());
    CHECK_EQ(updated->value("precision", -1), 2);
}

TEST(upsert_rate_on_same_date_updates_in_place_not_duplicates) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string base = fixture::make_currency(*db, identity.ledger_id, icon);
    std::string quote = fixture::make_currency(*db, identity.ledger_id, icon);
    auto created = currency_pairs_repo::create_pair(*db, identity.ledger_id, base, quote, 5);
    REQUIRE(created.error == currency_pairs_repo::CreatePairError::kOk);
    std::string pair_uuid = created.pair.at("uuid").get<std::string>();

    auto first = currency_pairs_repo::upsert_rate(*db, identity.ledger_id, pair_uuid,
                                                   "2026-01-15", "1.2000000000");
    REQUIRE(first.error == currency_pairs_repo::RateWriteError::kOk);
    std::string rate_uuid = first.rate.at("uuid").get<std::string>();

    auto second = currency_pairs_repo::upsert_rate(*db, identity.ledger_id, pair_uuid,
                                                    "2026-01-15", "1.3300000000");
    REQUIRE(second.error == currency_pairs_repo::RateWriteError::kOk);
    // Тот же uuid — правка существующего курса, не вторая строка (тот же
    // принцип, что WalletDbCRUD.InsertOrReplaceRate на клиенте).
    CHECK_EQ(second.rate.at("uuid").get<std::string>(), rate_uuid);
    CHECK_EQ(second.rate.at("rate").get<std::string>(), std::string("1.3300000000"));

    auto rates = currency_pairs_repo::list_rates(*db, identity.ledger_id, pair_uuid, "", "");
    REQUIRE(rates.has_value());
    CHECK_EQ(rates->size(), std::size_t(1));
}

TEST(own_rate_coexists_with_and_overrides_reference_rate_on_same_date) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    // Общая пара (ledger_id NULL) — заведена напрямую SQL, тем же приёмом,
    // что общая иконка/валюта: create_pair всегда создаёт СВОЮ пару (см. её
    // комментарий), общую в тесте иначе не получить.
    std::string base = fixture::make_currency(*db, "", icon);
    std::string quote = fixture::make_currency(*db, "", icon);
    std::string pair_uuid = uuidgen::v4();
    {
        auto seq = db->exec("SELECT next_seq('00000000-0000-0000-0000-000000000001')");
        db->exec("INSERT INTO currency_pair (uuid, seq, symbol, base_currency_uuid, "
                  "quote_currency_uuid, \"precision\") VALUES ($1,$2,$3,$4,$5,$6)",
                  {pair_uuid, seq.rows.at(0).fields.at(0), "REFPAIR-" + pair_uuid, base, quote, "5"});
    }

    // Общий курс на дату X — тоже напрямую SQL (ledger_id NULL).
    {
        auto seq = db->exec("SELECT next_seq('00000000-0000-0000-0000-000000000001')");
        db->exec("INSERT INTO currency_pair_rate (uuid, seq, currency_pair_uuid, date, rate) "
                  "VALUES ($1,$2,$3,'2026-02-01',$4)",
                  {uuidgen::v4(), seq.rows.at(0).fields.at(0), pair_uuid, "10.0000000000"});
    }

    // Пара видна этому леджеру (она общая) — upsert_rate обязан пройти, а не
    // вернуть kPairNotFound.
    auto own_rate = currency_pairs_repo::upsert_rate(*db, identity.ledger_id, pair_uuid,
                                                      "2026-02-01", "11.5000000000");
    REQUIRE(own_rate.error == currency_pairs_repo::RateWriteError::kOk);

    // list_rates для ЭТОГО леджера — своя строка перекрывает общую на ту же
    // дату (одна строка, значение — своё).
    auto rates = currency_pairs_repo::list_rates(*db, identity.ledger_id, pair_uuid, "", "");
    REQUIRE(rates.has_value());
    REQUIRE(rates->size() == std::size_t(1));
    CHECK_EQ(rates->at(0).at("rate").get<std::string>(), std::string("11.5000000000"));
    CHECK_EQ(rates->at(0).value("is_own", false), true);

    // Другой леджер, не трогавший эту пару, видит ОБЩИЙ курс как есть.
    auto other = fixture::make_identity(*db);
    auto other_rates = currency_pairs_repo::list_rates(*db, other.ledger_id, pair_uuid, "", "");
    REQUIRE(other_rates.has_value());
    REQUIRE(other_rates->size() == std::size_t(1));
    CHECK_EQ(other_rates->at(0).at("rate").get<std::string>(), std::string("10.0000000000"));
    CHECK_EQ(other_rates->at(0).value("is_own", true), false);
}

TEST(delete_rate_removes_only_own_row_not_reference) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string base = fixture::make_currency(*db, identity.ledger_id, icon);
    std::string quote = fixture::make_currency(*db, identity.ledger_id, icon);
    auto created = currency_pairs_repo::create_pair(*db, identity.ledger_id, base, quote, 5);
    REQUIRE(created.error == currency_pairs_repo::CreatePairError::kOk);
    std::string pair_uuid = created.pair.at("uuid").get<std::string>();

    // Своего курса на эту дату ещё нет вовсе — нечего удалять.
    CHECK(!currency_pairs_repo::delete_rate(*db, identity.ledger_id, pair_uuid, "2026-03-01"));

    REQUIRE(currency_pairs_repo::upsert_rate(*db, identity.ledger_id, pair_uuid, "2026-03-01",
                                              "2.0000000000")
                .error == currency_pairs_repo::RateWriteError::kOk);
    CHECK(currency_pairs_repo::delete_rate(*db, identity.ledger_id, pair_uuid, "2026-03-01"));

    auto rates = currency_pairs_repo::list_rates(*db, identity.ledger_id, pair_uuid, "", "");
    REQUIRE(rates.has_value());
    CHECK_EQ(rates->size(), std::size_t(0));
}

TEST(delete_pair_cascades_to_its_own_rates) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string base = fixture::make_currency(*db, identity.ledger_id, icon);
    std::string quote = fixture::make_currency(*db, identity.ledger_id, icon);
    auto created = currency_pairs_repo::create_pair(*db, identity.ledger_id, base, quote, 5);
    REQUIRE(created.error == currency_pairs_repo::CreatePairError::kOk);
    std::string pair_uuid = created.pair.at("uuid").get<std::string>();

    REQUIRE(currency_pairs_repo::upsert_rate(*db, identity.ledger_id, pair_uuid, "2026-04-01",
                                              "3.0000000000")
                .error == currency_pairs_repo::RateWriteError::kOk);

    CHECK(currency_pairs_repo::delete_pair(*db, identity.ledger_id, pair_uuid));

    // Пара мягко удалена — не видна вовсе, list_rates отвечает nullopt (тот
    // же смысл, что и "пара не найдена"), не пустым списком.
    CHECK(!currency_pairs_repo::find_pair(*db, identity.ledger_id, pair_uuid).has_value());
    CHECK(!currency_pairs_repo::list_rates(*db, identity.ledger_id, pair_uuid, "", "").has_value());

    // Курс тоже мягко удалён — проверяем напрямую в базе, раз list_rates
    // теперь ничего не отдаёт по этой (уже невидимой) паре.
    auto row = db->exec("SELECT deleted_at IS NOT NULL FROM currency_pair_rate "
                         "WHERE currency_pair_uuid = $1",
                         {pair_uuid});
    REQUIRE(row.rows.size() == std::size_t(1));
    CHECK_EQ(row.rows.at(0).fields.at(0), std::string("t"));

    // Повторное удаление уже удалённой пары — не находит ничего, false.
    CHECK(!currency_pairs_repo::delete_pair(*db, identity.ledger_id, pair_uuid));
}
