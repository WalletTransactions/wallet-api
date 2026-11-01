# Spec Delta

## MODIFIED Requirements

### Requirement: Сброс курсора, ушедшего дальше головы
Если курсор потока больше его головы (такого `seq` сервер не выдавал), pull
SHALL отдать поток с нуля, `reset: true` и `reset_reason: "ahead"` в этом
потоке и записать warn `sync_pull_cursor_reset`. Без сброса — `reset: false`
и без поля `reset_reason`. Голова только растёт, так что параллельный push
ложного сброса не даёт.

#### Scenario: Курсор от пересозданной базы
- **WHEN** клиент присылает `ledger_seq=146` при голове потока `13`
- **THEN** `ledger.reset` = `true`, `ledger.reset_reason` = `"ahead"`, поток отдан с начала, `next_seq` ≤ 13

#### Scenario: Обычная страница
- **WHEN** курсор не больше головы и поток не вычищен дальше курсора
- **THEN** `reset` = `false`, поля `reset_reason` в потоке нет
