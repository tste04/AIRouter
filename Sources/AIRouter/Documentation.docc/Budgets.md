# Budgets und Kosten

Wie der Router Verbrauch reserviert, deckelt und abrechnet.

## Overview

Cloud-Aufrufe laufen gegen zwei Grenzen pro Stundenfenster: ein
**Token-Budget** (`setHourlyBudget(_:)`, Default 200.000) und optional ein
**Kosten-Budget in USD** (`setHourlyCostBudget(usd:)`, berechnet aus den
Katalog-Preisen). Beide arbeiten mit **Reservierung**: Vor dem Netzaufruf wird
die Schätzung (Input-Zeichen/4 + `maxTokens`) reserviert, nach der Antwort mit
den echten Zählern verrechnet. Parallele Aufrufe können eine Grenze dadurch
nicht gemeinsam durchbrechen.

Reservierungen tragen eine **Fenster-Epoche**: Läuft das Stundenfenster ab,
während ein Aufruf unterwegs ist, kann dessen Abrechnung die Reservierungen
des neuen Fensters nicht verfälschen.

## Prioritäten

Das Throttling staffelt nach ``AITaskPriority``:

| Priorität | Token-Ceiling |
| --- | --- |
| `low` | 75 % des Budgets |
| `normal` | 90 % |
| `high` | 100 % |
| `critical` | keine Grenze (reserviert aber sichtbar) |

Gedrosselte Aufrufe werfen ``AIRouterError/budgetExhausted(task:)`` — oder
warten mit `setQueueOnBudgetExhausted(true)` aufs nächste Fenster. Existiert
ein lokales Backend, wechselt der Router stattdessen dorthin.

## Beobachten und Persistieren

- `budgetStatus()` liefert Verbrauch, Reservierungen, USD-Kosten und
  `secondsUntilReset` (monotone Uhr — Wanduhr-Sprünge verfälschen nichts).
- ``AIUsageInfo/costUSD`` weist die Kosten pro Aufruf aus.
- Mit einem ``RouterStorage`` überlebt der Zählerstand App-Neustarts;
  `flushPersistence()` wartet vor Terminierung auf den letzten Snapshot.
