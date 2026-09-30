// Провижининг одного леджера ("иконка" + валюта + два счёта, category и
// wallet) НАСТОЯЩИМ протоколом синка (POST /sync/blobs, потом POST
// /sync/push) — тем же путём, что и реальный клиент, не короткий путь через
// SQL напрямую (тот доступен только интеграционным тестам с локальным
// db::Database, у k6 есть только HTTP, см. wallet-api/tests_integration/
// fixture.hpp::make_reference_icon про этот короткий путь и почему он здесь
// недоступен).
//
// Один раз НА ЛЕДЖЕР, не на каждую итерацию нагрузки (см. setup() в
// scenario_push_*.js) — план счетов реальные устройства не пересоздают на
// каждый синк, а дальше просто дописывают новые операции (см.
// pushOneOperation ниже) — та же картина трафика, что и в проде.
//
// uuid счетов/валюты/иконки — ДЕТЕРМИНИРОВАННЫЕ (см. deterministicUuid), не
// {@link uuidv4}: реальная находка (лог `POST /sync/push`, 2026-09-13,
// сценарий same_ledger — provisionLedger() зовётся заново при КАЖДОМ `k6 run`
// тем же токеном из уже сминченного mint_tokens.sh, т.е. на уже
// провижененный леджер) — со случайным uuid повторный прогон пытался
// вставить ВТОРУЮ строку icon с тем же именем 'loadtest-icon' в тот же
// леджер и падал `23505 uq_icon_name_ledger` (та же судьба ждала бы currency
// на uq_currency_name_ledger, account — на uq_account_name). Перезаписывать
// СУЩЕСТВУЮЩУЮ строку по имени (natural-key upsert, как currency_pair_rate,
// но здесь есть FK-зависимые: currency.icon_uuid/account.icon_uuid) на
// сервере ОПАСНО — Postgres не даёт молча переставить PK строки, на которую
// уже ссылаются другие (UPDATE ... SET uuid = ... упал бы 23503 при первом
// же реальном использовании, см. обсуждение при этой правке). Правильный
// уровень фикса — здесь: тот же uuid на повторный прогон ТОГО ЖЕ токена
// заводит push_batch на обычный, безопасный `ON CONFLICT (uuid) DO UPDATE`
// (та же физическая строка обновляется на месте, никакой natural-key
// коллизии вообще не возникает) — токен стабилен между прогонами k6 против
// уже сминченного data/*.json (переминчен — другой sub → другой леджер →
// другие производные uuid, тоже корректно).
import crypto from 'k6/crypto';
import http from 'k6/http';

export function uuidv4() {
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
        var r = (Math.random() * 16) | 0,
            v = c === 'x' ? r : (r & 0x3) | 0x8;
        return v.toString(16);
    });
}

// См. комментарий над импортами — тот же (token, seed) всегда даёт тот же
// "uuid". НЕ настоящий UUID v4 (версия/variant биты не выставлены нарочно) —
// Postgres-колонке типа uuid это безразлично, а вот стабильность для
// повторного запуска здесь важнее случайности.
function deterministicUuid(seed) {
    const hex = crypto.sha256(seed, 'hex');
    return (
        hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16) + '-' +
        hex.slice(16, 20) + '-' + hex.slice(20, 32)
    );
}

function authHeaders(token) {
    return { headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' } };
}

export function provisionLedger(baseUrl, token) {
    const blobRes = http.post(`${baseUrl}/sync/blobs`, 'loadtest-icon-bytes', authHeaders(token));
    if (blobRes.status !== 200) {
        throw new Error(`setup: POST /sync/blobs -> ${blobRes.status}: ${blobRes.body}`);
    }
    const sha256 = JSON.parse(blobRes.body).sha256;

    const iconUuid = deterministicUuid(token + ':loadtest-icon');
    const currencyUuid = deterministicUuid(token + ':loadtest-currency');
    const categoryUuid = deterministicUuid(token + ':loadtest-category');
    const walletUuid = deterministicUuid(token + ':loadtest-wallet');

    const changes = {
        icon: [{ uuid: iconUuid, name: 'loadtest-icon', content_sha256: sha256, icon_type: 0 }],
        currency: [{
            // iso_code — тоже детерминированный (первые 2 hex-символа общего
            // хэша % 100, а не Math.random()) — тем же доводом: реальной
            // коллизии тут взяться было неоткуда (единственная валюта этого
            // леджера, uq_currency_iso_ledger её не с чем спутать), но
            // случайный iso_code на КАЖДЫЙ повторный прогон делал бы
            // UPDATE...SET iso_code=EXCLUDED.iso_code бессмысленно шумным.
            uuid: currencyUuid, name: 'Loadtest',
            iso_code: 'L' + (parseInt(deterministicUuid(token + ':loadtest-iso').slice(0, 2), 16) % 100),
            icon_uuid: iconUuid, symbol: 'L', precision: 2,
        }],
        account: [
            { uuid: categoryUuid, name: 'Loadtest category', comment: '', icon_uuid: iconUuid, is_archived: false, system_kind: 0, kind: 0 },
            { uuid: walletUuid, name: 'Loadtest wallet', comment: '', icon_uuid: iconUuid, is_archived: false, system_kind: 0, kind: 0 },
        ],
        account_operating: [{ uuid: walletUuid, currency_uuid: currencyUuid }],
    };

    const pushRes = http.post(
        `${baseUrl}/sync/push`,
        JSON.stringify({ batch_id: uuidv4(), changes }),
        authHeaders(token)
    );
    if (pushRes.status !== 200) {
        throw new Error(`setup: POST /sync/push -> ${pushRes.status}: ${pushRes.body}`);
    }

    return { categoryUuid: categoryUuid, walletUuid: walletUuid };
}

// batch_id — новый uuid на КАЖДЫЙ вызов (см. sync_repo.hpp про
// идемпотентность по batch_id: повтор того же id просто вернул бы старый
// ответ, не создал бы вторую операцию) — здесь это не повтор, а НОВАЯ
// операция, поэтому и batch_id, и operation.uuid каждый раз свои.
export function pushOneOperation(baseUrl, token, accounts) {
    const changes = {
        operation: [{
            uuid: uuidv4(),
            date: new Date().toISOString().slice(0, 19),
            acc_fr_uuid: accounts.categoryUuid,
            acc_to_uuid: accounts.walletUuid,
            amount: (Math.random() * 100).toFixed(2),
            comment: 'loadtest',
        }],
    };
    return http.post(
        `${baseUrl}/sync/push`,
        JSON.stringify({ batch_id: uuidv4(), changes }),
        authHeaders(token)
    );
}
