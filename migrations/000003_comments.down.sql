-- Откат 000003_comments.up.sql — снимает все COMMENT ON, не трогая ни одной
-- таблицы/колонки/данных. COMMENT ON ... IS NULL — единственный способ
-- убрать комментарий в Postgres (DROP COMMENT не существует).

COMMENT ON TABLE wallets IS NULL;
COMMENT ON COLUMN wallets.id IS NULL;
COMMENT ON COLUMN wallets.owner_id IS NULL;
COMMENT ON COLUMN wallets.currency IS NULL;
COMMENT ON COLUMN wallets.label IS NULL;
COMMENT ON COLUMN wallets.balance_cents IS NULL;
COMMENT ON COLUMN wallets.created_at IS NULL;

COMMENT ON TABLE change_stream IS NULL;
COMMENT ON COLUMN change_stream.id IS NULL;
COMMENT ON COLUMN change_stream.kind IS NULL;
COMMENT ON COLUMN change_stream.seq IS NULL;

COMMENT ON TABLE ledger IS NULL;
COMMENT ON COLUMN ledger.id IS NULL;
COMMENT ON COLUMN ledger.name IS NULL;
COMMENT ON COLUMN ledger.created_at IS NULL;

COMMENT ON TABLE app_user IS NULL;
COMMENT ON COLUMN app_user.id IS NULL;
COMMENT ON COLUMN app_user.email IS NULL;
COMMENT ON COLUMN app_user.created_at IS NULL;
COMMENT ON COLUMN app_user.disabled_at IS NULL;

COMMENT ON TABLE ledger_member IS NULL;
COMMENT ON COLUMN ledger_member.ledger_id IS NULL;
COMMENT ON COLUMN ledger_member.user_id IS NULL;
COMMENT ON COLUMN ledger_member.role IS NULL;
COMMENT ON COLUMN ledger_member.joined_at IS NULL;

COMMENT ON TABLE device IS NULL;
COMMENT ON COLUMN device.id IS NULL;
COMMENT ON COLUMN device.user_id IS NULL;
COMMENT ON COLUMN device.ledger_id IS NULL;
COMMENT ON COLUMN device.platform IS NULL;
COMMENT ON COLUMN device.name IS NULL;
COMMENT ON COLUMN device.last_seen_at IS NULL;
COMMENT ON COLUMN device.last_ack_seq IS NULL;
COMMENT ON COLUMN device.created_at IS NULL;

COMMENT ON TABLE sync_push_batch IS NULL;
COMMENT ON COLUMN sync_push_batch.batch_id IS NULL;
COMMENT ON COLUMN sync_push_batch.device_id IS NULL;
COMMENT ON COLUMN sync_push_batch.ledger_id IS NULL;
COMMENT ON COLUMN sync_push_batch.seq IS NULL;
COMMENT ON COLUMN sync_push_batch.response IS NULL;
COMMENT ON COLUMN sync_push_batch.created_at IS NULL;

COMMENT ON TABLE blob IS NULL;
COMMENT ON COLUMN blob.sha256 IS NULL;
COMMENT ON COLUMN blob.bytes IS NULL;
COMMENT ON COLUMN blob.created_at IS NULL;

COMMENT ON TABLE icon IS NULL;
COMMENT ON COLUMN icon.uuid IS NULL;
COMMENT ON COLUMN icon.ledger_id IS NULL;
COMMENT ON COLUMN icon.seq IS NULL;
COMMENT ON COLUMN icon.deleted_at IS NULL;
COMMENT ON COLUMN icon.updated_at IS NULL;
COMMENT ON COLUMN icon.updated_by IS NULL;
COMMENT ON COLUMN icon.name IS NULL;
COMMENT ON COLUMN icon.content_sha256 IS NULL;
COMMENT ON COLUMN icon.icon_type IS NULL;

COMMENT ON TABLE currency IS NULL;
COMMENT ON COLUMN currency.uuid IS NULL;
COMMENT ON COLUMN currency.ledger_id IS NULL;
COMMENT ON COLUMN currency.seq IS NULL;
COMMENT ON COLUMN currency.deleted_at IS NULL;
COMMENT ON COLUMN currency.updated_at IS NULL;
COMMENT ON COLUMN currency.updated_by IS NULL;
COMMENT ON COLUMN currency.name IS NULL;
COMMENT ON COLUMN currency.iso_code IS NULL;
COMMENT ON COLUMN currency.icon_uuid IS NULL;
COMMENT ON COLUMN currency.symbol IS NULL;
COMMENT ON COLUMN currency."precision" IS NULL;

COMMENT ON TABLE currency_pair IS NULL;
COMMENT ON COLUMN currency_pair.uuid IS NULL;
COMMENT ON COLUMN currency_pair.ledger_id IS NULL;
COMMENT ON COLUMN currency_pair.seq IS NULL;
COMMENT ON COLUMN currency_pair.deleted_at IS NULL;
COMMENT ON COLUMN currency_pair.updated_at IS NULL;
COMMENT ON COLUMN currency_pair.updated_by IS NULL;
COMMENT ON COLUMN currency_pair.symbol IS NULL;
COMMENT ON COLUMN currency_pair.base_currency_uuid IS NULL;
COMMENT ON COLUMN currency_pair.quote_currency_uuid IS NULL;
COMMENT ON COLUMN currency_pair."precision" IS NULL;

COMMENT ON TABLE currency_pair_rate IS NULL;
COMMENT ON COLUMN currency_pair_rate.uuid IS NULL;
COMMENT ON COLUMN currency_pair_rate.ledger_id IS NULL;
COMMENT ON COLUMN currency_pair_rate.seq IS NULL;
COMMENT ON COLUMN currency_pair_rate.deleted_at IS NULL;
COMMENT ON COLUMN currency_pair_rate.updated_at IS NULL;
COMMENT ON COLUMN currency_pair_rate.updated_by IS NULL;
COMMENT ON COLUMN currency_pair_rate.currency_pair_uuid IS NULL;
COMMENT ON COLUMN currency_pair_rate."date" IS NULL;
COMMENT ON COLUMN currency_pair_rate.rate IS NULL;

COMMENT ON TABLE currency_conversion IS NULL;
COMMENT ON COLUMN currency_conversion.uuid IS NULL;
COMMENT ON COLUMN currency_conversion.ledger_id IS NULL;
COMMENT ON COLUMN currency_conversion.seq IS NULL;
COMMENT ON COLUMN currency_conversion.deleted_at IS NULL;
COMMENT ON COLUMN currency_conversion.updated_at IS NULL;
COMMENT ON COLUMN currency_conversion.updated_by IS NULL;
COMMENT ON COLUMN currency_conversion.from_currency_uuid IS NULL;
COMMENT ON COLUMN currency_conversion.to_currency_uuid IS NULL;
COMMENT ON COLUMN currency_conversion.num IS NULL;
COMMENT ON COLUMN currency_conversion.currency_pair_uuid IS NULL;
COMMENT ON COLUMN currency_conversion.is_reverse IS NULL;

COMMENT ON TABLE account IS NULL;
COMMENT ON COLUMN account.uuid IS NULL;
COMMENT ON COLUMN account.ledger_id IS NULL;
COMMENT ON COLUMN account.seq IS NULL;
COMMENT ON COLUMN account.deleted_at IS NULL;
COMMENT ON COLUMN account.updated_at IS NULL;
COMMENT ON COLUMN account.updated_by IS NULL;
COMMENT ON COLUMN account.name IS NULL;
COMMENT ON COLUMN account.comment IS NULL;
COMMENT ON COLUMN account.icon_uuid IS NULL;
COMMENT ON COLUMN account.is_archived IS NULL;

COMMENT ON TABLE account_operating IS NULL;
COMMENT ON COLUMN account_operating.uuid IS NULL;
COMMENT ON COLUMN account_operating.ledger_id IS NULL;
COMMENT ON COLUMN account_operating.seq IS NULL;
COMMENT ON COLUMN account_operating.deleted_at IS NULL;
COMMENT ON COLUMN account_operating.updated_at IS NULL;
COMMENT ON COLUMN account_operating.updated_by IS NULL;
COMMENT ON COLUMN account_operating.currency_uuid IS NULL;

COMMENT ON TABLE operation IS NULL;
COMMENT ON COLUMN operation.uuid IS NULL;
COMMENT ON COLUMN operation.ledger_id IS NULL;
COMMENT ON COLUMN operation.seq IS NULL;
COMMENT ON COLUMN operation.deleted_at IS NULL;
COMMENT ON COLUMN operation.updated_at IS NULL;
COMMENT ON COLUMN operation.updated_by IS NULL;
COMMENT ON COLUMN operation."date" IS NULL;
COMMENT ON COLUMN operation.acc_fr_uuid IS NULL;
COMMENT ON COLUMN operation.acc_to_uuid IS NULL;
COMMENT ON COLUMN operation.amount IS NULL;
COMMENT ON COLUMN operation.comment IS NULL;

COMMENT ON TABLE operation_link IS NULL;
COMMENT ON COLUMN operation_link.uuid IS NULL;
COMMENT ON COLUMN operation_link.ledger_id IS NULL;
COMMENT ON COLUMN operation_link.seq IS NULL;
COMMENT ON COLUMN operation_link.deleted_at IS NULL;
COMMENT ON COLUMN operation_link.updated_at IS NULL;
COMMENT ON COLUMN operation_link.updated_by IS NULL;
COMMENT ON COLUMN operation_link.main_uuid IS NULL;
COMMENT ON COLUMN operation_link.link_uuid IS NULL;
