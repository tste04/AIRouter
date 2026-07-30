# Changelog

Format nach [Keep a Changelog](https://keepachangelog.com/de/1.1.0/);
Versionierung nach [SemVer](https://semver.org/lang/de/), sobald das erste
Release getaggt ist. Bis dahin sammelt `Unreleased` den Stand von `main`.

## [Unreleased]

### Hinzugefügt
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
- Reservierungs-Budget (Tokens/Stunde) mit prioritätsbasiertem Throttling,
  zusätzlichem USD-Kosten-Budget, optionaler Warteschlange
  (`setQueueOnBudgetExhausted`) und Persistenz (`RouterStorage`).
- Circuit-Breaker pro Modell, Opt-in-Antwort-Cache, Konkurrenzlimit für
  Cloud-Aufrufe, Latenz-/Fehler-Statistik (`modelStats()`).
- Kosten-Telemetrie aus Katalog-Preisen (`AIUsageInfo.costUSD`,
  `BudgetStatus.costUSD`) und PII-Preflight-Hook (`setCloudPreflight`).

### Sicherheit
- Allowlist-Validierung für Region/Projekt/Modellnamen und lokale Endpoints;
  `http://` für Cloud-Provider nur zu Loopback-/privaten Hosts.
- Response-Größenlimit (50 MB) im Standard-Transport; Fehler-Bodies auf
  500 Zeichen gekappt; Datei-Logs `0600`; monotone Budget-Uhr.

### Infrastruktur
- CI (GitHub Actions, macOS): `swift build` + `swift test` (47 mock-basierte
  Tests, ohne Netz) bei jedem Push und PR.
- Swift 5.7+ (Xcode 14.1+), macOS 13+ / iOS 16+, keine externen Dependencies.
