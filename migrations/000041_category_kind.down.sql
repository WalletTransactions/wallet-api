-- Откат 000041: колонка category_kind (вместе со своим CHECK) удаляется.
-- Остальные данные account не меняются; seq строк, которые разметка двинула,
-- не возвращается — поток изменений только растёт.
ALTER TABLE account DROP COLUMN category_kind;
