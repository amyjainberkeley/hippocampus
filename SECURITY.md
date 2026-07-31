# Security

This app reads your screen. That means a bug here is worse than a bug in most software, and I'd rather hear about one than not.

## Reporting something

Open a [private security advisory](https://github.com/amyjainberkeley/hippocampus/security/advisories/new) on this repo. Please don't open a public issue for anything exploitable.

I'll acknowledge within a few days. This is a solo project, so I can't promise a fix window, but I'll tell you honestly where it stands.

## What I'd most want to know about

In rough order of how badly I'd want the report:

1. **Anything that gets data off the machine.** The whole premise is that nothing leaves. A path that sends captured content anywhere, including in a crash report or a log, is the worst possible bug.
2. **Anything that reads the store without the key.** Plaintext on disk, a key that survives where it shouldn't, an unwrapped key in memory longer than it needs to be.
3. **Capture that should have been blocked.** A password prompt, private browsing window, or DRM surface that gets recorded anyway.
4. **Redaction that misses.** A one-time code or bank alert that ends up stored. There's a synthetic corpus for this in `core/brain/fixtures/`; a shape it doesn't catch is a useful report.
5. **The loopback API.** It's authenticated and local-only. Anything that lets another process on the machine query your memory without permission counts.

## What's already known

I try not to waste your time on things I've already written down:

- Live screen capture is not verified on real hardware and ships switched off. Bugs in that path are expected, not news.
- Encrypted sync is a skeleton. Cross-device convergence is unproven.
- The build isn't signed or notarized under my own Apple Developer ID yet.

The full honest status is in the README and in [ARCHITECTURE.md](ARCHITECTURE.md).

## Scope

In scope: this repo. Out of scope: anything about a hosted service, because there isn't one.
