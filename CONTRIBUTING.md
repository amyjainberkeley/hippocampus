# Contributing

This is a solo project, so the most useful contributions are precise ones: an issue that says what you ran, what you expected and what happened, or a small pull request with the test that proves it.

## Set up

Prerequisites are in the [README](README.md#build-from-source): an Apple silicon Mac, Xcode 26, the Rust toolchain named in `rust-toolchain.toml`, and Python 3.12 with uv for the text reader. `./scripts/check.sh` also needs ripgrep and SwiftFormat: `brew install ripgrep swiftformat`.

```bash
git clone https://github.com/amyjainberkeley/hippocampus.git
cd hippocampus
./scripts/try-it.sh        # builds the CLI and runs the demo; needs no permissions
```

## Before you open a pull request

```bash
./scripts/check.sh
```

That runs `cargo fmt`, `cargo clippy` with warnings as errors (as CI does), `cargo test`, `cargo audit`, SwiftFormat, the Swift tests for every package, hippocampus-mind built without Foundation Models, the OCR worker's tests when `tools/ocr/.venv` is set up, the release and product contracts, and shell syntax checks. `./scripts/check.sh --help` lists selectors if you only want one lane.

## Pull request titles

CI lints titles as [Conventional Commits](https://www.conventionalcommits.org): `type: subject`, or `type(scope): subject`. Allowed types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`.

## What a good change looks like

- One change per pull request, with a test.
- Nothing above the `CaptureSource` seam may contain OS-specific code. [ARCHITECTURE.md](ARCHITECTURE.md) lists the four invariants; breaking any of them breaks the product.
- Errors surface. Nothing falls back silently to a worse answer.
- A change to an invariant or a load-bearing choice gets a record under [`docs/decisions/`](docs/decisions/).

## Security

Anything exploitable goes through [SECURITY.md](SECURITY.md), not a public issue.
