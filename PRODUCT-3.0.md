# ambit.pg-studio.app 3.0 - PRODUCT

Mirror of the SDD project "ambit.pg-studio.app 3.0" (http://127.0.0.1:9494/wiki/sdd) - the wiki is the source of truth;
regenerate with `scripts/product-md.py`. Content in Polish (the wiki's language).

Stage: **Mvp**

## Cele (co ma udowodnić)

- Wszystko, co edytor umie, da się znaleźć bez znajomości skrótów: menu pod prawym przyciskiem, pomoc (F1) i paleta poleceń pokazują te same polecenia z jednego rejestru, z opisem i skrótem.
  - Done when: Test: każde polecenie z rejestru ma nazwę, opis i miejsce (edytor, drzewo, karta, panel); każdy skrót z pomocy działa, a każdy działający skrót jest w pomocy; menu kontekstowe w edytorze, drzewach, kartach i panelach. ./verify ui
- Praca nad bazą bez wychodzenia z aplikacji: terminal w katalogu projektu (git, liquibase, pg-studio check, claude), a pliki zmienione z terminala od razu w indeksie.
  - Done when: Test: terminal startuje powłokę użytkownika w katalogu projektu, ścieżki plik.sql:linia w wyjściu otwierają plik, zamknięcie karty kończy proces, plik zapisany z terminala jest w indeksie; .deb z terminalem przechodzi test w czystych kontenerach. ./verify terminal, ./verify package

## Nigdy

- Połączenie z bazą danych z kodu aplikacji (analiza, podpowiedzi, menu) - także w 3.0
- SQL Server / T-SQL

## Jeszcze nie

- Podział terminala na panele, terminal zdalny (ssh) jako funkcja aplikacji, zapisywanie historii terminala między uruchomieniami
- Własne menu i skróty definiowane przez użytkownika (keymap)

## Decyzje

- Jeden rejestr poleceń (id, nazwa, opis, skrót, gdzie dostępne, kiedy aktywne) zasila skróty, menu kontekstowe, pomoc i paletę; nowe polecenie dodaje się w jednym miejscu.
  - Dlaczego: Dziś skróty są w mapie home_page.dart, a opisy w tooltipach i README - rozjeżdżają się. Z jednego źródła pomoc nie może kłamać, a test pilnuje kompletności.
- Terminal: xterm.dart (TerminalView) + flutter_pty, powłoka z $SHELL (domyślnie /bin/bash) w katalogu otwartego folderu.
  - Dlaczego: Dojrzały emulator z obsługą ANSI i alt screen w czystym Flutterze; pty daje prawdziwą powłokę (vim, less, claude działają). Do sprawdzenia: licencje i natywna biblioteka pty w paczce .deb.
- Aplikacja nadal nigdy sama nie łączy się z bazą; terminal to powłoka użytkownika - to, co w niej wpisze (psql, liquibase update), jest jego decyzją.
  - Dlaczego: Zasada 'bez połączenia' dotyczy analizy i funkcji edytora; terminal nie dodaje do aplikacji żadnego kodu łączącego się z bazą.

## Specyfikacje

| Nr | Tytuł | Status | Kryteria Passed |
|---|---|---|---|
| 001 | Rejestr poleceń i menu pod prawym przyciskiem | Done | 3/3 |
| 002 | Pomoc: przycisk ? i F1 | Done | 3/3 |
| 003 | Terminal w dolnym panelu | Done | 4/4 |
| 004 | Paleta poleceń (propozycja) | Done | 1/1 |
