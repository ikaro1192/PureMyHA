# Contributing to PureMyHA

Contributions are welcome — bug reports, feature ideas, and pull requests alike. Feel free to open an issue anytime. Please note that responses may not be immediate, as this project is maintained on a best-effort basis.

## Reporting Bugs

Found something wrong? Before opening an issue, please search [existing issues](https://github.com/ikaro1192/PureMyHA/issues) to avoid duplicates. If nothing matches, please open a new one. It helps to include:

- PureMyHA version (`puremyha --version`)
- MySQL version and `gtid_mode` / `enforce_gtid_consistency` values
- Relevant log output (JSON log lines from `puremyhad`)
- Steps to reproduce

## Feature Requests

Have an idea? Before opening an issue, please search [existing issues](https://github.com/ikaro1192/PureMyHA/issues) to see if it has already been discussed. If not, please open a new one and describe:

- The problem or use case you're trying to solve
- Your proposed solution or behavior
- How it fits with the [Design Principles](#design-principles) of PureMyHA

PureMyHA is intentionally focused in scope, so proposals that add significant complexity without a clear HA-correctness benefit may not be accepted — but discussing it upfront is always a good start.

## Prerequisites

| Tool | Version |
|------|---------|
| GHC | 9.x |
| Cabal | 3.0+ |
| Docker + Docker Compose | E2E tests only |

Install GHC and Cabal via [GHCup](https://www.haskell.org/ghcup/).

## Build & Test

```bash
# Build
cabal build all

# Unit tests (HSpec + QuickCheck)
cabal test

# E2E tests — spins up a real MySQL 8.4 GTID cluster (Docker required)
cd e2e && make e2e
make e2e-test T=02    # run a specific scenario
make e2e-logs         # follow daemon logs
make e2e-clean        # tear down the environment
```

See [docs/development.md](docs/development.md) for the full build reference.

CI runs unit tests on every push and E2E tests on every pull request, on both x86_64 and aarch64.

## Code Conventions

### Haskell style

- All `-Wall` warnings must be resolved. Do not silence them with `{-# OPTIONS_GHC -Wno-... #-}` unless genuinely necessary.
- Keep functions small and pure where possible. Side-effectful code belongs at the edges (IO, STM).
- Use `STM` for shared mutable state accessed by multiple threads; avoid `IORef` in those cases.

### Module structure

```
PureMyHA.Types        -- Shared domain types
PureMyHA.Config       -- YAML config parsing and validation
PureMyHA.MySQL.*      -- Wire protocol, GTID, TLS, auth
PureMyHA.Topology.*   -- Discovery and in-memory topology state
PureMyHA.Monitor.*    -- Per-node monitoring workers and failure detection
PureMyHA.Failover.*   -- Candidate selection, auto-failover, switchover, errant GTID
PureMyHA.IPC.*        -- Unix socket protocol between daemon and CLI
PureMyHA.HTTP.*       -- Optional read-only HTTP listener
```

New functionality belongs in the most specific existing namespace.

## Commit Messages

- **English only** — subject line, body, and any trailers
- Use the imperative mood: `Add errant GTID repair`, not `Added` or `Adds`
- Reference a GitHub issue when relevant: `Fixes #123`

## Pull Requests

Before submitting a PR, please search [existing issues and PRs](https://github.com/ikaro1192/PureMyHA/issues) to check whether the same change is already in progress. Then open an issue to discuss the approach first. The only exceptions are obvious typo fixes or trivial documentation corrections. Even well-implemented PRs may be declined if they would introduce ongoing maintenance burden that outweighs their benefit — discussing the idea upfront helps avoid that.

- One logical change per PR
- Ensure local tests pass(unit tests, E2E tests)
- If your change affects failover behavior, add or update the relevant `test/PureMyHA/*Spec.hs`
- Update `docs/` if your change affects configuration keys, CLI commands, or observable behavior
- Include `Fixes #<issue>` in the PR body to link the issue

## Design Principles

To keep PureMyHA simple and reliable, contributions should align with its core philosophy:

- **MySQL 8.4+ only** — no legacy version support or compatibility shims
- **Correctness-first** — if an operation cannot be done safely (GTID-aware, relay log awaited), it should not be done at all
- **Stateless daemon** — all state is derived from MySQL at startup; avoid adding durable on-disk state
- **Do one thing well** — HA tool only, not a topology manager or query router
- **No C dependencies** — preserve the pure-Haskell, statically-linkable property

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
