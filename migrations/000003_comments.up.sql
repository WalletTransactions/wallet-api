-- Описания таблиц и колонок как настоящие Postgres-комментарии (COMMENT ON),
-- а не только прозаические -- комментарии над CREATE TABLE в 000001/000002.
-- Разница принципиальная: COMMENT ON виден через \d+ в psql и через
-- information_schema/pg_catalog кому угодно, кто открыл базу инструментом, а
-- не читает исходники миграций — например, отчётному сервису или человеку с
-- DBeaver/pgAdmin.
--
-- Отдельная миграция, не правка 000001/000002: COMMENT ON — настоящее
-- изменение схемы (хранится в pg_description), и 000001/000002 уже накачены
-- на живую базу — golang-migrate их повторно не выполнит (см.
-- infra/db/README.md, "Миграции").
--
-- Тот же текст (см. ту же мысль в каждой правке этого домена) продублирован
-- в зеркале schema/server/table/*.sql — см. корневую память
-- ddl-mirror-must-follow-schema-changes.

-- ── Демо-таблица первой миграции ────────────────────────────────────────

COMMENT ON TABLE wallets IS
    'Демонстрационная таблица из самой первой миграции — не часть домена синка (ledger/account/operation и т.д.), простой смоук-тест схемы и ролей.';
COMMENT ON COLUMN wallets.id IS 'Идентификатор кошелька.';
COMMENT ON COLUMN wallets.owner_id IS
    '"sub" уже проверенного access-JWT — НЕ внешний ключ, отдельной таблицы пользователей в этой базе нет (см. README wallet-api, "Своя БД").';
COMMENT ON COLUMN wallets.currency IS
    'ISO-код валюты кошелька текстом, без ссылки на отдельную таблицу currency — демо-таблица устроена проще боевой схемы.';
COMMENT ON COLUMN wallets.label IS 'Название кошелька, видимое пользователю.';
COMMENT ON COLUMN wallets.balance_cents IS
    'Баланс в минимальных единицах валюты (центах) — целочисленно, без numeric, в отличие от operation.amount в боевой схеме.';
COMMENT ON COLUMN wallets.created_at IS 'Момент создания записи.';

-- ── Счётчики версий ──────────────────────────────────────────────────────

COMMENT ON TABLE change_stream IS
    'Счётчики версий строк (seq): одна строка на каждый леджер (kind=''ledger'') плюс одна константная строка на общие справочники (kind=''reference''). next_seq() инкрементирует нужную строку в той же транзакции, что и сами изменения — см. function/next_seq.sql.';
COMMENT ON COLUMN change_stream.id IS
    'Для kind=''ledger'' совпадает с ledger.id того же леджера. Для kind=''reference'' — фиксированное значение 00000000-0000-0000-0000-000000000001, на которое ссылается весь код, работающий со справочниками.';
COMMENT ON COLUMN change_stream.kind IS
    '''ledger'' — персональный поток одного леджера (счета, операции, свои валюты/иконки); ''reference'' — общий поток на всю базу (общие иконки/валюты/пары/курсы).';
COMMENT ON COLUMN change_stream.seq IS
    'Текущее значение счётчика версий этого потока. Растёт монотонно только через next_seq() — не SEQUENCE и не время (см. README schema/server, "Версия строки — seq, а не время").';

-- ── Владение данными ─────────────────────────────────────────────────────

COMMENT ON TABLE ledger IS
    'Леджер — единица владения данными и единица синхронизации: всё, что видит пользователь, принадлежит ровно одному леджеру.';
COMMENT ON COLUMN ledger.id IS
    'Совпадает с change_stream.id того же потока (kind=''ledger'') — создание леджера всегда две вставки в одной транзакции, сначала в change_stream.';
COMMENT ON COLUMN ledger.name IS
    'Название леджера, для показа в UI при выборе/переключении. На MVP — один леджер на пользователя (см. servers/TODO_mobile_sync.md, п. 1.3), поле зарезервировано на будущий шаринг.';
COMMENT ON COLUMN ledger.created_at IS 'Момент создания леджера.';

COMMENT ON TABLE app_user IS
    'Пользователь wallet-api. Не отдельная идентичность — id это claim "sub" уже проверенного access-JWT (внутренний UserRecord.id google-auth), вся аутентификация и выпуск токенов централизованы в google-auth.';
COMMENT ON COLUMN app_user.id IS
    '= claim "sub" access-JWT, НЕ DEFAULT gen_random_uuid() — значение приходит извне, из уже проверенного токена, а не порождается этой базой.';
COMMENT ON COLUMN app_user.email IS
    'Кэш claim "email" из JWT — только для показа и отчётов, не участвует ни в одном решении о доступе; легитимно устаревает между обновлениями токена.';
COMMENT ON COLUMN app_user.created_at IS
    'Момент первого появления пользователя в этой базе (первый вызов provisioning::ensure_identity).';
COMMENT ON COLUMN app_user.disabled_at IS
    'Мягкая блокировка входа — зарезервировано, сейчас ничего его не выставляет (саму блокировку входа делает google-auth).';

COMMENT ON TABLE ledger_member IS
    'Права доступа пользователя к леджеру — кто может видеть/писать/владеть. Заведена с первого дня, даже если пользователь у леджера всегда один: общий кошелёк потом требует только выдачи второй строки, а не переписывания всех запросов.';
COMMENT ON COLUMN ledger_member.ledger_id IS 'Леджер, к которому относится право доступа.';
COMMENT ON COLUMN ledger_member.user_id IS 'Пользователь, которому выдано право доступа.';
COMMENT ON COLUMN ledger_member.role IS
    '''owner'' — ровно один на леджер (см. uq_ledger_member_owner), может удалить леджер и раздать доступ; ''member'' — обычный участник; ''reader'' — только чтение.';
COMMENT ON COLUMN ledger_member.joined_at IS 'Момент выдачи доступа к леджеру.';

COMMENT ON TABLE device IS
    'Устройство пользователя — книга устройств для курсоров синка и диагностики ("какое устройство последним писало"), НЕ точка выдачи/ротации refresh-токенов (это целиком делает google-auth).';
COMMENT ON COLUMN device.id IS
    '= claim "device_id" уже проверенного access-JWT (генерирует Android при первой установке, см. AppSettings.getOrCreateDeviceId), не порождается этой базой.';
COMMENT ON COLUMN device.user_id IS 'Владелец устройства.';
COMMENT ON COLUMN device.ledger_id IS 'Леджер, с которым это устройство синхронизируется.';
COMMENT ON COLUMN device.platform IS
    '''android''/''ios''/''web''/''other'' — из тела запроса мобильного входа (POST /auth/google/mobile); пустая строка — браузерный вход, где устройства как такового нет.';
COMMENT ON COLUMN device.name IS
    'Человекочитаемое имя устройства (модель телефона и т.п.), только для показа человеку — см. README google-auth, "Детали устройства".';
COMMENT ON COLUMN device.last_seen_at IS 'Момент последнего успешного обращения устройства к /sync/*.';
COMMENT ON COLUMN device.last_ack_seq IS
    'Справочная копия курсора клиента — только для диагностики и "сбросить синхронизацию на этом устройстве". Авторитетный курсор всё равно хранится на клиенте — сервер не знает, доехала ли до него последняя страница.';
COMMENT ON COLUMN device.created_at IS 'Момент первой регистрации устройства.';

COMMENT ON TABLE sync_push_batch IS
    'Идемпотентность отправки изменений: сохранённый ответ на уже применённый батч, чтобы повтор того же batch_id (офлайновый клиент, ответ потерялся) не применял изменения повторно, а получил тот же ответ.';
COMMENT ON COLUMN sync_push_batch.batch_id IS
    'Идентификатор батча, генерирует клиент. Первичный ключ — повтор с тем же значением находит эту строку и возвращает её response, ничего не применяя заново.';
COMMENT ON COLUMN sync_push_batch.device_id IS 'Устройство, приславшее батч.';
COMMENT ON COLUMN sync_push_batch.ledger_id IS 'Леджер, к которому применён батч.';
COMMENT ON COLUMN sync_push_batch.seq IS
    'Значение seq, выданное этому батчу через next_seq() — то же самое значение записано во все изменённые этим батчом строки.';
COMMENT ON COLUMN sync_push_batch.response IS
    'Сохранённое тело HTTP-ответа (JSON) — то, что будет возвращено при повторе того же batch_id.';
COMMENT ON COLUMN sync_push_batch.created_at IS
    'Момент применения батча — по этому полю строки чистятся по расписанию (живут порядка недели).';

-- ── Содержимое и справочники ─────────────────────────────────────────────

COMMENT ON TABLE blob IS
    'Двоичное содержимое, адресуемое по SHA-256 (сейчас только изображения иконок). Строки ничьи — ledger_id здесь нет, содержимое общее; право прочитать конкретный blob проверяет приложение.';
COMMENT ON COLUMN blob.sha256 IS
    'SHA-256 содержимого, ровно 32 байта — первичный ключ и адрес контента одновременно.';
COMMENT ON COLUMN blob.bytes IS
    'Само содержимое (WEBP-изображение иконки), от 1 байта до 1 МиБ — верхняя граница защищает от заливки произвольных файлов через API иконок.';
COMMENT ON COLUMN blob.created_at IS 'Момент заливки содержимого.';

COMMENT ON TABLE icon IS
    'Иконка — ссылка на содержимое в blob по SHA-256, с именем и типом. ledger_id IS NULL — общая иконка, которая едет всем; заполненный — своя, добавленная пользователем из галереи.';
COMMENT ON COLUMN icon.uuid IS 'Идентификатор иконки, общий для клиента и сервера (синхронизируемая сущность).';
COMMENT ON COLUMN icon.ledger_id IS 'NULL — общая (справочная) иконка; заполнено — своя иконка этого леджера.';
COMMENT ON COLUMN icon.seq IS 'Версия строки в её потоке изменений (ledger или reference, см. change_stream).';
COMMENT ON COLUMN icon.deleted_at IS 'Момент мягкого удаления (tombstone); NULL — строка активна.';
COMMENT ON COLUMN icon.updated_at IS
    'Момент последнего изменения строки — только диагностика, проставляет триггер set_updated_at; ни одно решение о конфликте по нему не принимается (см. seq).';
COMMENT ON COLUMN icon.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN icon.name IS 'Название иконки, видимое в галерее выбора.';
COMMENT ON COLUMN icon.content_sha256 IS 'Ссылка на содержимое картинки в blob.sha256.';
COMMENT ON COLUMN icon.icon_type IS
    'Код типа иконки: у клиента различает 0=категория/1=флаг, но в реальных данных встречаются и другие значения (см. комментарий в table/icon.sql) — приложение считает "1 это флаг, всё остальное категория".';

COMMENT ON TABLE currency IS
    'Валюта — справочная таблица. ledger_id IS NULL — общая валюта, которую сервер раздаёт всем; заполненный — валюта, которую пользователь добавил себе сам (редкая, локальная, крипта).';
COMMENT ON COLUMN currency.uuid IS 'Идентификатор валюты.';
COMMENT ON COLUMN currency.ledger_id IS 'NULL — общая валюта; заполнено — своя валюта этого леджера.';
COMMENT ON COLUMN currency.seq IS 'Версия строки в её потоке изменений (ledger или reference).';
COMMENT ON COLUMN currency.deleted_at IS 'Момент мягкого удаления (tombstone); NULL — строка активна.';
COMMENT ON COLUMN currency.updated_at IS 'Момент последнего изменения строки — только диагностика.';
COMMENT ON COLUMN currency.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN currency.name IS 'Название валюты, видимое пользователю.';
COMMENT ON COLUMN currency.iso_code IS
    'Код валюты (например, "USD") — по нему уникальность внутри своей области видимости (общая/леджера, см. uq_currency_iso_*).';
COMMENT ON COLUMN currency.icon_uuid IS 'Иконка-флаг/символ этой валюты.';
COMMENT ON COLUMN currency.symbol IS 'Символ валюты для вывода сумм (например, "$").';
COMMENT ON COLUMN currency."precision" IS
    'Число знаков после запятой в суммах этой валюты — определяет округление и ограничивает верхнюю границу масштаба operation.amount для этой валюты.';

COMMENT ON TABLE currency_pair IS
    'Валютная пара с направлением "база → квота" и собственной точностью курса. Справочная таблица, область видимости как у currency.';
COMMENT ON COLUMN currency_pair.uuid IS 'Идентификатор пары.';
COMMENT ON COLUMN currency_pair.ledger_id IS 'NULL — общая пара; заполнено — своя пара этого леджера.';
COMMENT ON COLUMN currency_pair.seq IS 'Версия строки в её потоке изменений (ledger или reference).';
COMMENT ON COLUMN currency_pair.deleted_at IS 'Момент мягкого удаления (tombstone); NULL — строка активна.';
COMMENT ON COLUMN currency_pair.updated_at IS 'Момент последнего изменения строки — только диагностика.';
COMMENT ON COLUMN currency_pair.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN currency_pair.symbol IS 'Обозначение пары для отображения (например, "EUR/USD").';
COMMENT ON COLUMN currency_pair.base_currency_uuid IS
    'Базовая валюта пары — курс задаётся как "квота за 1 базовую единицу".';
COMMENT ON COLUMN currency_pair.quote_currency_uuid IS 'Котируемая валюта пары.';
COMMENT ON COLUMN currency_pair."precision" IS 'Число знаков после запятой в курсах этой пары.';

COMMENT ON TABLE currency_pair_rate IS
    'Курс пары на конкретную дату: квота за 1 базовую единицу. Самая большая по объёму таблица в базе — история курсов по всем парам за все годы.';
COMMENT ON COLUMN currency_pair_rate.uuid IS 'Идентификатор строки курса.';
COMMENT ON COLUMN currency_pair_rate.ledger_id IS
    'NULL — общий курс; заполнено — ручной курс этого леджера (сосуществует с общим на ту же дату, см. uq_currency_pair_rate_*).';
COMMENT ON COLUMN currency_pair_rate.seq IS 'Версия строки в её потоке изменений (ledger или reference).';
COMMENT ON COLUMN currency_pair_rate.deleted_at IS 'Момент мягкого удаления (tombstone); NULL — строка активна.';
COMMENT ON COLUMN currency_pair_rate.updated_at IS 'Момент последнего изменения строки — только диагностика.';
COMMENT ON COLUMN currency_pair_rate.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN currency_pair_rate.currency_pair_uuid IS 'Пара, к которой относится этот курс.';
COMMENT ON COLUMN currency_pair_rate."date" IS
    'Дата, на которую действует курс — без времени: курс это величина на день, две записи на одну дату с разным временем здесь невозможны.';
COMMENT ON COLUMN currency_pair_rate.rate IS
    'Значение курса, строго положительное. Обратный курс (квота→база) считается делением 1.0/rate, отдельно не хранится.';

COMMENT ON TABLE currency_conversion IS
    'Ручное переопределение маршрута пересчёта одной валюты в другую, когда прямой пары нет. В клиенте таблица всегда пустая — заведена ради полноты зеркала.';
COMMENT ON COLUMN currency_conversion.uuid IS 'Идентификатор строки переопределения.';
COMMENT ON COLUMN currency_conversion.ledger_id IS 'NULL — общее переопределение; заполнено — своё для этого леджера.';
COMMENT ON COLUMN currency_conversion.seq IS 'Версия строки в её потоке изменений (ledger или reference).';
COMMENT ON COLUMN currency_conversion.deleted_at IS 'Момент мягкого удаления (tombstone); NULL — строка активна.';
COMMENT ON COLUMN currency_conversion.updated_at IS 'Момент последнего изменения строки — только диагностика.';
COMMENT ON COLUMN currency_conversion.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN currency_conversion.from_currency_uuid IS 'Исходная валюта пересчёта.';
COMMENT ON COLUMN currency_conversion.to_currency_uuid IS 'Целевая валюта пересчёта.';
COMMENT ON COLUMN currency_conversion.num IS
    'Номер альтернативного маршрута между этой парой валют — на случай нескольких путей пересчёта между одними и теми же валютами.';
COMMENT ON COLUMN currency_conversion.currency_pair_uuid IS 'Пара, курс которой использовать для этого маршрута.';
COMMENT ON COLUMN currency_conversion.is_reverse IS
    'true — использовать обратный курс пары (1.0/rate), false — прямой.';

-- ── Данные леджера ───────────────────────────────────────────────────────

COMMENT ON TABLE account IS
    'Единая таблица счетов и категорий: строка становится кошельком, если для того же uuid есть строка в account_operating, иначе это категория.';
COMMENT ON COLUMN account.uuid IS 'Идентификатор счёта/категории, общий с клиентом.';
COMMENT ON COLUMN account.ledger_id IS 'Леджер-владелец — личные данные пользователя, общих счетов не бывает (NOT NULL).';
COMMENT ON COLUMN account.seq IS 'Версия строки в потоке изменений леджера.';
COMMENT ON COLUMN account.deleted_at IS 'Момент мягкого удаления (tombstone); NULL — строка активна.';
COMMENT ON COLUMN account.updated_at IS 'Момент последнего изменения строки — только диагностика.';
COMMENT ON COLUMN account.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN account.name IS
    'Название счёта/категории, видимое пользователю — уникально среди живых (deleted_at IS NULL) строк леджера, см. uq_account_name.';
COMMENT ON COLUMN account.comment IS 'Свободный комментарий пользователя к счёту/категории.';
COMMENT ON COLUMN account.icon_uuid IS 'Иконка счёта/категории.';
COMMENT ON COLUMN account.is_archived IS
    'Признак только для интерфейса — архивный счёт участвует в расчётах наравне с остальными, иначе архивация молча меняла бы итоги за прошлые периоды.';

COMMENT ON TABLE account_operating IS
    'Расширение account для кошельков: строка есть — счёт операционный (есть валюта), строки нет — это категория. uuid всегда равен account.uuid.';
COMMENT ON COLUMN account_operating.uuid IS '= account.uuid того же счёта.';
COMMENT ON COLUMN account_operating.ledger_id IS '= account.ledger_id того же счёта.';
COMMENT ON COLUMN account_operating.seq IS 'Версия строки в потоке изменений леджера — своя, отдельная от account.seq.';
COMMENT ON COLUMN account_operating.deleted_at IS
    'Момент мягкого удаления (снятие "операционности" со счёта); NULL — строка активна.';
COMMENT ON COLUMN account_operating.updated_at IS 'Момент последнего изменения строки — только диагностика.';
COMMENT ON COLUMN account_operating.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN account_operating.currency_uuid IS 'Валюта этого кошелька.';

COMMENT ON TABLE operation IS
    'Единственная таблица транзакций. Любая операция — перевод между двумя account: расход "кошелёк → категория", доход "категория → кошелёк", перевод "кошелёк → кошелёк".';
COMMENT ON COLUMN operation.uuid IS 'Идентификатор операции, общий с клиентом.';
COMMENT ON COLUMN operation.ledger_id IS 'Леджер-владелец операции.';
COMMENT ON COLUMN operation.seq IS 'Версия строки в потоке изменений леджера.';
COMMENT ON COLUMN operation.deleted_at IS 'Момент мягкого удаления (tombstone); NULL — строка активна.';
COMMENT ON COLUMN operation.updated_at IS 'Момент последнего изменения строки — только диагностика.';
COMMENT ON COLUMN operation.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN operation."date" IS
    'Бизнес-дата операции — локальное время клиента, БЕЗ часового пояса намеренно (перевод в UTC сдвинул бы часть операций через границу суток и разъехал отчёты между устройствами в разных поясах).';
COMMENT ON COLUMN operation.acc_fr_uuid IS 'Счёт списания (источник проводки).';
COMMENT ON COLUMN operation.acc_to_uuid IS 'Счёт зачисления (получатель проводки).';
COMMENT ON COLUMN operation.amount IS
    'Сумма проводки, всегда неотрицательная (CHECK amount >= 0) — направление задаёт пара acc_fr/acc_to, а не знак.';
COMMENT ON COLUMN operation.comment IS 'Свободный комментарий пользователя к операции.';

COMMENT ON TABLE operation_link IS
    'Связь проводок одной пользовательской операции, хранимых несколькими строками (разновалютный перевод, комиссия за перевод).';
COMMENT ON COLUMN operation_link.uuid IS 'Идентификатор строки связи.';
COMMENT ON COLUMN operation_link.ledger_id IS 'Леджер-владелец.';
COMMENT ON COLUMN operation_link.seq IS 'Версия строки в потоке изменений леджера.';
COMMENT ON COLUMN operation_link.deleted_at IS 'Момент мягкого удаления (tombstone); NULL — строка активна.';
COMMENT ON COLUMN operation_link.updated_at IS 'Момент последнего изменения строки — только диагностика.';
COMMENT ON COLUMN operation_link.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN operation_link.main_uuid IS
    'Проводка списания с кошелька-источника — по ней находится вся операция целиком.';
COMMENT ON COLUMN operation_link.link_uuid IS 'Вторая нога перевода или комиссия, связанная с main_uuid.';
