-- Откат 000029_sync_load_base_seq.up.sql.
ALTER TABLE device
    DROP COLUMN reference_load_base_seq,
    DROP COLUMN ledger_load_base_seq;
