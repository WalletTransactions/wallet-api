# Design

## Context

- `f_operations_for_period` и `f_operations_total` (миграция 000036, до этого 000032/000033) — SQL-функции
  `LANGUAGE sql`; фильтры повторены в обеих дословно (категории, исключённые категории,
  кошельки, `kind` через вычисляемый `CASE`, `q`, `qs`). wallet-report вызывает их
  именованной нотацией, передавая только заданные параметры.
- Добавление параметра меняет сигнатуру функции: `CREATE OR REPLACE` создал бы
  перегрузку. Прецедент — 000032 и 000036: `DROP FUNCTION` + `CREATE` + `GRANT`
  (DROP снимает привилегии).

## Goals / Non-Goals

**Goals:** `p_exclude_qs` в обеих функциях; `f_operations_by_category` с теми же фильтрами; согласованность итогов.

**Non-Goals:** изменение таблиц; индексы по комментарию (поиск по подстроке уже делается
полным проходом периода); группировка по месяцам или кошелькам.

## Decisions

### D1. DROP + CREATE + GRANT для изменённых функций
Старые сигнатуры (13 и 10 аргументов) удаляются, создаются с `p_exclude_qs text[] DEFAULT NULL`
последним параметром. Вызов wallet-report без `p_exclude_qs` продолжает работать (DEFAULT).
Тела — дословно 000036 плюс одно условие:
```
AND (p_exclude_qs IS NULL
     OR o.comment IS NULL
     OR NOT EXISTS (SELECT 1 FROM unnest(p_exclude_qs) AS v(q)
                     WHERE strpos(lower(translate(o.comment, 'Ёё', 'Ее')), lower(translate(v.q, 'Ёё', 'Ее'))) > 0))
```
`o.comment IS NULL` задан явно: `NULL` в `NOT EXISTS` даёт истину сам, но явная ветка убирает вопрос.

### D2. Новая функция вместо расширения `f_operations_total`
`f_operations_total` возвращает ровно одну строку, и wallet-report читает её позиционно;
добавление группировки сломало бы контракт. Отдельная `f_operations_by_category` — тот
же CTE `m` с колонками `category_uuid`, `category_name`, `date`, затем `GROUP BY`.
Категория берётся как в ленте: `NOT acc_from_is_operating → acc_fr_uuid`,
`NOT acc_to_is_operating → acc_to_uuid`, иначе `NULL`.

### D3. Знак `total_eq`
Тот же `CASE`, что в `f_operations_total` (с `p_kind` — `amount_eq`, без — `±` по `kind`);
без этого сумма по категориям не сойдётся с итогом. Согласованность закрепляется тестом
(аналог `operations_total_matches_all_pages` в wallet-report).

### D4. Другие сервисы
Нужна правка wallet-report (сопутствующий change `operations-search-summary`). wallet-gateway,
android-wallet, wallet-telegram, wallet-web не затрагиваются.

## Risks / Trade-offs

- **Дублирование фильтров в третий раз.** Три копии длинного `WHERE`. Принято: так устроено
  в 000027–000036; вынос в общую функцию — отдельная задача и риск для плана запроса.
- **Время выполнения.** Один дополнительный проход по периоду. Проверяется на тестовой базе (tasks 2.3).
- **Откат.** Down-миграция возвращает 000036 дословно и удаляет `f_operations_by_category`;
  wallet-report при откате без `summary` продолжает отвечать как раньше (D5 у wallet-report).
