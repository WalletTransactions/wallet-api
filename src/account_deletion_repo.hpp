// Самообслуживание — "Удалить аккаунт" в настройках wallet-web (см. её
// README и google-auth/src/repo.hpp::delete_user, второй, независимый
// вызов на той стороне). Название файла намеренно НЕ "account_repo" — в
// схеме уже есть таблица `account` (кошельки/категории, см.
// wallet-api/schema/table/account.sql), и это про совсем другое: удаление
// профиля ПОЛЬЗОВАТЕЛЯ целиком, а не операция над этой таблицей.
#pragma once

#include <string>

#include "db.hpp"

namespace account_deletion_repo {

enum class DeleteStatus {
    kOk,
    // Пользователь — owner леджера (wallet-api/schema/table/ledger_member.sql),
    // в котором есть ДРУГИЕ участники. Жёсткое удаление такого леджера
    // (см. delete_own_account ниже) снесло бы данные, которыми пользуются
    // ОНИ, не только сам удаляющийся — отказываем, а не удаляем молча.
    // Передача владения (POST /api/ledger/transfer-owner, invites_repo.cpp)
    // или удаление лишних участников (DELETE /api/ledger/members/{id}) —
    // дело пользователя ДО удаления аккаунта, у обеих ручек уже есть свой UI.
    // На MVP ("один леджер на пользователя, свой, без иных участников",
    // provisioning.cpp::ensure_personal_ledger) этот путь недостижим —
    // защита на будущее, когда шаринг (Фаза 6) станет обычным делом.
    kOwnsSharedLedger,
};

// Жёсткое удаление ВСЕХ данных пользователя в этой базе — по прямому
// запросу пользователя ("полное жёсткое удаление", не мягкое/анонимизация):
//
//   1. Леджеры, где user_id — единственный участник (role='owner', никого
//      кроме него в ledger_member) — удаляются целиком: DELETE FROM ledger
//      каскадом сносит ledger_member/ledger_invite/device/account/
//      account_operating/operation/operation_link/sync_push_batch/currency/
//      currency_pair/currency_pair_rate ЭТОГО леджера (см. ON DELETE CASCADE
//      у каждой из них в wallet-api/schema/table/*.sql — ledger_id заведён как
//      единица владения именно ради того, чтобы это был один каскад, а не
//      десяток ручных DELETE в правильном порядке; ключи между таблицами
//      леджера на время транзакции отложены до COMMIT — см. миграцию
//      000025, иначе вложенный каскад падает на порядке). Следом — DELETE FROM
//      change_stream: ledger.id REFERENCES change_stream ON DELETE RESTRICT
//      (см. ledger.sql) — поток обязан пережить сам леджер РОВНО настолько,
//      сколько нужно, чтобы не остаться осиротевшим; к этому моменту леджер
//      уже удалён, RESTRICT больше не мешает.
//   2. DELETE FROM app_user — каскадом снимает ledger_member ЭТОГО user_id
//      в ЧУЖИХ леджерах (тех, где он был просто участником — это и есть
//      "выйти из общих кошельков", без затрагивания самих леджеров и данных
//      других людей в них), device (если что-то осталось) и ledger_invite
//      (created_by/used_by).
//
// Обе ветки — REFERENCES ... ON DELETE CASCADE ведёт с одной таблицы на
// другую (не наоборот), так что порядок "сначала леджеры, потом app_user"
// принципиален: app_user.id — цель FK ledger_member.user_id, а не источник,
// удаление app_user НЕ трогает данные ЛЕДЖЕРА (account/operation и т.п.) —
// это FK на ledger_id, не на user_id, поэтому шаг 1 обязателен отдельно.
//
// Одна транзакция на всё — либо всё пользовательское присутствие в базе
// исчезает разом, либо (kOwnsSharedLedger, до единого DELETE) не трогается
// вовсе.
DeleteStatus delete_own_account(db::Database& db, const std::string& user_id);

} // namespace account_deletion_repo
