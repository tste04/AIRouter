# AIRouter

Standalone Swift-Package des `AIRouter` aus dem UserCockpit-Projekt. Ein
zentraler Router, der KI-Aufgaben anhand von **Energiemodus**, **Routing-Policy**
und **Token-Budget** auf Cloud-Modelle (Vertex AI: Anthropic & Google) oder
lokale Modelle (In-Process-Provider oder Ollama-HTTP) verteilt.

## Use Case

Der Router löst ein konkretes Problem: **eine App wählt pro Aufgabe automatisch das
richtige Modell — und schaltet je nach Strom, Netz und Budget zwischen
Cloud-Qualität und lokaler Privatsphäre/Offline-Fähigkeit um**, ohne dass jede
Call-Site das wissen muss.

Besonders stark bei:

- **Hybrid lokal/Cloud** — Apple Silicon + MLX/Ollama als Sparmodus, Vertex als Qualitätsmodus.
- **Laptop-/Akku-Szenarien** — `powerSave` und `offline` schalten automatisch um.
- **Kostenkontrolle** — stündliches Token-Budget mit prioritätsbasiertem Throttling.
- **Viele heterogene KI-Aufgaben** in einer App mit unterschiedlichen Qualitätsstufen.

Weniger geeignet: einfache „1 App, 1 Modell, 1 Provider"-Fälle (Overkill) sowie
Multi-Provider-Setups außerhalb von Google Cloud (siehe *Grenzen* unten).

## Key-Funktionalitäten

| Bereich | Funktion |
| --- | --- |
| **Aufgaben-Routing** | `send(task:system:user:)` wählt Modell anhand `AITask` (30 vordefinierte Aufgaben mit Default-Modell, Token-Budget, Priorität, Policy). |
| **Energiemodi** | `setEnergyMode(_:)` — `maxCloud`, `fullPower`, `offline`, `powerSave` steuern Cloud-vs-Lokal-Verhalten global. |
| **Routing-Policies** | Pro Aufgabe `cloudOnly` / `preferCloud` / `preferLocal` / `localOnly`, überschreibbar via `taskRoutingPolicies`. |
| **Cloud ↔ Lokal-Fallback** | Automatischer Wechsel bei Fehlern oder erschöpftem Budget. |
| **Vertex AI** | Anthropic (`:rawPredict`) und Google (`:generateContent`); Modell-Fallback bei HTTP 404, Token-Refresh bei HTTP 401, Retry mit Backoff. |
| **Lokale Inferenz** | `LocalInferenceProvider`-Protokoll (z. B. MLX) **oder** Ollama (`/api/chat`), mit Auto-Erkennung installierter Ollama-Modelle. |
| **Streaming** | `sendStreaming(task:…)` liefert Token-weise (In-Process, Ollama-NDJSON, oder Fallback auf Vollantwort). |
| **Token-Budget** | `setHourlyBudget(_:)` + `budgetStatus()`; Throttling nach Priorität (critical umgeht Budget). |
| **Telemetrie** | `setUsageCallback(_:)` liefert `AIUsageInfo` (Modell, Tokens, Dauer) pro Aufruf. |
| **Austauschbare Auth** | `accessTokenProvider`-Closure; Default `gcloud auth application-default print-access-token`. |
| **Logging** | `DebugLog` über `os.Logger`, optional in Datei (`DebugLog.configure(filePath:)`). |

## Grenzen (noch nicht universell)

Der Router ist **generisch in der Routing-Mechanik**, aber in den Inhalten auf
UserCockpit zugeschnitten:

- **Nur Vertex AI** als Cloud-Provider — OpenAI, Azure, Anthropic-direkt oder Mistral
  erfordern aktuell Code-Änderungen.
- **`AITask` ist projektspezifisch** — 30 feste Aufgaben mit deutschen `displayName`s.
- **Modellnamen hartkodiert** (`claude-opus-4-6`, `gemini-2.5-flash` …) in `defaultModel`,
  `upgradeModel`, `fallbackModel`.
- **Default-Auth** nutzt einen `gcloud`-Shell-Aufruf (macOS-spezifisch).

Für volle Projektunabhängigkeit: `AITask` zu konfigurierbaren Profilen machen, Vertex
hinter ein `CloudInferenceProvider`-Protokoll ziehen und Modell-/Fallback-Ketten aus
Daten statt `switch`-Statements speisen.

## Features

- **Aufgabenbasiertes Routing** über `AITask` — jede Aufgabe besitzt Default-Modell,
  Token-Budget, Priorität und Routing-Policy.
- **Energiemodi** (`EnergyMode`): `maxCloud`, `fullPower`, `offline`, `powerSave`.
- **Routing-Policies** (`RoutingPolicy`): `cloudOnly`, `preferCloud`, `preferLocal`,
  `localOnly` — inkl. automatischem Fallback Cloud ↔ Lokal.
- **Vertex AI** für Anthropic (`:rawPredict`) und Google (`:generateContent`),
  inkl. Modell-Fallback bei HTTP 404 und Token-Refresh bei HTTP 401.
- **Lokale Inferenz** über das `LocalInferenceProvider`-Protokoll (z. B. MLX) oder
  per Ollama (`/api/chat`, NDJSON-Streaming).
- **Streaming** via `sendStreaming(task:…)`.
- **Stündliches Token-Budget** mit prioritätsbasiertem Throttling.
- **Usage-Telemetrie** über einen Callback (`AIUsageInfo`).

## Installation

In `Package.swift`:

```swift
.package(path: "../AIRouter")
```

oder als Git-Abhängigkeit:

```swift
.package(url: "<repo-url>", from: "1.0.0")
```

und im Target:

```swift
.product(name: "AIRouter", package: "AIRouter")
```

## Schnellstart

```swift
import AIRouter

let router = AIRouter(
    vertexRegion: "us-central1",
    vertexProject: "mein-gcp-projekt"
)

await router.setEnergyMode(.fullPower)

// Optional: lokales Ollama-Backend (Modell wird automatisch erkannt, wenn "")
await router.configureLocalLLM(endpoint: "http://localhost:11434", model: "")

let antwort = try await router.send(
    task: .meetingSummary,
    system: "Du bist ein praeziser Meeting-Zusammenfasser.",
    user: "Transkript: …"
)
```

### Streaming

```swift
for try await chunk in router.sendStreaming(task: .advisorRealtime,
                                            system: "…",
                                            user: "…") {
    print(chunk, terminator: "")
}
```

## Authentifizierung gegen Vertex AI

Standardmäßig holt der Router ein OAuth2-Token via
`gcloud auth application-default print-access-token`. Eigene Token-Quelle
injizieren:

```swift
let router = AIRouter(
    vertexRegion: "us-central1",
    vertexProject: "mein-gcp-projekt",
    accessTokenProvider: {
        // z. B. aus einem Service-Account / Metadata-Server
        try await meinTokenProvider.fetch()
    }
)
```

## Eigener In-Process-Provider (statt MLX)

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

## Budget & Telemetrie

```swift
await router.setHourlyBudget(500_000)

await router.setUsageCallback { info in
    print("\(info.model): in=\(info.inputTokens) out=\(info.outputTokens) \(info.durationMs)ms")
}

let status = await router.budgetStatus()
print("Genutzt: \(status.tokensUsed)/\(status.tokenBudget) (\(Int(status.utilization * 100))%)")
```

## Unterschiede zur eingebetteten UserCockpit-Variante

- `MLXModelManager` ist durch das Protokoll `LocalInferenceProvider` ersetzt — keine
  harte MLX-Abhängigkeit, der Router bleibt eigenständig kompilierbar.
- Die Vertex-Authentifizierung ist über `accessTokenProvider` austauschbar
  (Default weiterhin `gcloud`).
- Alle relevanten Typen sind `public`.

## Anforderungen

- macOS 13+
- Swift 5.9+

## Build & Test

```sh
swift build
swift test
```
