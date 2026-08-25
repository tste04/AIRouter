# Routing

Wie der Router aus Energiemodus, Policy und Overrides das Modell bestimmt.

## Overview

Jeder Aufruf durchläuft dieselbe Entscheidungskette, von der stärksten Zusage
zur schwächsten Präferenz:

1. **Flugmodus** (`setAirplaneMode(true)` bzw. `EnergyMode.offline`): Es wird
   immer das lokale Modell gewählt — auch gegen Modell-Overrides, und auch
   dann, wenn der lokale Aufruf fehlschlägt (kein stiller Cloud-Fallback).
2. **`RoutingPolicy.localOnly`**: Datenschutz-Zusage pro Aufgabe; schlägt
   Overrides und jeden Energiemodus, inklusive `maxCloud`.
3. **`taskModels`-Override**: Ein explizit gesetztes Modell für die Aufgabe.
4. **Energiemodus × Policy**: die eigentliche Mischentscheidung.

## Energiemodus × Policy

| | `cloudOnly` | `preferCloud` | `preferLocal` | `localOnly` |
| --- | --- | --- | --- | --- |
| `maxCloud` | Cloud (Upgrade) | Cloud (Upgrade) | Cloud (Upgrade) | lokal |
| `fullPower` | Cloud | Cloud | lokal, sonst Cloud | lokal |
| `powerSave` | Cloud | Cloud | Cloud | lokal |
| `offline` | lokal | lokal | lokal | lokal |

„lokal, sonst Cloud" heißt: das lokale Backend wird genutzt, wenn eines
konfiguriert ist (``LocalInferenceProvider`` oder Ollama-Endpoint); andernfalls
das Cloud-Default-Modell der Aufgabe.

## Fallbacks zur Laufzeit

- **Lokal → Cloud**: nur unter `preferLocal`, nur außerhalb des Flugmodus,
  wenn der lokale Aufruf fehlschlägt.
- **Cloud → Lokal**: wenn das Budget erschöpft ist und ein lokales Backend
  existiert — beim `send` wie beim Streaming.
- **Modell → Fallback-Modell**: bei HTTP 404 entlang der `fallsBackTo`-Kette
  des ``ModelCatalog`` (zyklusfest).

Alle Wechsel werden über ``RouterEvent`` gemeldet.
