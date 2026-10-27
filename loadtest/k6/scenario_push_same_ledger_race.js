// Главный сценарий под "возможные дедлоки" (по прямому запросу) — по
// прямому запросу: НЕСКОЛЬКО устройств ОДНОГО аккаунта (см. TOKENS_FILE=
// data/same_ledger_tokens.json у mint_tokens.sh — один sub, разные
// device_id) пушут операции в ОДИН И ТОТ ЖЕ леджер ОДНОВРЕМЕННО. Это и есть
// офлайн-first многоустройство, ради которого весь sync-протокол вообще
// существует (org/docs/TODO_mobile_sync.md) — и единственная ситуация, где
// конкурентная запись реально пересекается на одних и тех же строках
// (change_stream, next_seq(ledger_id), account этого леджера), а не просто
// делит один пул соединений с чужими, никак не связанными запросами.
//
// batch_id и operation.uuid — новые на КАЖДЫЙ вызов (см. lib/provision.js) —
// значит любая ошибка здесь ПОДОЗРИТЕЛЬНА (это не "дубль", которому положено
// вернуть старый ответ, — настоящий конфликт/дедлок Postgres обязан либо
// сериализовать оба, либо явно откатить один с понятной ошибкой; зависшего
// или неверного состояния тут по протоколу не должно быть в принципе).
//
// Как читать: http_req_failed и p(95) duration — те же признаки "что-то
// не так", что у scenario_pool_saturation.js в wallet-report/loadtest,
// плюс — если весь прогон просто НЕ ЗАВЕРШИЛСЯ до k6-таймаута ("test
// context has been cancelled" на VU) — это уже прямой сигнал зависания на
// сервере, не статистика по latency.
import { check } from 'k6';
import { tokens, pickToken } from './lib/tokens.js';
import { provisionLedger, pushOneOperation } from './lib/provision.js';
import { SUMMARY_OPTIONS } from './lib/summary_options.js';

const BASE_URL = __ENV.GATEWAY_URL || 'http://localhost:8091';
const VUS = Number(__ENV.VUS || 30);
const DURATION = __ENV.DURATION || '1m';

export const options = {
    ...SUMMARY_OPTIONS,
    scenarios: {
        same_ledger_race: { executor: 'constant-vus', vus: VUS, duration: DURATION },
    },
    thresholds: {
        http_req_failed: ['rate<0.01'],
        http_req_duration: ['p(95)<5000'],
    },
};

// ОДИН раз, ОДНИМ из токенов — все токены этого файла делят ОДИН леджер (см.
// шапку файла): заводить каждому СВОЮ пару счетов означало бы N независимых
// пар в одном леджере, а не нужную здесь ситуацию "все пишут в одно и то же".
export function setup() {
    return provisionLedger(BASE_URL, tokens[0].token);
}

export default function (accounts) {
    const token = pickToken(); // round-robin по VU — разные VU это разные "устройства" ОДНОГО аккаунта
    const res = pushOneOperation(BASE_URL, token, accounts);
    check(res, {
        'push: status 200': (r) => r.status === 200,
        'push: not stuck (<5s)': (r) => r.timings.duration < 5000,
    });
}
