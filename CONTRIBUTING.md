# Contributing to AIRouter

Thank you for considering a contribution — issues, ideas and pull requests are welcome.

## The one rule: the CLA

AIRouter is **dual-licensed** (free for noncommercial use under PolyForm Noncommercial,
commercial licenses sold separately). For that model — and for the project's ability to
ever change its licensing or transfer the codebase as a whole — the maintainer must
hold sufficient rights to *all* of the code.

Therefore every contribution requires agreeing to the
**[Contributor License Agreement](docs/CLA.md)**. Short version: you keep the copyright
to your contribution, and you grant the maintainer a perpetual, irrevocable,
transferable license to use, relicense and sublicense it under any terms.

Agreement is expressed per pull request: add this line to your PR description —

```
I have read docs/CLA.md and I agree to it for this and all my future contributions.
```

PRs without it can't be merged, no exceptions — this protects the project's chain of
title.

## Practical notes

- Build: `swift build` (macOS 13+ / Xcode 15+).
- Tests: `swift test` — all tests run against mocks, no network and no credentials
  required; they must stay that way.
- Hard invariants (PRs violating them will be declined regardless of usefulness):
  - **No telemetry, no phone-home, no hardwired remote endpoints.** Auth
    (`accessTokenProvider`) and transport (`HTTPTransport`) stay injectable.
  - **Validation stays strict**: the allowlists in `RouterValidation` (region,
    project, model names, local endpoints) must not be loosened; unknown models
    keep failing loudly with `notConfigured`.
  - **Budget correctness**: every cloud path accounts against the hourly budget —
    no new call path may bypass `budgetStatus()`.
