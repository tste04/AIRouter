# Contributing

Issues und Pull Requests sind willkommen.

## Lizenz

AIRouter steht unter der [MIT-Lizenz](LICENSE). Beiträge gelten wie üblich als
unter der Projektlizenz eingereicht (inbound = outbound) — es gibt kein CLA.

## Praktisches

- Build: `swift build` (macOS 13+ / Xcode 14.1+, Swift 5.7+).
- Tests: `swift test` — alle Tests laufen gegen Mocks, ohne Netz und ohne
  Credentials; das muss so bleiben. CI (macOS-Test + iOS-Build) muss grün sein.

## Invarianten

PRs, die eine der folgenden Zusagen aufweichen, werden abgelehnt:

- Kein Phone-Home: keine Telemetrie, keine fest verdrahteten Remote-Endpoints.
  Auth (`accessTokenProvider`) und Transport (`HTTPTransport`) bleiben injizierbar.
- Die Allowlists in `RouterValidation` (Region, Projekt, Modellnamen, Endpoints)
  werden nicht gelockert; unbekannte Modelle scheitern laut.
- Jeder Cloud-Pfad zahlt aufs Budget ein — kein neuer Aufrufweg darf an
  `budgetStatus()` vorbeilaufen.
