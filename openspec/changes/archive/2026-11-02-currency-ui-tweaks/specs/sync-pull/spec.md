# Spec Delta

## ADDED Requirements

### Requirement: Флаг эквивалента в строке валюты
Строка `currency` в pull SHALL нести булево `show_in_equivalent` в обоих
потоках: у общих валют оно задаётся сервером, у своих — последним push.
Валюты, созданные до появления флага, отдаются с `true`.

#### Scenario: Валюта до миграции
- **WHEN** клиент делает полный pull после миграции, а валюта создана раньше
- **THEN** её строка несёт `show_in_equivalent: true`

#### Scenario: Флаг снят на другом устройстве
- **WHEN** другое устройство того же леджера запушило валюту с `show_in_equivalent: false`
- **THEN** pull после курсора отдаёт эту валюту с `show_in_equivalent: false`
