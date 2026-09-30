// 1 VU, 1 итерация — ворота перед серьёзной нагрузкой: провижининг + один
// push проходят и отвечают 200, прежде чем гонять сотни VU (тот же принцип,
// что scenario_smoke.js у wallet-report/loadtest).
import { check } from 'k6';
import { pickToken } from './lib/tokens.js';
import { provisionLedger, pushOneOperation } from './lib/provision.js';

const BASE_URL = __ENV.GATEWAY_URL || 'http://localhost:8090';

export const options = { vus: 1, iterations: 1 };

export default function () {
    const token = pickToken();
    const accounts = provisionLedger(BASE_URL, token);
    const res = pushOneOperation(BASE_URL, token, accounts);
    check(res, { 'push: status 200': (r) => r.status === 200 });
}
