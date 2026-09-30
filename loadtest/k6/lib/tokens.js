// Грузит TOKENS_FILE (см. ../../mint_tokens.sh) через SharedArray — одна
// копия на процесс k6, а не на VU — и раздаёт токен каждому VU по кругу.
// Один и тот же файл-модуль годится для ОБОИХ наборов токенов (см. README.md):
// independent_tokens.json (разные пользователи/леджеры) и
// same_ledger_tokens.json (один леджер, разные устройства) — какой из них
// использовать, решает TOKENS_FILE конкретного прогона, не эта библиотека.
import { SharedArray } from 'k6/data';

const TOKENS_FILE = __ENV.TOKENS_FILE || './data/independent_tokens.json';

export const tokens = new SharedArray('tokens', function () {
    const raw = JSON.parse(open(TOKENS_FILE));
    if (!Array.isArray(raw) || raw.length === 0) {
        throw new Error(
            `${TOKENS_FILE} пуст или не найден — сначала bash mint_tokens.sh (см. ../../README.md)`
        );
    }
    return raw;
});

export function pickToken() {
    const idx = (__VU - 1) % tokens.length;
    return tokens[idx].token;
}
