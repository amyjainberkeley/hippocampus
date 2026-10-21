# Security

This app reads your screen. That means a bug here is worse than a bug in most software, and I'd rather hear about one than not.

## Reporting something

Open a [private security advisory](https://github.com/amyjainberkeley/hippocampus/security/advisories/new) on this repo. Please don't open a public issue for anything exploitable. If that form isn't open, open an issue that asks for a private contact and leaves the details out.

I'll acknowledge within a few days. This is a solo project, so I can't promise a fix window, but I'll tell you honestly where it stands.

## What I'd most want to know about

In rough order of how badly I'd want the report:

1. **Anything that gets data off the Mac.** What you saw should leave only when you connect an AI tool, use a model server on this Mac, or copy it yourself. A path that sends it anywhere else, including in a crash report or a log, is the worst bug there is.
2. **Anything that reads the store without the key.** Plaintext on disk, a key that survives where it shouldn't, an unwrapped key in memory longer than it needs to be.
3. **Reading that should have been skipped.** A password field, one of the skipped apps, a private browser window that shows it is private, or protected video that gets saved anyway.
4. **Secret checks that miss.** A password, key, token, card number or one-time code that ends up stored although it is in one of the shapes the checks look for. There's a synthetic corpus for this in `core/brain/fixtures/`; a common shape it doesn't cover is a useful report too.
5. **Local access.** Connected tools read your memory through `mci-agent mcp-serve`, with the key kept in your Keychain. Hippocampus listens on no network port. While it is remembering, `mci-agent` takes page text from the browser extension on a Unix socket in its data folder; that socket takes text in and sends nothing back. Anything that lets another process read your memory, or write into it, some other way counts.

## What's already known

I try not to waste your time on things I've already written down:

- Connected tools can still read your memory while Hippocampus is quit, until you disconnect them in Preferences, under AI Tools ([PRIVACY.md](PRIVACY.md#disconnecting-an-ai-tool)).
- Any program running as you can start `mci-agent` and read your memory the way a connected tool does. The [threat model](PRIVACY.md#threat-model) says what encryption covers and what it doesn't.
- Password managers and authenticator apps are skipped by bundle ID, from a list of 66 identifier families. One that isn't on the list is read like any other app, with the secret checks still applied.
- Private browser windows are skipped when they show they are private, by a title marker or the private badge in the window's top bar. A private window that shows neither is read.
- Everything Hippocampus stores, from the screen or any other source, is checked for secret shapes before it is kept: a password, secret, key or token written as `name: value`; an API key or token in the shape Anthropic, OpenAI, GitHub, GitLab, Slack, Google, AWS or Stripe gives it; a JSON web token; the first line of a private key; a long token after `Bearer`; a credit-card number that passes the Luhn check; and a one-time code within about 40 characters of a keyword (verification code, one-time, passcode, OTP, 2FA, …). The window's title and the page's address are checked too, and an address loses its sign-in parameters first. These are precision-first, so some things still get through: a lone code with no nearby keyword, a one-time code in a format the keywords don't name, a high-entropy token that fits no pattern, or a bank alert shown on screen (the Messages/Mail deep hook removes bank alerts on its own path).
- Search results reach a connected AI tool as plain text, with nothing marking them as not to be obeyed. Session-start text does carry that line.
- The database key is kept in your login Keychain. Wrapping it with the Secure Enclave is designed but not built.
- In 0.3.0 the key has no this-device-only setting, so it moves with a copied login keychain; the next beta moves it to the data-protection keychain.
- The text reader uses Microsoft's official ONNX Runtime 1.30, which still contains Microsoft's telemetry client. Hippocampus turns it off three ways (the worker sets `ORT_DISABLE_TELEMETRY=1` before ONNX Runtime loads and calls `disable_telemetry_events()`, and the capture helper starts it with the same setting) and runs the reader in a sandbox with no network. The end-to-end test checks both on the running reader. Removing the client itself needs ONNX Runtime built from source without telemetry, which needs a build with network access, so it isn't done yet. Earlier versions did neither: from 0.2.0, their reader sent ONNX Runtime's usage events and a device ID to Microsoft.

What works today, and how it was checked, is in [docs/STATUS.md](docs/STATUS.md). [PRIVACY.md](PRIVACY.md) lists every request the app makes.

## Scope

In scope: this repo. Out of scope: anything about a hosted service, because there isn't one.
