# AIRouter

Ein eigenständiges Swift-Package mit einem zentralen Router, der KI-Aufgaben
anhand von **Energiemodus**, **Routing-Policy** und **Token-/Kosten-Budget** auf
Cloud-Modelle (Vertex AI: Anthropic & Google — sowie beliebige weitere Backends
über das `CloudInferenceProvider`-Protokoll, z. B. OpenAI-kompatible APIs oder
Anthropic direkt) oder lokale Modelle (In-Process-Provider oder Ollama-HTTP)
verteilt.

Keine Auth-Strategie und kein Cloud-Projekt sind fest verdrahtet:
Authentifizierung, lokales Backend und Modell-/Routing-Konfiguration werden
vollständig von außen injiziert.

**Lizenz:** PolyForm Noncommercial 1.0.0 — nichtkommerziell frei, kommerziell
kostenpflichtig (siehe [Lizenz](#lizenz) / [COMMERCIAL.md](COMMERCIAL.md)).

## Inhalt

- [Funktionen](#funktionen)
- [Installation](#installation)
- [Schnellstart](#schnellstart)
- [Authentifizierung gegen Vertex AI](#authentifizierung-gegen-vertex-ai)
- [Eigener In-Process-Provider](#eigener-in-process-provider)
- [Eigene Modelle & Overrides](#eigene-modelle--overrides)
- [Testen ohne Netz](#testen-ohne-netz)
- [Budget & Telemetrie](#budget--telemetrie)
- [Erweiterte Funktionen](#erweiterte-funktionen)
- [Weitere Cloud-Provider](#weitere-cloud-provider-openai-kompatibel-anthropic-direkt-eigene)
- [Betrieb: Budgets, Persistenz, Backpressure](#betrieb-budgets-persistenz-backpressure)
- [Sicherheit](#sicherheit)
- [Modulübersicht](#modulübersicht)
- [Anforderungen](#anforderungen) · [Build & Test](#build--test)
- [Lizenz](#lizenz) · [Beiträge](#beiträge)

## Funktionen

| Bereich | Funktion |
| --- | --- |
| **Aufgaben-Routing** | `send(task:system:user:)` wählt Modell anhand `AITask` (vordefinierte Aufgaben mit Default-Modell, Token-Budget, Priorität, Policy). |
| **Energiemodi** | `setEnergyMode(_:)` — `maxCloud`, `fullPower`, `offline`, `powerSave` steuern Cloud-vs-Lokal-Verhalten global. |
| **Routing-Policies** | Pro Aufgabe `cloudOnly` / `preferCloud` / `preferLocal` / `localOnly`, überschreibbar via `taskRoutingPolicies`. |
| **Cloud ↔ Lokal-Fallback** | Automatischer Wechsel bei Fehlern oder erschöpftem Budget. |
| **Vertex AI** | Anthropic (`:rawPredict`) und Google (`:generateContent`); Modell-Fallback bei HTTP 404, Token-Refresh bei HTTP 401, Retry mit Backoff. |
| **Eigene Cloud-Provider** | `CloudInferenceProvider`-Protokoll + `registerCloudProvider(_:)`; mitgeliefert: `OpenAICompatibleProvider` (OpenAI, Azure, Groq, vLLM, …) und `AnthropicDirectProvider`. Budget, Breaker, Retry, Preflight und Kosten bleiben beim Router. |
| **Lokale Inferenz** | `LocalInferenceProvider`-Protokoll (eigenes On-Device-Modell) **oder** Ollama (`/api/chat`), mit Auto-Erkennung installierter Ollama-Modelle. |
| **Streaming** | `sendStreaming(task:…)` liefert Token-weise: In-Process, Ollama-NDJSON und Cloud nativ via SSE (`:streamRawPredict` / `:streamGenerateContent?alt=sse`), inkl. Budget-Reservierung. |
| **Multi-Turn & Optionen** | `send(task:system:messages:options:)` mit `AIMessage`-Verlauf und `GenerationOptions` (Temperatur, top-p/k, Stop-Sequenzen, `jsonMode`, `requestTimeout`) auf allen Pfaden. |
| **JSON-Mode** | `GenerationOptions(jsonMode: true)` — strukturierte Ausgabe via Google `responseMimeType`, OpenAI `response_format`, Ollama `format: json`. |
| **Circuit-Breaker** | Nach 3 Fehlern in Folge wird ein Modell 60 s gemieden (Fallback-Kette, sonst `circuitOpen`). |
| **Antwort-Cache** | `enableResponseCache(tasks:ttlSeconds:maxEntries:)` — opt-in für idempotente Tasks, Schlüssel = vollständige Anfrage. |
| **Kosten-Telemetrie** | Katalog-Preise (USD/MTok) ergeben `AIUsageInfo.costUSD` pro Aufruf und `BudgetStatus.costUSD` pro Stunde. |
| **PII-Preflight** | `setCloudPreflight(_:)` transformiert System-Prompt und Nachrichten vor jedem Cloud-Versand (z. B. Redaktion); lokale Aufrufe bleiben unberührt. |
| **Retry-Policy** | `RetryPolicy(maxTransientRetries:baseDelay:)` im Initializer steuert Backoff für HTTP 429/5xx. |
| **Token-Budget** | `setHourlyBudget(_:)` + `budgetStatus()`; Reservierungs-Budget (kein TOCTOU): Schaetzung wird vor dem Netzaufruf reserviert und nach Antwort mit echten Tokenzahlen verrechnet. Throttling nach Priorität (critical umgeht Budget). |
| **Kosten-Budget (USD)** | `setHourlyCostBudget(usd:)` — zusätzliche Stunden-Grenze in USD auf Basis der Katalog-Preise. |
| **Budget-Warteschlange** | `setQueueOnBudgetExhausted(true)` — Cloud-Aufrufe warten aufs nächste Stundenfenster statt zu werfen (wenn kein lokales Fallback existiert). |
| **Persistenz** | `RouterStorage`-Protokoll + `configureStorage(_:)` — Budget-Zustand überlebt App-Neustarts (kein Budget-Reset per Neustart). |
| **Konkurrenzlimit** | `setMaxConcurrentCloudCalls(_:)` — Backpressure für parallele Cloud-Aufrufe (Default 8). |
| **Modell-Statistik** | `modelStats()` — Aufrufe, Fehler und Ø-Latenz pro Modell seit Prozessstart. |
| **Telemetrie** | `setUsageCallback(_:)` liefert `AIUsageInfo` (Modell, Tokens, Dauer, `isEstimated`, `costUSD`) pro Aufruf — auch beim Streaming. |
| **Injizierbare Auth** | `accessTokenProvider`-Closure liefert ein `AccessToken` (Wert + `expiresAt`); keine Auth-Strategie und keine feste TTL sind verdrahtet. |
| **Injizierbarer Transport** | `transport: HTTPTransport` ist austauschbar (Default `URLSession`), wodurch der Router ohne echtes Netz testbar ist. |
| **Modellkatalog** | Bekannte Modelle inkl. Upgrade-/Fallback-Kanten stehen im `ModelCatalog`; eigene Modelle via `additionalModels`. Unbekannte Modelle führen zu `AIRouterError.notConfigured` statt stiller Fehl-Zuordnung. |
| **Logging** | `DebugLog` über `os.Logger`, optional in Datei (`DebugLog.configure(filePath:)`). |

## Installation

In `Package.swift`:

```swift
.package(path: "../AIRouter")
```

oder als Git-Abhängigkeit:

```swift
.package(url: "https://github.com/tste04/AIRouter.git", from: "1.0.0")
```

und im Target:

```swift
.product(name: "AIRouter", package: "AIRouter")
```

## Schnellstart

```swift
import AIRouter

let router = AIRouter(
    vertexRegion: "<deine-region>",
    vertexProject: "<dein-projekt>",
    accessTokenProvider: {
        // Liefert ein AccessToken (Wert + Ablaufzeitpunkt) fuer Vertex AI.
        try await tokenSource.fetchAccessToken()
    }
)

await router.setEnergyMode(.fullPower)

// Optional: lokales Ollama-Backend (Modell wird automatisch erkannt, wenn "")
await router.configureLocalLLM(endpoint: "http://localhost:11434", model: "")

let antwort = try await router.send(
    task: .meetingSummary,
    system: "Du bist ein praeziser Zusammenfasser.",
    user: "Eingabetext: …"
)
```

### Streaming

```swift
for try await chunk in await router.sendStreaming(task: .advisorRealtime,
                                                  system: "…",
                                                  user: "…") {
    print(chunk, terminator: "")
}
```

## Authentifizierung gegen Vertex AI

Der Router enthält **bewusst keine** eingebaute Auth-Logik. Cloud-Aufrufe
benötigen einen `accessTokenProvider`, der ein gültiges `AccessToken`
(OAuth2-Tokenwert plus Ablaufzeitpunkt) liefert. Anhand von `expiresAt`
cacht der Router das Token und fordert es erst nach Ablauf neu an — eine fest
verdrahtete TTL gibt es nicht. Die Token-Quelle ist frei wählbar — z. B. ein
Service-Account, ein Metadata-Server, ein eigener Token-Cache oder ein
CLI-Aufruf in deiner App.

```swift
let router = AIRouter(
    vertexRegion: "<deine-region>",
    vertexProject: "<dein-projekt>",
    accessTokenProvider: {
        let raw = try await meinTokenProvider.fetch()
        return AccessToken(value: raw.token, expiresAt: raw.expiry)
        // oder: AccessToken(value: raw.token, lifetime: 3600)
    }
)
```

Ohne `accessTokenProvider` schlagen Cloud-Aufrufe mit `AIRouterError.notConfigured`
fehl. Rein lokale Nutzung (Ollama / `LocalInferenceProvider`) funktioniert ohne
Token-Provider.

## Eigener In-Process-Provider

Für On-Device-Inferenz ein beliebiges lokales Sprachmodell hinter dem Protokoll
`LocalInferenceProvider` einbinden:

```swift
struct MyLocalLLM: LocalInferenceProvider {
    var isReady: Bool { get async { true } }

    func generate(system: String, user: String, maxTokens: Int) async throws
        -> (text: String, inputTokens: Int, outputTokens: Int) {
        // eigenes Modell aufrufen …
    }

    func generateStream(system: String, user: String, maxTokens: Int)
        -> AsyncThrowingStream<String, Error> {
        // token-weises Streaming …
    }
}

await router.configureLocalProvider(MyLocalLLM())
```

## Eigene Modelle & Overrides

`taskModels` und `taskRoutingPolicies` sind typisiert und überschreiben pro
Aufgabe das Default-Modell bzw. die Policy. Eigene Modelle werden über
`additionalModels` registriert — inkl. Upgrade-/Fallback-Kanten. Nicht
registrierte Modelle werfen `AIRouterError.notConfigured` statt still als
Anthropic/Google geraten zu werden.

```swift
let router = AIRouter(
    vertexRegion: "<deine-region>",
    vertexProject: "<dein-projekt>",
    taskModels: [.factCheck: "claude-sonnet-4-6"],
    taskRoutingPolicies: [.meetingSummary: .preferLocal],
    accessTokenProvider: { try await tokenSource.fetchAccessToken() },
    additionalModels: [
        "gemini-2.5-flash-lite": ModelDescriptor(
            provider: .google,
            upgradesTo: "gemini-2.5-flash",
            fallsBackTo: nil
        )
    ]
)
```

## Testen ohne Netz

Der HTTP-Transport ist über das `HTTPTransport`-Protokoll injizierbar (Default
`URLSessionTransport`). In Tests lässt sich ein Mock einsetzen, der Status-Codes
und Antworten skriptet — so sind Budget, Retry/Fallback und Telemetrie ohne
echte Cloud-Aufrufe prüfbar.

```swift
let router = AIRouter(
    vertexRegion: "us-central1",
    vertexProject: "demo",
    accessTokenProvider: { AccessToken(value: "test", lifetime: 3600) },
    transport: MockTransport(/* skriptete Antworten */)
)
```

## Budget & Telemetrie

```swift
await router.setHourlyBudget(500_000)

await router.setUsageCallback { info in
    print("\(info.model): in=\(info.inputTokens) out=\(info.outputTokens) \(info.durationMs)ms")
}

let status = await router.budgetStatus()
print("Genutzt: \(status.tokensUsed)/\(status.tokenBudget) (\(Int(status.utilization * 100))%)")
```

## Erweiterte Funktionen

```swift
// Multi-Turn-Konversation mit Sampling-Optionen
let antwort = try await router.send(
    task: .memoryQuery,
    system: "Du bist ein hilfreicher Assistent.",
    messages: [
        .user("Was war unser letztes Thema?"),
        .assistant("Wir sprachen über das Q3-Budget."),
        .user("Fasse die offenen Punkte zusammen.")
    ],
    options: GenerationOptions(temperature: 0.2, stopSequences: ["###"])
)

// Natives Cloud-Streaming (SSE) — Budget wird reserviert und verrechnet
for try await chunk in await router.sendStreaming(
    task: .meetingSummary, system: "…", messages: [.user("…")]
) {
    print(chunk, terminator: "")
}

// Antwort-Cache für idempotente Klassifikations-Tasks (opt-in)
await router.enableResponseCache(tasks: [.emailRelevance, .sentimentAnalysis], ttlSeconds: 300)

// PII-Redaktion vor jedem Cloud-Versand (lokale Aufrufe bleiben unberührt)
await router.setCloudPreflight { text in
    text.replacingOccurrences(of: kundennummerRegex, with: "[KUNDE]", options: .regularExpression)
}

// Kosten im Blick: pro Aufruf und pro Stunde
await router.setUsageCallback { info in
    if let cost = info.costUSD { print("\(info.model): $\(cost)") }
}
let status = await router.budgetStatus()
print("Diese Stunde: $\(status.costUSD)")
```

**Circuit-Breaker:** Meldet ein Modell wiederholt Fehler (429/5xx/Transportfehler,
3× in Folge), wird es für 60 Sekunden gemieden. Existiert eine Fallback-Kante im
Katalog, springt der Router automatisch dorthin; sonst wirft er
`AIRouterError.circuitOpen(model:)`, statt weiter gegen ein totes Modell zu laufen.

## Weitere Cloud-Provider (OpenAI-kompatibel, Anthropic direkt, eigene)

Modelle mit `provider: .custom("<id>")` werden an den unter dieser ID
registrierten `CloudInferenceProvider` geleitet. Budget, Circuit-Breaker,
Retry-Policy, PII-Preflight und Kosten-Telemetrie wendet weiterhin der Router
an — der Provider implementiert nur Transport, Auth und Parsing.

```swift
let router = AIRouter(
    vertexRegion: "us-central1",
    vertexProject: "mein-projekt",
    taskModels: [.factCheck: "gpt-4o-mini", .dossierSynthesis: "claude-opus-4-6-direct"],
    additionalModels: [
        "gpt-4o-mini": ModelDescriptor(
            provider: .custom("openai"),
            inputCostPerMTok: 0.15, outputCostPerMTok: 0.60),
        "claude-opus-4-6-direct": ModelDescriptor(
            provider: .custom("anthropic"),
            inputCostPerMTok: 15, outputCostPerMTok: 75)
    ]
)

// OpenAI-kompatibel: OpenAI, Azure OpenAI, Groq, Together, vLLM, LM Studio, …
await router.registerCloudProvider(OpenAICompatibleProvider(
    baseURL: "https://api.openai.com/v1",
    apiKeyProvider: { try await keychain.openAIKey() }
))

// Anthropic direkt (ohne Vertex-Umweg)
await router.registerCloudProvider(AnthropicDirectProvider(
    apiKeyProvider: { try await keychain.anthropicKey() }
))
```

Eigene Backends implementieren das Protokoll selbst (`generate` + `stream`).

## Betrieb: Budgets, Persistenz, Backpressure

```swift
// Zusätzlich zum Token-Budget: harte Kosten-Grenze in USD pro Stunde.
await router.setHourlyCostBudget(usd: 2.50)

// Statt budgetExhausted zu werfen: aufs nächste Stundenfenster warten
// (greift nur, wenn kein lokales Fallback existiert; abbrechbar via Cancellation).
await router.setQueueOnBudgetExhausted(true)

// Budget-Zustand über App-Neustarts hinweg halten (eigenes Speichermedium).
await router.configureStorage(MyUserDefaultsStorage())

// Max. parallele Cloud-Aufrufe (Backpressure), Default 8.
await router.setMaxConcurrentCloudCalls(4)

// Latenz-/Fehler-Statistik pro Modell (z. B. für ein Debug-Panel).
for stat in await router.modelStats() {
    print("\(stat.model): \(stat.calls) Aufrufe, \(stat.failures) Fehler, Ø \(stat.averageLatencyMs) ms")
}

// Deadline & strukturierte Ausgabe pro Aufruf
let json = try await router.send(
    task: .entityExtraction,
    system: "Extrahiere Entitäten als JSON.",
    messages: [.user(text)],
    options: GenerationOptions(jsonMode: true, requestTimeout: 15)
)
```

## Sicherheit

Der Router validiert alle Werte, die in Request-URLs interpoliert werden, gegen
strikte Allowlists:

- **`vertexRegion`** (landet im *Hostnamen*): nur `a-z`, `0-9`, `-`. Verhindert,
  dass eine manipulierte Region (z. B. aus Remote-Config) Requests samt
  Bearer-Token auf einen fremden Host umleitet.
- **`vertexProject`**: nur `a-z`, `0-9`, `-`, `.`, `:` (Legacy-Format
  `example.com:project` bleibt möglich).
- **Modellnamen**: Buchstaben, Ziffern, `-`, `.`, `_`, `@` — kein `/`, keine
  Pfad-Injection über `additionalModels`/`taskModels`.
- **Lokale Endpoints** (`configureLocalLLM`): nur `http`/`https` mit Host;
  ungültige Endpoints (z. B. `file://`) werden verworfen und aktivieren die
  lokale Inferenz nicht.

Weitere Härtungen:

- **Budget-Reset über monotone Uhr** (`ContinuousClock`): Wanduhr-Sprünge können
  das Stundenbudget weder vorzeitig zurücksetzen noch einfrieren.
- **Auch `send(model:…)` (roher Modell-Pfad) zählt auf `budgetStatus()` ein** —
  kein stiller Kosten-Bypass an der Task-Abstraktion vorbei.
- **Fehler-Bodies sind auf 500 Zeichen begrenzt**, bevor sie in `AIRouterError`
  (und damit ggf. in Logs der aufrufenden App) landen.
- **Datei-Logs werden mit `0600` angelegt**; `os.Logger`-Ausgaben sind
  `privacy: .private` (Klartext nur im explizit konfigurierten Datei-Log).
- **Ollama-Modell-Cache ist pro Endpoint** — ein Endpoint-Wechsel liefert nie
  die Modellliste eines anderen Hosts.
- **Keine Klartext-Keys ins Netz**: Cloud-Provider akzeptieren `http://` nur
  für Loopback-/private Hosts (explizites Opt-out via `allowInsecureHTTP`).
- **Response-Größenlimit**: Der Standard-Transport kappt Antworten bei 50 MB
  (konfigurierbar) — kein Speicher-DoS durch defekte/kompromittierte Endpoints.

Details und Meldeweg für Schwachstellen: [SECURITY.md](SECURITY.md).

## Modulübersicht

| Datei | Inhalt |
| --- | --- |
| `AIRouter.swift` | Zentraler Actor: Routing, Budget, Breaker, Cache, Streaming, Telemetrie. |
| `AITask.swift` | Aufgaben-Enum mit Default-Modell, Token-Limit und Priorität. |
| `RoutingPolicy.swift` / `EnergyMode.swift` | Policies und Energiemodi. |
| `AIMessage.swift` | `AIMessage` (Multi-Turn) und `GenerationOptions`. |
| `ModelCatalog.swift` | `ModelDescriptor` (Provider, Upgrade-/Fallback-Kanten, Preise, Kontextfenster) und Standardkatalog. |
| `CloudInferenceProvider.swift` | Provider-Protokoll plus `OpenAICompatibleProvider` und `AnthropicDirectProvider`. |
| `LocalInferenceProvider.swift` | Protokoll für In-Process-Inferenz. |
| `OllamaService.swift` | Ollama-Modell-Discovery (`/api/tags`), Cache pro Endpoint. |
| `HTTPTransport.swift` | Injizierbarer Transport (`data` + zeilenweises `lines`-Streaming). |
| `AccessToken.swift` / `RetryPolicy.swift` | Auth-Token mit Ablauf; Retry-Strategie. |
| `RouterStorage.swift` | Persistenz-Protokoll für den Budget-Zustand. |
| `RouterValidation.swift` | Allowlist-Validierung für Regionen, Projekte, Modellnamen, Endpoints. |
| `DebugLog.swift` | `os.Logger` + optionales Datei-Log (`0600`). |

### Projekt-Dokumente

| Datei | Inhalt |
| --- | --- |
| [LICENSE.md](LICENSE.md) | PolyForm Noncommercial 1.0.0 (Dual-License-Header). |
| [COMMERCIAL.md](COMMERCIAL.md) | Kommerzielle Lizenzierung — Editionen, Konditionen auf Verhandlungsbasis, Kontakt. |
| [LICENSING.md](LICENSING.md) | Komponentenübergreifende Lizenz-Policy (Schichtenmodell, Distribution, Chain of Title). |
| [SECURITY.md](SECURITY.md) | Sicherheitsmodell und Meldeweg für Schwachstellen. |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Beitragsregeln inkl. CLA-Pflicht und harte Invarianten. |
| [docs/CLA.md](docs/CLA.md) | Contributor License Agreement. |

## Anforderungen

- macOS 13+ / iOS 16+ (nutzt `ContinuousClock` und `os.Logger`)
- Swift 5.7+ (Xcode 14.1+)
- Keine externen Abhängigkeiten

## Build & Test

```sh
swift build
swift test   # 47 Tests, laufen komplett gegen Mocks — kein Netz, keine Credentials
```

CI (GitHub Actions, macOS) baut und testet jeden Push auf `main` und jeden
Pull Request: [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

## Lizenz

AIRouter ist **dual-lizenziert**:

- **Nichtkommerzielle Nutzung** ist kostenlos unter der
  [PolyForm Noncommercial License 1.0.0](LICENSE.md).
- **Kommerzielle Nutzung** (Einsatz im Unternehmen, Einbettung in ein Produkt,
  Teil eines bezahlten Dienstes) erfordert eine kommerzielle Lizenz — Konditionen
  auf Verhandlungsbasis, siehe [COMMERCIAL.md](COMMERCIAL.md).

Die komponentenübergreifende Lizenz-Policy (Schichtenmodell, Distribution,
Chain of Title) steht in [LICENSING.md](LICENSING.md).

Kommerzielle Anfragen: **[hello@tstellmacher.com](mailto:hello@tstellmacher.com)**

Copyright 2026 Tommy Stellmacher.

## Beiträge

Beiträge sind willkommen und erfordern das CLA ([docs/CLA.md](docs/CLA.md)) —
Details in [CONTRIBUTING.md](CONTRIBUTING.md).

