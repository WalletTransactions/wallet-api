-- Проставляет updated_at при любом UPDATE синхронизируемой строки.
--
-- updated_at — колонка для диагностики и только: порядок изменений задаёт seq,
-- и ни одно решение о конфликте по времени не принимается. Триггер нужен, чтобы
-- колонка не врала — иначе забытый в одном месте SET updated_at = now() делает
-- её бесполезной ровно тогда, когда по ней разбирают инцидент.
CREATE FUNCTION set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;
