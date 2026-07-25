# Kommerzielle Lizenzierung

AIRouter ist dual-lizenziert.

- **Persönliche & nichtkommerzielle Nutzung ist kostenlos** unter der
  [PolyForm Noncommercial License 1.0.0](LICENSE.md) — eigene Projekte, eigene
  Experimente, eigene Maschine.
- **Jede kommerzielle Nutzung erfordert eine kommerzielle Lizenz** — Einsatz
  innerhalb eines Unternehmens, Einbettung in ein Produkt oder Bereitstellung als
  Teil eines bezahlten Dienstes.

„Kommerziell" und „nichtkommerziell" richten sich nach den Definitionen der
PolyForm Noncommercial License 1.0.0. Im Zweifel: eine kurze Anfrage klärt es.

## Warum eine kommerzielle Lizenz

AIRouter ist keine „ein Modell, ein Provider"-Hilfsfunktion, sondern die
**Routing- und Governance-Schicht** zwischen App und KI-Backends:

| Was du bekommst | Warum es kommerziell zählt |
|---|---|
| Provider-agnostisches Routing (Vertex, OpenAI-kompatibel, Anthropic-direkt, lokal) | Keine Vendor-Bindung — Backends wechseln, ohne Call-Sites anzufassen. |
| Token- **und** USD-Budget mit prioritätsbasiertem Throttling | Harte Kostendeckel pro Stunde statt Überraschungen auf der Cloud-Rechnung. |
| Kosten-Telemetrie pro Aufruf und pro Stunde | Verbrauch ist messbar und zuordenbar — die Grundlage für Weiterverrechnung. |
| PII-Preflight vor jedem Cloud-Versand | Sensible Inhalte werden vor dem Versand redigiert — reduziert Auftragsverarbeitungs-Risiko. |
| Circuit-Breaker & Retry-Policy | Ausfälle einzelner Modelle degradieren kontrolliert statt die App mitzureißen. |
| Hybrid lokal/Cloud mit Energiemodi | Datenschutz-/Offline-Betrieb ohne separaten Code-Pfad. |

## Editionen (indikativ)

| Edition | Für | Umfang | Preis (Richtwert) |
|---|---|---|---|
| **Personal** | Einzelpersonen, nichtkommerziell | Alles in diesem Repo | Kostenlos (PolyForm NC) |
| **Pro** | Freelancer & kommerzielle Einzelnutzung | Kommerzielle Lizenz, priorisierte Issues | €79 / Jahr |
| **Team** | Unternehmen bis 25 Seats | Kommerzielle Lizenz, E-Mail-Support | €990 / Jahr |
| **Enterprise / OEM** | Einbettung in Produkte, Compliance-Deployments | OEM-Lizenz, SLA, Roadmap-Einfluss | ab €25.000 / Jahr |

Preise sind bis zum ersten öffentlichen Release indikativ und können sich ändern;
Early Adopters behalten ihre Stufe.

## Wie die Lizenzierung funktioniert

AIRouter telefoniert nicht nach Hause — es gibt **keinen Lizenzserver, keine
Aktivierungs-Calls, keine Telemetrie und keinen Kill-Switch**. Die Durchsetzung ist
**rechtlicher, nicht technischer** Natur:

1. **PolyForm NC macht unlizenzierte kommerzielle Nutzung zur
   Urheberrechtsverletzung** — derselbe Hebel, auf dem jedes betriebliche
   Software-Asset-Management beruht. Unternehmen lizenzieren, weil ihre eigenen
   Compliance-Regeln unlizenzierte Software verbieten.
2. **Enterprise-Verträge enthalten eine jährliche Selbstauskunft** zur Seat-Zahl,
   die auf der nächsten Rechnung angepasst wird — übliche Praxis, keine Audits per
   Default.

## Lizenz erhalten

Öffne ein GitHub-Issue mit dem Titel `commercial license` in diesem Repository oder
kontaktiere den Autor über das GitHub-Profil. Du erhältst eine kurze
Lizenzvereinbarung und eine Rechnung — kein Call nötig, außer du möchtest einen.

## FAQ

**Kann ich kommerziell zuerst evaluieren?** Ja — 30 Tage, ohne Registrierung.

**Nervt oder telefoniert die freie Version nach Hause?** Nein.

**Beiträge?** Willkommen. Damit das Projekt als Ganzes lizenzierbar und
verkaufbar bleibt (saubere Rechtekette), erfolgt die Einreichung unter Abtretung
der nötigen Rechte an den Maintainer — Details klären wir pro Beitrag.
