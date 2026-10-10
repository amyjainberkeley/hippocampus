# Contributing

This is a solo project, so the most useful contributions are precise ones: an issue that says what you ran, what you expected and what happened, or a small pull request with the test that proves it.

## Set up

Prerequisites are in the [README](README.md#prerequisites): macOS 14 or later, Rust 1.83 or later, and Xcode 15 or later for the Swift packages.

```bash
git clone https://github.com/amyjainberkeley/hippocampus.git
cd hippocampus
./scripts/try-it.sh        # builds the CLI and runs the demo; needs no permissions
```

## Before you open a pull request

```bash
./scripts/check.sh
```

That runs the same lanes CI runs: `cargo fmt`, `cargo clippy`, `cargo test`, `cargo audit`, the Swift tests for the capture helper, recall UI and onboarding packages, and shell syntax checks. `./scripts/check.sh --help` lists selectors if you only want one lane.

## Pull request titles

CI lints titles as [Conventional Commits](https://www.conventionalcommits.org): `type: subject`, or `type(scope): subject`. Allowed types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`.

## What a good change looks like

- One change per pull request, with a test.
- Nothing above the `CaptureSource` seam may contain OS-specific code. [ARCHITECTURE.md](ARCHITECTURE.md) lists the four invariants; breaking any of them breaks the product.
- Errors surface. Nothing falls back silently to a worse answer.
- A change to an invariant or a load-bearing choice gets a record under [`docs/decisions/`](docs/decisions/).

## Security

Anything exploitable goes through [SECURITY.md](SECURITY.md), not a public issue.
