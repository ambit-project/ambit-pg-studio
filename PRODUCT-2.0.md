# ambit.pg-studio.app 2.0 - PRODUCT

Mirror of the SDD project "ambit.pg-studio.app 2.0" (http://127.0.0.1:9494/wiki/sdd) - the wiki is the source of truth;
regenerate with `scripts/product-md.py`. Content in Polish (the wiki's language).

Stage: **Retro**

## Cele (co ma udowodnić)

- Formatowanie SQL nigdy nie zmienia znaczenia ani nie psuje wdrożenia Liquibase.
  - Done when: Formatowanie wszystkich changesetów runOnChange w ambit.wms.app/db, halycon.app.dev/db/changelog i ambit.jobtron.app/db: fingerprint libpg_query przed = po (SQL) i te same tokeny poza białymi znakami (PL/pgSQL), 0 utraconych komentarzy, drugie formatowanie = brak zmian; changesety już wdrożone (z datą, bez runOnChange) nie są ruszane. ./verify format
- Pisanie bazy jest szybsze niż w zwykłym edytorze: podpowiedzi, zmiana nazwy, nowy changeset z szablonu.
  - Done when: Podpowiedzi obiektów, kolumn po aliasie i parametrów CALL; rename z podglądem zmian; nowy obiekt/changeset z kolejnym numerem i id zgodnym z check-module-changesets.sh (skrypt przechodzi na wygenerowanym pliku). ./verify authoring
- Agent Claude Code korzysta z indeksu zamiast grepa.
  - Done when: pg_studio check (kod wyjścia, JSON) i serwer MCP (stdio) z narzędziami definicji, odwołań, grafu i problemów; na trzech repo wynik check = problemy z UI. ./verify cli
- Edytor instaluje się jak zwykła aplikacja na Debianie/Ubuntu.
  - Done when: Paczka .deb (dpkg -i) instaluje aplikację z libpg_query, ikoną i wpisem w menu, uruchamia się z menu i z terminala (pg-studio <katalog>), dpkg -r usuwa bez śladów; lintian bez błędów. ./verify package

## Nigdy

- Połączenie z bazą danych, wykonywanie SQL i uruchamianie Liquibase
- SQL Server / T-SQL

## Jeszcze nie

- Windows i macOS
- Formatowanie changesetów już wdrożonych (bez runOnChange) - zmiana sumy kontrolnej Liquibase
- Rozszerzenia/wtyczki innych firm

## Decyzje

- D1. Wersja 2.0 jako osobny projekt SDD w tym samym repo (ambit.pg-studio.app ma stan Done po MVP).
  - Dlaczego: Nowe cele i bramki bez ruszania zamkniętego MVP.
- D2. Formatowanie zmienia tylko białe znaki: własny formatter na tokenach (statementy: podziały linii autora, wcięcia wg klauzul/nawiasów/CASE, łamanie za długich linii; nagłówki routine: parametr i klauzula na linię; PL/pgSQL: wcięcia blokami). Deparser libpg_query NIE jest używany do formatowania (ADR 0004).
  - Dlaczego: Spike i pierwsza wersja z deparserem (2026-11-14): znaczenie zachowane, ale przesuwał komentarze (nawet do ARRAY[...]), przepisywał interval/::integer, upychał listy - pogorszył 69/69 widoków wms. Formatter tylko-białe-znaki: 0 odrzuceń na trzech repo, asn_save.sql bajt w bajt.
  - Wrócić, gdy: Gdy potrzebne będzie formatowanie kodu bez podziałów linii w ogóle (np. jedna długa linia z generatora) - łamanie linii to obecnie tylko klauzule i lista SELECT.
- D3. Bezpieczeństwo formatowania: wynik przyjęty tylko gdy fingerprint libpg_query się zgadza (SQL) albo strumień tokenów bez białych znaków jest identyczny (PL/pgSQL); inaczej plik zostaje bez zmian i jest komunikat.
  - Dlaczego: Formatowanie nie może zmienić logiki w bazie, w której cała logika żyje.
- D4. Formatowanie dotyczy tylko changesetów runOnChange (obiekty modułów) i plików, których nie ma jeszcze w main; zwykłe changesety z datą - odmowa z wyjaśnieniem.
  - Dlaczego: Liquibase sprawdza sumę kontrolną wdrożonego changesetu; check-module-changesets.sh --base zabrania ich modyfikacji.
- D5. Styl formatowania: AS przed aliasami tabel zostaje (jak w repo: FROM orders.purchase_orders AS o), przecinki na końcu linii.
  - Dlaczego: Decyzja właściciela (2026-11-14).
- D6. Zakres 2.0: wszystkie 14 specyfikacji, kolejność 001 formatowanie, 014 .deb, 011 CLI/MCP, 002 podpowiedzi, 006 reguły, potem 003-005, 007-010, 012, 013. Tylko .deb (bez AppImage/Flatpak).
  - Dlaczego: Decyzja właściciela (2026-11-14).
- D7. Spec 005 (kolumny) przed 003 (rename): zmiana nazwy kolumny potrzebuje odwołań do kolumn.
  - Dlaczego: Zależność techniczna; kolejność D6 poza tym bez zmian (2026-11-14).
- D8. Główny użytkownik 2.0: człowiek piszący projekt bazy ręcznie, bez agenta - aplikacja ma pomagać w pisaniu (kolumny, szablony, zmiana nazwy, wyszukiwanie). Zmiana nazwy zawsze z podglądem i ostrzeżeniami (wdrożone changesety, nowy changeset ALTER ... RENAME).
  - Dlaczego: Właściciel (2026-11-14): "chcę napisać projekt sam bez Kloda, ta apka mi pomoże"; rename przy pracy z agentem byłby rzadki.

## Specyfikacje

| Nr | Tytuł | Status | Kryteria Passed |
|---|---|---|---|
| 001 | Formatowanie SQL (plik, zaznaczenie, opcjonalnie przy zapisie) | Done | 4/4 |
| 002 | Podpowiedzi podczas pisania | Done | 2/2 |
| 003 | Zmiana nazwy obiektu i kolumny w całym projekcie | Done | 2/2 |
| 004 | Nowy obiekt i changeset z szablonu | Done | 1/1 |
| 005 | Odwołania do kolumn i analiza wpływu | Done | 2/2 |
| 006 | Pełne reguły check-module-changesets.sh jako problemy w edytorze | Done | 2/2 |
| 007 | Wyszukiwanie i zamiana w całym projekcie | Done | 1/1 |
| 008 | Historia obiektu i efektywny DDL | Done | 2/2 |
| 009 | Diagram ER tabel | Done | 1/1 |
| 010 | Zmiany na gałęzi względem main (przegląd pracy agenta) | Done | 1/1 |
| 011 | CLI i serwer MCP dla agenta Claude Code | Done | 2/2 |
| 012 | Dynamiczny SQL: odwołania z EXECUTE format(...) | Done | 1/1 |
| 013 | Sesja, ustawienia i cache indeksu | Done | 2/2 |
| 014 | Instalator .deb dla Debiana/Ubuntu | Done | 2/2 |
