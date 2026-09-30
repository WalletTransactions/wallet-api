#include "provisioning.hpp"

#include <optional>

#include "util/uuid.hpp"

namespace provisioning {

namespace {

struct Membership {
    std::string ledger_id;
    std::string role;
};

// nullopt — у этого пользователя ещё нет ни одного леджера.
std::optional<Membership> find_existing_ledger(db::Database& db, const std::string& user_id) {
    auto res = db.exec(
        "SELECT ledger_id, role FROM ledger_member WHERE user_id = $1 ORDER BY joined_at LIMIT 1",
        {user_id});
    if (res.rows.empty()) return std::nullopt;
    return Membership{res.rows[0].fields.at(0), res.rows[0].fields.at(1)};
}

std::string create_ledger_owned_by(db::Database& db, const std::string& user_id,
                                    const std::string& name) {
    std::string ledger_id = uuidgen::v4();
    auto tx = db.begin_transaction();
    // change_stream — раньше ledger, тот же приём, что и в
    // wallet-api/schema/table/change_stream.sql: поток и сам леджер — одна
    // сущность, разнесённая по двум таблицам с общим id.
    tx.exec("INSERT INTO change_stream (id, kind) VALUES ($1, 'ledger')", {ledger_id});
    tx.exec("INSERT INTO ledger (id, name) VALUES ($1, $2)", {ledger_id, name});
    tx.exec("INSERT INTO ledger_member (ledger_id, user_id, role) VALUES ($1, $2, 'owner')",
            {ledger_id, user_id});
    tx.commit();
    return ledger_id;
}

Membership ensure_membership(db::Database& db, const std::string& user_id, const std::string& email) {
    // Кэш claim'ов из токена — email легитимно устаревает (см. app_user.sql),
    // подтягиваем на каждый вызов, как и upsert_user в google-auth. Пустой —
    // не затираем: у токена Telegram-бота email нет вовсе.
    db.exec("INSERT INTO app_user (id, email) VALUES ($1, $2) "
            "ON CONFLICT (id) DO UPDATE SET email = "
            "CASE WHEN EXCLUDED.email = '' THEN app_user.email ELSE EXCLUDED.email END",
            {user_id, email});

    auto existing = find_existing_ledger(db, user_id);
    return existing ? *existing : Membership{create_ledger_owned_by(db, user_id, "Мой кошелёк"), "owner"};
}

} // namespace

std::string ensure_personal_ledger(db::Database& db, const std::string& user_id,
                                    const std::string& email) {
    return ensure_membership(db, user_id, email).ledger_id;
}

Identity ensure_identity(db::Database& db, const std::string& user_id, const std::string& email,
                          const std::string& device_id, const std::string& device_name,
                          const std::string& platform) {
    Membership membership = ensure_membership(db, user_id, email);
    Identity identity{membership.ledger_id, membership.role};

    // last_seen_at/platform/name обновляются на каждый вызов — устройство,
    // которое давно не появлялось, не должно выглядеть недавно активным;
    // COALESCE на name — пустое имя в конкретном запросе не должно стирать
    // ранее известное человекочитаемое.
    db.exec(
        "INSERT INTO device (id, user_id, ledger_id, platform, name, last_seen_at) "
        "VALUES ($1, $2, $3, $4, $5, now()) "
        "ON CONFLICT (id) DO UPDATE SET "
        "  last_seen_at = now(), platform = EXCLUDED.platform, "
        "  name = CASE WHEN EXCLUDED.name = '' THEN device.name ELSE EXCLUDED.name END",
        {device_id, user_id, identity.ledger_id, platform, device_name});

    return identity;
}

} // namespace provisioning
