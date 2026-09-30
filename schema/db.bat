@echo off
rem Разворачивание серверной схемы в локальную базу.
rem
rem Путь до apply.sql раньше указывал на ServerDataBase/ — папку, которой не
rem существует с тех пор, как репозиторий разложили по роли (docs, schema,
rem server, tools). Теперь путь относительный: файл лежит рядом с этим .bat.
rem
rem apply.sql идемпотентен только в части ролей; таблицы создаются с нуля,
rem поэтому по непустой базе он не пройдёт.
"c:/Program Files/PostgreSQL/18/bin/psql.exe" -U postgres -h 127.0.0.1 -d wallet_dev -v ON_ERROR_STOP=1 -f "%~dp0apply.sql"
