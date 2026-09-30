#!/usr/bin/env bash
# Копия ../../wallet-report/loadtest/render_report.sh — скрипт общий
# (принимает summary.json/out.html/заголовок аргументами, ничего wallet-report-
# специфичного внутри), продублирована, а не вынесена в общее место, тем же
# приёмом, что и record_run.sh/mint_tokens.sh в этом каталоге — у loadtest-
# контура каждого сервиса свой независимый набор инструментов.
#
# Рисует статический HTML-отчёт по одному --summary-export JSON k6
# (BuildPlatform/jobs/wallet-api-loadtest/Jenkinsfile, стадия "Report" —
# публикуется HTML Publisher Plugin'ом). Только jq + bash-heredoc — без
# node/community-инструмента k6-reporter: проект последовательно избегает
# лишних внешних зависимостей (свой JWT, свой base64, свой тестовый
# фреймворк, см. остальной код servers/) — статическая таблица тех же
# агрегатных метрик, что уже использует compare_results.sh/extract_metrics.sh,
# не требует новой зависимости ради красивого рендера.
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Использование: $0 <summary.json> <out.html> <заголовок>" >&2
    exit 2
fi

SUMMARY="$1"
OUT="$2"
TITLE="$3"

if [[ ! -f "$SUMMARY" ]]; then
    echo "Не найден файл: $SUMMARY" >&2
    exit 2
fi

p95=$(jq -r '.metrics.http_req_duration."p(95)" // 0' "$SUMMARY")
p90=$(jq -r '.metrics.http_req_duration."p(90)" // 0' "$SUMMARY")
p50=$(jq -r '.metrics.http_req_duration.med // 0' "$SUMMARY")
avg=$(jq -r '.metrics.http_req_duration.avg // 0' "$SUMMARY")
max=$(jq -r '.metrics.http_req_duration.max // 0' "$SUMMARY")
reqs=$(jq -r '.metrics.http_reqs.count // 0' "$SUMMARY")
rate=$(jq -r '.metrics.http_reqs.rate // 0' "$SUMMARY")
err=$(jq -r '.metrics.http_req_failed.rate // 0' "$SUMMARY")

fmt() { awk -v v="$1" 'BEGIN { printf "%.1f", v }'; }

cat > "$OUT" <<HTML
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<title>${TITLE}</title>
<style>
  body { font-family: -apple-system, Segoe UI, sans-serif; margin: 24px; color: #1a1a1a; }
  h1 { font-size: 18px; }
  table { border-collapse: collapse; margin-top: 12px; }
  th, td { padding: 6px 14px; border: 1px solid #ccc; text-align: right; }
  th { background: #f0f0f0; text-align: left; }
  td:first-child { text-align: left; font-weight: bold; }
  .err { color: #b00020; }
  .ok { color: #1a7f37; }
</style>
</head>
<body>
<h1>${TITLE}</h1>
<table>
  <tr><th>Метрика</th><th>Значение</th></tr>
  <tr><td>Запросов всего</td><td>${reqs}</td></tr>
  <tr><td>req/s</td><td>$(fmt "$rate")</td></tr>
  <tr><td>avg</td><td>$(fmt "$avg") мс</td></tr>
  <tr><td>p50</td><td>$(fmt "$p50") мс</td></tr>
  <tr><td>p90</td><td>$(fmt "$p90") мс</td></tr>
  <tr><td>p95</td><td>$(fmt "$p95") мс</td></tr>
  <tr><td>max</td><td>$(fmt "$max") мс</td></tr>
  <tr><td>error rate</td><td class="$(awk -v e="$err" 'BEGIN{print (e>0)?"err":"ok"}')">$(awk -v e="$err" 'BEGIN{printf "%.2f%%", e*100}')</td></tr>
</table>
</body>
</html>
HTML

echo "Готово: $OUT"
