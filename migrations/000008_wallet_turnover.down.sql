-- Откат 000008_wallet_turnover.up.sql.
DROP FUNCTION IF EXISTS f_wallet_turnover_for_period(uuid, timestamp, timestamp);
