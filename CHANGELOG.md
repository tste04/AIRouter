# Changelog

Format nach [Keep a Changelog](https://keepachangelog.com/de/1.1.0/);
Versionierung nach [SemVer](https://semver.org/lang/de/), sobald das erste
Release getaggt ist. Bis dahin sammelt `Unreleased` den Stand von `main`.

## [Unreleased]

### Geändert
- Lizenz: MIT — frei nutzbar, auch kommerziell. Die kommerziellen
  Lizenz-Dokumente (`COMMERCIAL.md`, `LICENSING.md`, CLA) sind entfernt;
  Beiträge gelten als unter der Projektlizenz eingereicht (inbound = outbound).

### Hinzugefügt
- `healthStatus()`, `availableModels()`, `flushPersistence()`,
  `currentEnergyMode`/`isAirplaneMode`/`localModelName`-Getter.
- `setBreakerParameters(...)`, `setBudgetWindow(seconds:)`,
  `BudgetStatus.costBudgetUSD`/`costUtilization`.
- Kontextfenster-Prüfung (`contextWindowExceeded`) vor dem Versand.
- Raw-Streaming `sendStreaming(model:...)`; Budget-Warteschlange auch für
  Streaming; `GenerationOptions` in allen Single-Turn-Overloads.
- Codable/Equatable/CaseIterable-Konformitäten auf Konfigurationstypen.
- CI: zusätzlicher iOS-Build-Job.
- Task-basiertes Routing über Energiemodi (`maxCloud`/`fullPower`/`offline`/`powerSave`)
  und Routing-Policies (`cloudOnly`/`preferCloud`/`preferLocal`/`localOnly`).
- Vertex AI (Anthropic `:rawPredict`, Google `:generateContent`) mit
  Modell-Fallback (404), Token-Refresh (401) und Retry mit Backoff+Jitter.
- `CloudInferenceProvider`-Protokoll mit `OpenAICompatibleProvider`
  (OpenAI/Azure/Groq/vLLM/…) und `AnthropicDirectProvider`.
- Lokale Inferenz: `LocalInferenceProvider`-Protokoll und Ollama (`/api/chat`)
  inkl. Modell-Auto-Discovery.
- Multi-Turn-Konversationen (`AIMessage`) und `GenerationOptions`
  (Temperatur, top-p/k, Stop-Sequenzen, `jsonMode`, `requestTimeout`).
- Natives Cloud-Streaming via SSE inkl. Budget-Reservierung.
- Reservierungs-Budget (Tokens/Stunde) mit prioritätsbasiertem Throttling und
  Fenster-Epoche (Reservierungen überstehen den Stunden-Reset unversehrt);
  USD-Kosten-Budget inkl. in-flight-Reservierung; optionale Warteschlange
  (`setQueueOnBudgetExhausted`); Persistenz (`RouterStorage`, serialisierte
  Snapshots). Gilt auf allen Pfaden, auch dem rohen Modell-Pfad.
- Retries für HTTP 429/5xx und transiente Transportfehler (Backoff + Jitter);
  404-Modell-Fallback mit Zyklus-Schutz.
- Offline-Garantie: `airplaneMode`/`.offline` und `localOnly` schlagen
  Modell-Overrides und Energiemodus; im Flugmodus führt kein Pfad ins Netz.
- Circuit-Breaker pro Modell, Opt-in-Antwort-Cache, Konkurrenzlimit für
  Cloud-Aufrufe, Latenz-/Fehler-Statistik (`modelStats()`).
- Kosten-Telemetrie aus Katalog-Preisen (`AIUsageInfo.costUSD`,
  `BudgetStatus.costUSD`) und PII-Preflight-Hook (`setCloudPreflight`).
- Event-Hook `setEventCallback(_:)`: Fallbacks, Budget-Drosselung,
  Breaker-Zustandswechsel, Retries und Cache-Treffer als typisierte
  `RouterEvent`-Werte.
- `resetModelStats()`; `localEndpoint`-Property (ersetzt das deprecatede
  `localLLMEndpointValue()`).
- DocC-Katalog mit Artikeln zu Routing sowie Budgets und Kosten.

### Sicherheit
- Allowlist-Validierung für Region/Projekt/Modellnamen und lokale Endpoints;
  `http://` für Cloud-Provider nur zu Loopback-/privaten Hosts (echte
  IPv4-Prüfung, keine Präfix-Heuristik).
- Response-Größenlimit (50 MB) für Daten- und Streaming-Transport; Fehler-Bodies
  auf 500 Zeichen gekappt; Datei-Logs `0600`; monotone Budget-Uhr.

### Infrastruktur
- CI (GitHub Actions): macOS-Build + Tests (komplett mock-basiert, ohne Netz)
  und iOS-Build bei jedem Push und PR; Compiler-Warnungen brechen den Build
  (-warnings-as-errors).
- Swift 5.7+ (Xcode 14.1+), macOS 13+ / iOS 16+, keine externen Dependencies.
