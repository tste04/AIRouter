# AIRouter

Ein eigenständiges Swift-Package mit einem zentralen Router, der KI-Aufgaben
anhand von **Energiemodus**, **Routing-Policy** und **Token-Budget** auf
Cloud-Modelle (Vertex AI: Anthropic & Google) oder lokale Modelle
(In-Process-Provider oder Ollama-HTTP) verteilt.

Plug-and-play: keine Auth-Strategie und kein Cloud-Projekt sind fest verdrahtet —
Authentifizierung, lokales Backend und Modell-/Routing-Konfiguration werden
vollständig von außen injiziert.

## Use Case

Der Router löst ein konkretes Problem: **eine App wählt pro Aufgabe automatisch das
richtige Modell — und schaltet je nach Strom, Netz und Budget zwischen
Cloud-Qualität und lokaler Privatsphäre/Offline-Fähigkeit um**, ohne dass jede
Call-Site das wissen muss.

Besonders stark bei:

- **Hybrid lokal/Cloud** — On-Device-Modell/Ollama als Sparmodus, Vertex als Qualitätsmodus.
- **Laptop-/Akku-Szenarien** — `powerSave` und `offline` schalten automatisch um.
- **Kostenkontrolle** — stündliches Token-Budget mit prioritätsbasiertem Throttling.
- **Viele heterogene KI-Aufgaben** in einer App mit unterschiedlichen Qualitätsstufen.

Weniger geeignet: einfache „1 App, 1 Modell, 1 Provider"-Fälle (Overkill) sowie
Multi-Provider-Setups außerhalb von Google Cloud Vertex AI (siehe *Grenzen* unten).

## Key-Funktionalitäten

| Bereich | Funktion |
| --- | --- |
| **Aufgaben-Routing** | `send(task:system:user:)` wählt Modell anhand `AITask` (vordefinierte Aufgaben mit Default-Modell, Token-Budget, Priorität, Policy). |
| **Energiemodi** | `setEnergyMode(_:)` — `maxCloud`, `fullPower`, `offline`, `powerSave` steuern Cloud-vs-Lokal-Verhalten global. |
| **Routing-Policies** | Pro Aufgabe `cloudOnly` / `preferCloud` / `preferLocal` / `localOnly`, überschreibbar via `taskRoutingPolicies`. |
| **Cloud ↔ Lokal-Fallback** | Automatischer Wechsel bei Fehlern oder erschöpftem Budget. |
| **Vertex AI** | Anthropic (`:rawPredict`) und Google (`:generateContent`); Modell-Fallback bei HTTP 404, Token-Refresh bei HTTP 401, Retry mit Backoff. |
| **Lokale Inferenz** | `LocalInferenceProvider`-Protokoll (eigenes On-Device-Modell) **oder** Ollama (`/api/chat`), mit Auto-Erkennung installierter Ollama-Modelle. |
| **Streaming** | `sendStreaming(task:…)` liefert Token-weise (In-Process, Ollama-NDJSON, oder Fallback auf Vollantwort). |
| **Token-Budget** | `setHourlyBudget(_:)` + `budgetStatus()`; Reservierungs-Budget (kein TOCTOU): Schaetzung wird vor dem Netzaufruf reserviert und nach Antwort mit echten Tokenzahlen verrechnet. Throttling nach Priorität (critical umgeht Budget). |
| **Telemetrie** | `setUsageCallback(_:)` liefert `AIUsageInfo` (Modell, Tokens, Dauer, `isEstimated`) pro Aufruf — auch beim Streaming. |
| **Injizierbare Auth** | `accessTokenProvider`-Closure liefert ein `AccessToken` (Wert + `expiresAt`); keine Auth-Strategie und keine feste TTL sind verdrahtet. |
| **Injizierbarer Transport** | `transport: HTTPTransport` ist austauschbar (Default `URLSession`), wodurch der Router ohne echtes Netz testbar ist. |
| **Modellkatalog** | Bekannte Modelle inkl. Upgrade-/Fallback-Kanten stehen im `ModelCatalog`; eigene Modelle via `additionalModels`. Unbekannte Modelle führen zu `AIRouterError.notConfigured` statt stiller Fehl-Zuordnung. |
| **Logging** | `DebugLog` über `os.Logger`, optional in Datei (`DebugLog.configure(filePath:)`). |

## Grenzen (noch nicht universell)

Der Router ist **generisch in der Routing-Mechanik**, in den Inhalten aber auf
einige Annahmen festgelegt:

- **Nur Vertex AI** als Cloud-Transport — OpenAI, Azure, Anthropic-direkt oder
  Mistral erfordern aktuell Code-Änderungen.
- **`AITask` ist ein festes Enum** mit vordefinierten Aufgaben und deutschen
  `displayName`s.
- **Der Standard-Modellkatalog ist im Code hinterlegt** (`ModelCatalog.default`)
  — Overrides bzw. eigene Modelle sind über `taskModels`, `taskRoutingPolicies`
  und `additionalModels` möglich.

Für volle Provider-Unabhängigkeit: `AITask` zu konfigurierbaren Profilen machen,
Vertex hinter ein `CloudInferenceProvider`-Protokoll ziehen und Modell-/
Fallback-Ketten aus Daten statt `switch`-Statements speisen.

## Features

- **Aufgabenbasiertes Routing** über `AITask` — jede Aufgabe besitzt Default-Modell,
  Token-Budget, Priorität und Routing-Policy.
- **Energiemodi** (`EnergyMode`): `maxCloud`, `fullPower`, `offline`, `powerSave`.
- **Routing-Policies** (`RoutingPolicy`): `cloudOnly`, `preferCloud`, `preferLocal`,
  `localOnly` — inkl. automatischem Fallback Cloud ↔ Lokal.
- **Vertex AI** für Anthropic (`:rawPredict`) und Google (`:generateContent`),
  inkl. Modell-Fallback bei HTTP 404 und Token-Refresh bei HTTP 401.
- **Lokale Inferenz** über das `LocalInferenceProvider`-Protokoll oder
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
.package(url: "https://github.com/rdtste/AIRouter.git", from: "1.0.0")
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
for try await chunk in router.sendStreaming(task: .advisorRealtime,
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

## Budget & Telemetrie

```swift
await router.setHourlyBudget(500_000)

await router.setUsageCallback { info in
    print("\(info.model): in=\(info.inputTokens) out=\(info.outputTokens) \(info.durationMs)ms")
}

let status = await router.budgetStatus()
print("Genutzt: \(status.tokensUsed)/\(status.tokenBudget) (\(Int(status.utilization * 100))%)")
```

## Unterschiede zur eingebetteten Variante

- Die lokale In-Process-Inferenz ist durch das Protokoll `LocalInferenceProvider`
  abstrahiert — keine harte Abhängigkeit zu einem konkreten Inferenz-Framework.
- Die Vertex-Authentifizierung wird ausschließlich über `accessTokenProvider`
  injiziert; es ist keine Auth-Strategie fest verdrahtet.
- Alle relevanten Typen sind `public`.

## Anforderungen

- macOS 13+
- Swift 5.9+

## Build & Test

```sh
swift build
swift test
```

## Breaking Changes

Diese Version bricht bewusst die API, um Korrektheit und Testbarkeit zu erhöhen:

- **`accessTokenProvider` liefert jetzt `AccessToken`** (Wert + `expiresAt`)
  statt `String`. Der Router cacht anhand `expiresAt` statt einer festen
  50-Minuten-TTL. Migration: `return token` → `return AccessToken(value: token, lifetime: 3000)`.
- **`taskModels` und `taskRoutingPolicies` sind typisiert**: `[AITask: String]`
  bzw. `[AITask: RoutingPolicy]` statt stringly-typed Dictionaries.
- **Neuer Init-Parameter `transport: HTTPTransport`** (Default `URLSession`) zum
  Injizieren eines Test- oder Custom-Transports.
- **Neuer Init-Parameter `additionalModels: [String: ModelDescriptor]`** zum
  Registrieren eigener Modelle. **Unbekannte Modelle werfen `notConfigured`**
  statt still als Anthropic/Google geraten zu werden.

