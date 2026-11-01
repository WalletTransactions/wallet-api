// Сустейн-нагрузка на POST /sync/push через НЕЗАВИСИМЫЕ леджеры (см.
// TOKENS_FILE=data/independent_tokens.json по умолчанию у mint_tokens.sh) —
// показывает выигрыш DATABASE_POOL_SIZE на параллельных, НЕ пересекающихся
// нагрузках (тот же смысл, что scenario_pool_saturation.js у
// wallet-report/loadtest, только для write-пути wallet-api вместо чтения
// отчётов). Методика (POOL=1 vs 8 vs...) — см. ../README.md.
import { check } from 'k6';
import { tokens, pickToken } from './lib/tokens.js';
import { provisionLedger, pushOneOperation } from './lib/provision.js';
import { SUMMARY_OPTIONS } from './lib/summary_options.js';

const BASE_URL = __ENV.GATEWAY_URL || 'http://localhost:8091';
const VUS = Number(__ENV.VUS || 20);
const DURATION = __ENV.DURATION || '2m';

export const options = {
    ...SUMMARY_OPTIONS,
    scenarios: {
        push_sustained: { executor: 'constant-vus', vus: VUS, duration: DURATION },
    },
    thresholds: {
        http_req_failed: ['rate<0.01'],
    },
};

// setup() — ОДИН раз на весь прогон (k6 сам гарантирует однопоточность
// здесь), не на каждый VU: по одному леджеру НА КАЖДЫЙ токен (они все
// независимые, см. mint_tokens.sh) — иначе провижининг (несколько HTTP
// походов) попал бы в измеряемую фазу нагрузки вперемешку с самим тестом.
export function setup() {
    const accountsByToken = {};
    tokens.forEach(function (t) {
        accountsByToken[t.token] = provisionLedger(BASE_URL, t.token);
    });
    return accountsByToken;
}

export default function (accountsByToken) {
    const token = pickToken();
    const res = pushOneOperation(BASE_URL, token, accountsByToken[token]);
    check(res, { 'push: status 200': (r) => r.status === 200 });
}
