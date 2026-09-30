#include "invites_repo.hpp"

#include "util/crypto.hpp"
#include "util/hex.hpp"
#include "util/uuid.hpp"

namespace invites_repo {

namespace {

// hex(sha256(raw)) — тот же приём, что blob.cpp считает sha256 загруженного
// содержимого (crypto::sha256 отдаёт vector<unsigned char>, hex::encode
// принимает std::string байт).
std::string hash_token(const std::string& raw_token) {
    auto digest = crypto::sha256(raw_token);
    return hex::encode(std::string(reinterpret_cast<const char*>(digest.data()), digest.size()));
}

// ISO-8601 UTC с "Z" — Postgres-дефолтный ::text timestamptz даёт
// "2026-09-09 10:23:45.123456+00" (пробел вместо "T", смещение вместо "Z",
// зависит от TimeZone GUC сессии); to_char с AT TIME ZONE 'UTC' даёт
// одинаковый, предсказуемый формат независимо от настроек сессии.
constexpr const char* kIso8601Utc = "TO_CHAR(%s AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')";

std::string iso_expr(const std::string& column) {
    std::string out = kIso8601Utc;
    out.replace(out.find("%s"), 2, column);
    return out;
}

} // namespace

std::optional<Membership> find_membership(db::Database& db, const std::string& user_id) {
    // ORDER BY/LIMIT — на случай будущего смягчения "один леджер на
    // пользователя" (см. org/docs/TODO_mobile_sync.md, п. 9.3, открытый
    // вопрос): пока инвариант держится, второй строки не бывает, но если
    // однажды появится, детерминированный выбор лучше произвольного.
    auto res = db.exec(
        "SELECT ledger_id, role FROM ledger_member WHERE user_id = $1 ORDER BY joined_at LIMIT 1",
        {user_id});
    if (res.rows.empty()) return std::nullopt;
    Membership m;
    m.ledger_id = res.rows[0].fields.at(0);
    m.role = res.rows[0].fields.at(1);
    return m;
}

std::vector<MemberRow> list_members(db::Database& db, const std::string& ledger_id) {
    auto res = db.exec(
        "SELECT lm.user_id, COALESCE(au.email, ''), lm.role, " + iso_expr("lm.joined_at") +
            " FROM ledger_member lm "
            "JOIN app_user au ON au.id = lm.user_id "
            "WHERE lm.ledger_id = $1 "
            "ORDER BY (lm.role = 'owner') DESC, lm.joined_at",
        {ledger_id});
    std::vector<MemberRow> out;
    out.reserve(res.rows.size());
    for (const auto& row : res.rows) {
        MemberRow m;
        m.user_id = row.fields.at(0);
        m.email = row.fields.at(1);
        m.role = row.fields.at(2);
        m.joined_at = row.fields.at(3);
        out.push_back(std::move(m));
    }
    return out;
}

bool set_member_role(db::Database& db, const std::string& ledger_id, const std::string& user_id,
                      const std::string& new_role) {
    auto res = db.exec(
        "UPDATE ledger_member SET role = $3 "
        "WHERE ledger_id = $1 AND user_id = $2 AND role <> 'owner' "
        "RETURNING user_id",
        {ledger_id, user_id, new_role});
    return !res.rows.empty();
}

bool remove_member(db::Database& db, const std::string& ledger_id, const std::string& user_id) {
    auto res = db.exec(
        "DELETE FROM ledger_member WHERE ledger_id = $1 AND user_id = $2 AND role <> 'owner' "
        "RETURNING user_id",
        {ledger_id, user_id});
    return !res.rows.empty();
}

TransferStatus transfer_owner(db::Database& db, const std::string& ledger_id,
                               const std::string& caller_user_id,
                               const std::string& target_user_id) {
    auto tx = db.begin_transaction();

    // Порядок принципиален: сначала убеждаемся, что target вообще участник
    // ЭТОГО леджера, и только потом снимаем роль owner с caller — иначе
    // неудачный второй UPDATE оставил бы леджер вовсе без владельца до
    // отката транзакции (откат случится, но лучше не полагаться на него как
    // на единственную линию обороны там, где порядок избавляет от риска
    // вовсе).
    auto target_check =
        tx.exec("SELECT 1 FROM ledger_member WHERE ledger_id = $1 AND user_id = $2",
                {ledger_id, target_user_id});
    if (target_check.rows.empty()) {
        return TransferStatus::kTargetNotMember; // tx разрушится не закоммиченной — ROLLBACK
    }

    // См. wallet-api/schema/table/ledger_invite.sql / ledger.sql — ДВА
    // последовательных UPDATE, не один CASE: uq_ledger_member_owner —
    // частичный уникальный ИНДЕКС, не DEFERRABLE CONSTRAINT (частичный
    // индекс не может быть основой отложенного ограничения в Postgres), а
    // значит уникальность проверяется по каждой строке немедленно. Два
    // отдельных UPDATE подряд в одной транзакции не создают момента, когда
    // существуют два owner'а сразу.
    auto demote =
        tx.exec("UPDATE ledger_member SET role = 'member' "
                "WHERE ledger_id = $1 AND user_id = $2 AND role = 'owner' "
                "RETURNING user_id",
                {ledger_id, caller_user_id});
    if (demote.rows.empty()) {
        return TransferStatus::kCallerNotOwner; // ROLLBACK — кто-то другой уже перехватил владение
    }

    tx.exec("UPDATE ledger_member SET role = 'owner' WHERE ledger_id = $1 AND user_id = $2",
            {ledger_id, target_user_id});
    tx.commit();
    return TransferStatus::kOk;
}

CreatedInvite create_invite(db::Database& db, const std::string& ledger_id,
                             const std::string& created_by, const std::string& role,
                             int ttl_days) {
    // 32 случайных байта (256 бит) — заведомо больше, чем нужно для защиты
    // от перебора и от коллизии; hex — тот же приём, что content_sha256
    // (см. hex.hpp, зачем не base64: параметры exec() текстовые, но здесь
    // это не критично, hex просто последователен с остальным кодом).
    auto raw = crypto::random_bytes(32);
    std::string token = hex::encode(std::string(reinterpret_cast<const char*>(raw.data()), raw.size()));
    std::string hash = hash_token(token);

    auto res = db.exec(
        "INSERT INTO ledger_invite (ledger_id, role, token_hash, created_by, expires_at) "
        "VALUES ($1, $2, $3, $4, now() + make_interval(days => $5::int)) "
        "RETURNING id, " + iso_expr("created_at") + ", " + iso_expr("expires_at"),
        {ledger_id, role, hash, created_by, std::to_string(ttl_days)});

    CreatedInvite out;
    out.id = res.rows.at(0).fields.at(0);
    out.role = role;
    out.token = token;
    out.created_at = res.rows.at(0).fields.at(1);
    out.expires_at = res.rows.at(0).fields.at(2);
    return out;
}

std::vector<InviteSummary> list_active_invites(db::Database& db, const std::string& ledger_id) {
    auto res = db.exec(
        "SELECT id, role, " + iso_expr("created_at") + ", " + iso_expr("expires_at") +
            " FROM ledger_invite "
            "WHERE ledger_id = $1 AND used_at IS NULL AND revoked_at IS NULL AND expires_at > now() "
            "ORDER BY created_at DESC",
        {ledger_id});
    std::vector<InviteSummary> out;
    out.reserve(res.rows.size());
    for (const auto& row : res.rows) {
        InviteSummary s;
        s.id = row.fields.at(0);
        s.role = row.fields.at(1);
        s.created_at = row.fields.at(2);
        s.expires_at = row.fields.at(3);
        out.push_back(std::move(s));
    }
    return out;
}

bool revoke_invite(db::Database& db, const std::string& ledger_id, const std::string& invite_id) {
    auto res = db.exec(
        "UPDATE ledger_invite SET revoked_at = now() "
        "WHERE id = $1 AND ledger_id = $2 "
        "  AND used_at IS NULL AND revoked_at IS NULL AND expires_at > now() "
        "RETURNING id",
        {invite_id, ledger_id});
    return !res.rows.empty();
}

AcceptResult accept_invite(db::Database& db, const std::string& user_id, const std::string& email,
                            const std::string& raw_token) {
    // См. provisioning.cpp::ensure_identity — тот же принятый риск: два
    // одновременных accept ДВУХ РАЗНЫХ приглашений одним и тем же (новым)
    // user_id теоретически могут оба пройти проверку "ещё нет леджера" раньше,
    // чем один из них успеет вставить свою строку в ledger_member. Для
    // масштаба этого сервиса (штучные приглашения, не поток) риск принят
    // осознанно — блокировка на всё время accept усложнила бы код ради
    // исчезающе редкого случая.
    if (find_membership(db, user_id)) {
        return {AcceptStatus::kAlreadyHasLedger, {}, {}};
    }

    std::string hash = hash_token(raw_token);
    auto tx = db.begin_transaction();

    // app_user — ДО UPDATE ledger_invite: used_by ссылается на app_user(id)
    // (FK), а этот пользователь мог никогда раньше не обращаться к
    // wallet-api (чистый браузерный вход без единого /sync/* вызова).
    tx.exec("INSERT INTO app_user (id, email) VALUES ($1, $2) "
            "ON CONFLICT (id) DO UPDATE SET email = EXCLUDED.email",
            {user_id, email});

    // Guard WHERE used_at IS NULL AND revoked_at IS NULL AND expires_at > now()
    // — это и есть "одноразовая ссылка": вторая одновременная попытка тем же
    // токеном находит 0 строк здесь (Postgres сериализует конкурентные
    // UPDATE одной и той же строки), не создаёт вторую строку ledger_member.
    auto used = tx.exec(
        "UPDATE ledger_invite SET used_at = now(), used_by = $1 "
        "WHERE token_hash = $2 AND used_at IS NULL AND revoked_at IS NULL AND expires_at > now() "
        "RETURNING ledger_id, role",
        {user_id, hash});
    if (used.rows.empty()) {
        return {AcceptStatus::kInvalidOrExpired, {}, {}}; // ROLLBACK — app_user upsert не страшно потерять
    }

    AcceptResult out;
    out.status = AcceptStatus::kOk;
    out.ledger_id = used.rows.at(0).fields.at(0);
    out.role = used.rows.at(0).fields.at(1);

    tx.exec("INSERT INTO ledger_member (ledger_id, user_id, role) VALUES ($1, $2, $3)",
            {out.ledger_id, user_id, out.role});
    tx.commit();
    return out;
}

} // namespace invites_repo
