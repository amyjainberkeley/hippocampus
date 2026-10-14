# AGENTS.md

- Run the `scripts/check.sh` lanes that cover your change, and all of them before a pull request (`scripts/check.sh --help` lists them).
- Never commit captured screen data, memory databases, keys, certificates, tokens or environment files.
- Keep the privacy gates intact: the never-read rules, the secret scans and the admission policy may be extended, never weakened, and their tests must pass.
- Run builds and tests without provider API keys or other credentials in the environment.
- Read [ARCHITECTURE.md](ARCHITECTURE.md) before changing a boundary, and record a load-bearing choice under `docs/decisions/`.
