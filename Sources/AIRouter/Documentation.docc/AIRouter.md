# ``AIRouter``

Routing- und Governance-Schicht zwischen App und KI-Backends: wählt pro
Aufgabe das passende Modell (Cloud oder lokal), setzt Token- und
Kosten-Budgets durch und hält Ausfälle mit Circuit-Breaker und Retries fern.

## Overview

Der zentrale Einstiegspunkt ist der Actor ``AIRouter/AIRouter``. Eine App
konfiguriert einmalig Region, Projekt und Auth (injizierbar über
``AIRouter/AIRouter/AccessTokenProvider``) und ruft danach nur noch
`send(task:system:user:)` bzw. `sendStreaming` auf — welches Modell antwortet,
entscheidet der Router aus Energiemodus, Routing-Policy und Budgetlage.

## Topics

### Artikel

- <doc:Routing>
- <doc:Budgets>

### Kern

- ``AIRouter/AIRouter``
- ``AITask``
- ``EnergyMode``
- ``RoutingPolicy``

### Anfragen

- ``AIMessage``
- ``GenerationOptions``

### Backends

- ``CloudInferenceProvider``
- ``OpenAICompatibleProvider``
- ``AnthropicDirectProvider``
- ``LocalInferenceProvider``
- ``ModelCatalog``
- ``ModelDescriptor``

### Beobachtbarkeit

- ``AIUsageInfo``
- ``RouterEvent``

### Infrastruktur

- ``HTTPTransport``
- ``URLSessionTransport``
- ``AccessToken``
- ``RetryPolicy``
- ``RouterStorage``
- ``PersistedBudgetState``
- ``AIRouterError``
