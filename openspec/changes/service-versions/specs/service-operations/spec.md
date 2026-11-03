# Spec Delta

## MODIFIED Requirements

### Requirement: Версия билда
`GET /version` SHALL отвечать `{"service":"wallet-api","version":…,"build":…,"git_commit":…,"started_at":…}`:
версия из файла `VERSION`; `build` — тег образа из `APP_BUILD`, без него
`<VERSION>-dev`; короткий хеш коммита на момент сборки или `unknown`;
`started_at` — время запуска процесса, ISO-8601 UTC. `service`, `version`,
`build` и `git_commit` есть в `build_info` метрик и в строке лога при старте.
`/metrics` дополнительно отдаёт `process_start_time_seconds`.

#### Scenario: Сборка без git
- **WHEN** образ собран без `GIT_COMMIT`, и git недоступен
- **THEN** `git_commit` = `unknown`

#### Scenario: Сборка без тега
- **WHEN** образ собран без `APP_BUILD`
- **THEN** `build` = `<VERSION>-dev`

#### Scenario: Время запуска
- **WHEN** `/version` вызван дважды без перезапуска, а затем после перезапуска контейнера
- **THEN** первые два `started_at` равны, третий — время нового запуска
