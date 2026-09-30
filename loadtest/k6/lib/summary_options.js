// Копия ../../../wallet-report/loadtest/k6/lib/summary_options.js — то же
// назначение: k6 по умолчанию кладёт в --summary-export только
// avg/min/med/max/p(90)/p(95) — БЕЗ p(50) (есть только "med", то же
// значение, но под другим ключом) и БЕЗ p(99) вовсе. record_run.sh
// (../../record_run.sh) читает из summary.json именно "p(50)"/"p(90)"/
// "p(95)"/"p(99)" — без этого summaryTrendStats p50_ms/p99_ms в perf_history
// молча писались бы нулями, не падая ни на чём (jq -r '... // 0').
export const SUMMARY_OPTIONS = {
    summaryTrendStats: ['avg', 'min', 'med', 'p(50)', 'p(90)', 'p(95)', 'p(99)', 'max'],
};
