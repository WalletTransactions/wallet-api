# Git-хуки проекта

Версионируемые хуки — `.git/hooks/` не под git, туда ничего не кладём.

## Установка (один раз на чекаут)

```bash
git config core.hooksPath scripts/hooks
```

## `pre-commit`

Если в коммит попадают правки `schema/` или `migrations/`, гоняет
интеграционные тесты отчётов из соседнего репозитория
(`../wallet-report/tests_integration/run_local.sh` — тесты на реальной
цепочке миграций и реальном протоколе синка) и отклоняет коммит, если они
не прошли. Требует `wallet-report` рядом с `wallet-api` и запущенный `db`
из `docker compose` (см. `wallet-infra/README.md`) — если его нет, хук
сразу скажет, что поднять.

Разовый обход: `git commit --no-verify`.
