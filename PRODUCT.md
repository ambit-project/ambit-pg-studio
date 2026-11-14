# ambit.pg-studio.app - PRODUCT

Mirror of the SDD project "ambit.pg-studio.app" (http://127.0.0.1:9494/wiki/sdd) - the wiki is the source of truth;
regenerate with `scripts/product-md.py`. Content in Polish (the wiki's language).

Stage: **Done**

## Cele (co ma udowodnić)

- Katalog bazy PostgreSQL (pliki SQL, changesety Liquibase) daje pełny indeks obiektów i odwołań bez połączenia z bazą.
  - Done when: Na ambit.jobtron.app/db, ambit.wms.app/db i halycon.app.dev/db/changelog indeksowanie kończy się bez wyjątku, 0 changesetów z błędem parsowania SQL i plpgsql (każdy wyjątek wyjaśniony w open), czas halycon zmierzony i < 5 s. ./verify corpus
- Z projektem bazy pracuje się jak z kodem C# w IDE: Ctrl+klik do definicji, Znajdź odwołania, podgląd sygnatury, szybkie wyszukiwanie, wstecz/naprzód.
  - Done when: Na ambit.wms.app/db: Ctrl+klik na wywołaniu platform.require_role otwiera jego definicję na właściwej linii; Znajdź odwołania dla orders.purchase_orders pokazuje odczyty i zapisy w kilku modułach; zrzuty w docs/screens/. ./verify nav
- Edycja plików SQL nie gubi pracy i od razu odświeża analizę.
  - Done when: Zapis Ctrl+S przeindeksowuje plik; zmiana pliku na dysku (np. przez agenta) przeindeksowuje go sama; przy niezapisanych zmianach w karcie aplikacja pyta zamiast nadpisać. ./verify editor
- Edytor zna konwencje naszego stacku: moduły nn-, kontrakt <moduł>_app, kody błędów U1xxx.
  - Done when: Ostrzeżenia o kolejności modułów i użyciu cudzych tabel / _internal zgadzają się z db/scripts/check-module-changesets.sh na trzech katalogach (te same pliki); lista ERRCODE zawiera U1445 z miejscem w orders_app.asn_save.sql. ./verify conventions

## Nigdy

- Połączenie z bazą danych, wykonywanie SQL i uruchamianie Liquibase
- Windows, macOS, web i mobile
- SQL Server / T-SQL

## Jeszcze nie

- Autouzupełnianie (nazwy obiektów, kolumn, parametrów)
- Zmiana nazwy obiektu we wszystkich plikach (rename)
- Formatowanie SQL

## Decyzje

- D1. Osobne publiczne repo ambit-project/ambit-pg-studio (licencja MIT).
  - Dlaczego: Decyzja właściciela (2026-11-14); projekt obok repo aplikacji, których katalogi bazy czyta.
- D2. Tylko desktop Linux, Flutter 3.47 / Dart 3.13.
  - Dlaczego: Decyzja właściciela; jedna platforma = jeden natywny build libpg_query.
  - Wrócić, gdy: Gdy będzie potrzebny Windows albo macOS.
- D3. Edycja i zapis plików w MVP, bez autouzupełniania i rename.
  - Dlaczego: Decyzja właściciela: pliki zmienia też agent Claude Code, edytor ma od razu pokazywać skutki.
- D4. Parser: libpg_query 18.1.0 przez dart:ffi (pg_query_parse, pg_query_parse_plpgsql, pg_query_scan), .so budowana z vendorowanego źródła i dołączona do bundla Linuksa.
  - Dlaczego: Prawdziwa gramatyka PostgreSQL 18. Spike 2026-11-14: 1149 plików z trzech repo w ~0,2 s; obejścia: podstawienia Liquibase ${...} zastępowane identyfikatorem tej samej długości, typy z innego schematu w parametrach i DECLARE podmieniane przed parserem plpgsql (LookupExplicitNamespace).
  - Wrócić, gdy: Gdy libpg_query przestanie nadążać za wersją PostgreSQL albo FFI okaże się kłopotliwe przy buildzie.
- D5. Konwencje stacku (moduły nn-, <moduł>_app / _internal, ERRCODE U1xxx) według db/scripts/check-module-changesets.sh; na katalogu bez tych konwencji funkcje po prostu nic nie pokazują.
  - Dlaczego: Decyzja właściciela; skrypt jest już źródłem reguł w repo aplikacji, edytor ma się z nim zgadzać.
- D6. MVP = indeks, drzewa plików i obiektów, edytor z kartami, definicja, odwołania, hover, szybkie wyszukiwanie, obserwacja dysku, graf zależności, konwencje stacku.
  - Dlaczego: Decyzja właściciela (2026-11-14).
- D7. Analiza w czystym Dart (lib/core, bez Fluttera) w osobnym isolate; UI tylko czyta wynik.
  - Dlaczego: Testy bez UI (flutter test na core), UI nie zamarza przy dużym katalogu.

## Działa dziś

- Otwarcie katalogu bazy bez połączenia: indeks obiektów i odwołań (halycon 901 plików ~0,1-0,3 s, 0 błędów na trzech repo).
- Drzewa: pliki, obiekty po schematach, obiekty po modułach (kontrakt _app); filtr.
- Edytor z podświetlaniem z libpg_query i nakładkami z indeksu; Ctrl+klik/F12, Shift+F12 (odczyty/zapisy), podpowiedź, Ctrl+T/Ctrl+P, Alt+←/→.
- Edycja z Ctrl+S, błędy na żywo, obserwacja dysku z pytaniem przy konflikcie; pytanie o niezapisane przy zamykaniu karty i okna.
- Konwencje stacku: ostrzeżenia granic i kolejności modułów zgodne z check-module-changesets.sh, kontrakt, kody ERRCODE.
- Graf zależności obiektu i graf modułów.

## Dalej

- Bramka MVP → Features (zatwierdza właściciel w UI wiki).
- Kandydaci na Features: autouzupełnianie, rename, wyszukiwanie w treści wszystkich plików, odwołania w EXECUTE format(...), publiczne repo na GitHubie (ambit-project/ambit-pg-studio, zrobione).

## Specyfikacje

| Nr | Tytuł | Status | Kryteria Passed |
|---|---|---|---|
| 001 | Szkielet aplikacji i libpg_query przez FFI | Done | 3/3 |
| 002 | Indeks obiektów i odwołań (core) | Done | 4/4 |
| 003 | Konwencje stacku: moduły, kontrakt _app, kody błędów | Done | 3/3 |
| 004 | Okno projektu: otwarcie katalogu, drzewa, edytor z kartami, problemy | Done | 2/2 |
| 005 | Nawigacja jak w IDE | Done | 4/4 |
| 006 | Edycja, zapis i obserwacja dysku | Done | 3/3 |
| 007 | Graf zależności | Done | 2/2 |
