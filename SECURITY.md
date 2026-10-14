# Security

This app reads your screen. That means a bug here is worse than a bug in most software, and I'd rather hear about one than not.

## Reporting something

Open a [private security advisory](https://github.com/amyjainberkeley/hippocampus/security/advisories/new) on this repo. Please don't open a public issue for anything exploitable.

I'll acknowledge within a few days. This is a solo project, so I can't promise a fix window, but I'll tell you honestly where it stands.

## What I'd most want to know about

In rough order of how badly I'd want the report:

1. **Anything that gets data off the Mac.** Nothing you saw should leave unless you connect an AI tool or copy it yourself. A path that sends it anywhere else, including in a crash report or a log, is the worst possible bug.
2. **Anything that reads the store without the key.** Plaintext on disk, a key that survives where it shouldn't, an unwrapped key in memory longer than it needs to be.
3. **Reading that should have been skipped.** A password field, a password manager, a private browser window that shows it is private, or protected video that gets saved anyway.
4. **Redaction that misses.** A one-time code or bank alert that ends up stored. There's a synthetic corpus for this in `core/brain/fixtures/`; a shape it doesn't catch is a useful report.
5. **Local access.** Connected tools read your memory through `mci-agent mcp-serve`, with the key kept in your Keychain. Hippocampus opens no listening socket. Anything that lets another process on the Mac read your memory some other way counts.

## What's already known

I try not to waste your time on things I've already written down:

- Connected tools can still read your memory while Hippocampus is quit. Disconnect a tool to stop that.
- Private browser windows are skipped when they show they are private, by a title marker or the private badge in the window's top bar. A private window that shows neither is read.
- The database key is kept in your login Keychain. Wrapping it with the Secure Enclave is designed but not built.

What works today, and how it was checked, is in [docs/STATUS.md](docs/STATUS.md). [PRIVACY.md](PRIVACY.md) lists every request the app makes.

## Scope

In scope: this repo. Out of scope: anything about a hosted service, because there isn't one.
