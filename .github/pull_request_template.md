## Was ändert dieser PR?

<!-- Kurz: was und warum. Bei Verhaltensänderungen: vorher/nachher. -->

## Checkliste

- [ ] `swift build` und `swift test` laufen lokal grün (Tests bleiben mock-basiert, ohne Netz)
- [ ] Keine Invariante verletzt (kein Phone-Home, Auth/Transport injizierbar,
      Validierung nicht gelockert, jeder Cloud-Pfad zahlt aufs Budget ein)
- [ ] Öffentliche API-Änderungen sind additiv und dokumentiert (README/DocC/CHANGELOG)
