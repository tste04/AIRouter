# Security Policy

## Schwachstellen melden

Bitte **kein öffentliches GitHub-Issue** für Sicherheitslücken. Stattdessen:

- E-Mail an **[hello@tstellmacher.com](mailto:hello@tstellmacher.com)** mit
  Beschreibung, betroffener Version/Commit und — wenn möglich — einem
  Reproduktionsweg.
- Du erhältst innerhalb von 7 Tagen eine Antwort. Bitte gib uns Gelegenheit zur
  Behebung, bevor Details veröffentlicht werden (koordinierte Offenlegung).

## Sicherheitsmodell (Kurzfassung)

AIRouter verarbeitet Prompts und API-Credentials. Die wichtigsten Zusicherungen:

- **Kein Phone-Home**: keine Telemetrie, keine Lizenzserver, keine
  fest verdrahteten Remote-Endpoints. Jeder Netzkontakt geht an vom Nutzer
  konfigurierte Backends.
- **Strikte URL-Validierung**: Region/Projekt/Modellnamen laufen gegen
  Allowlists (kein Host-/Pfad-Injection mit Bearer-Token); lokale Endpoints
  nur `http`/`https` mit Host.
- **Klartext-Schutz für Keys**: `http://` akzeptieren die Cloud-Provider nur
  für Loopback-/private Hosts (Opt-out explizit via `allowInsecureHTTP`).
- **Begrenzte Antworten**: Response-Bodies sind im Standard-Transport auf
  50 MB begrenzt; Fehler-Bodies werden auf 500 Zeichen gekappt, bevor sie in
  Fehlern/Logs landen.
- **Budget-Integrität**: Reservierungs-Budget über eine monotone Uhr —
  Wanduhr-Sprünge können Limits weder zurücksetzen noch einfrieren; jeder
  Cloud-Pfad zahlt auf `budgetStatus()` ein.
- **Log-Härtung**: Datei-Logs mit `0600`, `os.Logger` mit `privacy: .private`.

Bekannte, bewusst akzeptierte Grenzen: Der persistierte Budget-Zustand
(`RouterStorage`) ist nicht integritätsgesichert (wer die Storage schreiben
kann, kann Budgets zurücksetzen), und Fehler-Bodies können Auszüge der
Backend-Antwort enthalten.

## Unterstützte Versionen

Sicherheitsfixes erfolgen auf `main`. Es gibt keine LTS-Zweige.
