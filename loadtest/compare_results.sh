#!/usr/bin/env bash
# Копия ../../wallet-report/loadtest/compare_results.sh — скрипт общий, см.
# комментарий в render_report.sh этого каталога, почему продублирован.
#
# Инструмент сравнения нагрузочного контура (BuildPlatform/jobs/
# wallet-api-loadtest/Jenkinsfile, стадия "Compare") — сравнивает два --summary-export
# JSON от k6 (текущий прогон и baseline — обычно предыдущий успешный билд
# Jenkins, подтянутый Copy Artifact Plugin'ом) и решает, деградировала ли
# производительность.
#
# jq — уже обязательная зависимость контура (см. ../run.sh); awk — для
# процентной арифметики, чтобы не тянуть отдельно python3/bc.
#
# Код возврата 0 — в пределах порога (или baseline лучше), 1 — p95
# регрессировал больше REGRESSION_THRESHOLD_PCT. Jenkinsfile превращает
# ненулевой код в currentBuild.result = 'UNSTABLE' (не FAILURE — нагрузочная
# деградация должна привлекать внимание, а не намертво ронять пайплайн,
# тем же принципом, что пороги `thresholds` в самих k6-сценариях не валят
# прогон целиком).
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Использование: $0 <current.json> <baseline.json>" >&2
    exit 2
fi

CURRENT="$1"
BASELINE="$2"
THRESHOLD_PCT="${REGRESSION_THRESHOLD_PCT:-20}"

for f in "$CURRENT" "$BASELINE"; do
    if [[ ! -f "$f" ]]; then
        echo "Не найден файл: $f" >&2
        exit 2
    fi
done

# jq -e с "// 0" — на случай отсутствующей метрики (например, http_reqs
# пуст, если сценарий не сделал ни одного запроса) не падаем, а сравниваем
# честный 0, ничего не имитируя.
read_metric() {
    jq -r "$2 // 0" "$1"
}

cur_p95=$(read_metric "$CURRENT" '.metrics.http_req_duration."p(95)"')
base_p95=$(read_metric "$BASELINE" '.metrics.http_req_duration."p(95)"')
cur_avg=$(read_metric "$CURRENT" '.metrics.http_req_duration.avg')
base_avg=$(read_metric "$BASELINE" '.metrics.http_req_duration.avg')
cur_rate=$(read_metric "$CURRENT" '.metrics.http_reqs.rate')
base_rate=$(read_metric "$BASELINE" '.metrics.http_reqs.rate')
cur_err=$(read_metric "$CURRENT" '.metrics.http_req_failed.rate')
base_err=$(read_metric "$BASELINE" '.metrics.http_req_failed.rate')

# delta_pct(текущее, baseline) — на сколько % ХУЖЕ текущее (положительное
# число = деградация); baseline=0 (пустой прогон) — 0%, а не деление на
# ноль/бесконечность.
delta_pct() {
    awk -v cur="$1" -v base="$2" 'BEGIN {
        if (base == 0) { print "0.0"; exit }
        printf "%.1f", (cur - base) / base * 100
    }'
}

p95_delta=$(delta_pct "$cur_p95" "$base_p95")
avg_delta=$(delta_pct "$cur_avg" "$base_avg")
# throughput — рост хороший, поэтому дельта считается в обратную сторону
# (baseline относительно текущего), чтобы "плюс" везде означало "хуже".
rate_delta=$(delta_pct "$base_rate" "$cur_rate")

printf "%-22s %12s %12s %10s\n" "метрика" "текущее" "baseline" "Δ%"
printf "%-22s %12.1f %12.1f %9s%%\n" "p95, мс" "$cur_p95" "$base_p95" "$p95_delta"
printf "%-22s %12.1f %12.1f %9s%%\n" "avg, мс" "$cur_avg" "$base_avg" "$avg_delta"
printf "%-22s %12.1f %12.1f %9s%%\n" "req/s" "$cur_rate" "$base_rate" "$rate_delta"
printf "%-22s %12.4f %12.4f\n" "error rate" "$cur_err" "$base_err"

is_regression=$(awk -v d="$p95_delta" -v t="$THRESHOLD_PCT" 'BEGIN { print (d > t) ? "1" : "0" }')

if [[ "$is_regression" == "1" ]]; then
    echo
    echo "РЕГРЕССИЯ: p95 хуже baseline на ${p95_delta}% (порог ${THRESHOLD_PCT}%)"
    exit 1
fi

echo
echo "OK: p95 в пределах порога (${p95_delta}% <= ${THRESHOLD_PCT}%)"
