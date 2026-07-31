# Hippocampus

Your computer already sees everything you do. It just doesn't remember any of it.

Hippocampus is a Mac app that fixes that. It watches what's on your screen, understands it, and stores it in an encrypted database on your own machine. Later you can ask it "what was that pricing page I looked at last Tuesday?" and get the answer.

Nothing leaves your laptop. There is no server to trust, because there is no server.

## Why I built this

I lose things constantly. A paper I skimmed three weeks ago. The name of a tool someone mentioned in a call. A page I know I read but can't find again. Search doesn't help, because I don't remember the words. I remember the situation. I remember it was a Tuesday and I was annoyed.

Computers store files. Brains store moments. I wanted the second thing.

The hard part isn't recording your screen. Anyone can do that. The hard part is that a full day of screen recording is millions of frames and almost none of them matter, and if you want to search the ones that do, you need the search to run on your own machine, and it has to be fast, and it has to work when you describe a feeling instead of a keyword. That's the problem this repo is about.

## What it actually does

Five steps, roughly:

1. **Watch.** A small Swift helper grabs the screen, but only when something meaningful changes. Not on a timer. An idle detector stops it when you walk away, and a perceptual hash throws away frames that are near-copies of the last one. This is what turns eight hours into a few thousand moments instead of a few million frames.
2. **Read.** Each surviving frame goes through on-device OCR, and gets joined to what you were doing: which app, which window, which URL.
3. **Understand.** Moments get grouped into episodes, then turned into vectors by a small embedding model running on the Neural Engine. This happens when your machine is idle, never while you're using it.
4. **Store.** Everything goes into one encrypted SQLite file. One file, one lock. The key is wrapped by the Secure Enclave.
5. **Recall.** When you ask a question, it searches two ways at once: keyword search for exact things like a filename, and vector search for vague things like "that pricing discussion." The two result sets get merged, weighted by how recent and how relevant each hit is.

The design choices behind each of those are written up in [ARCHITECTURE.md](ARCHITECTURE.md), and the arguments I had with myself are in the 37 decision records under [docs/decisions/](docs/decisions/).

## What works and what doesn't

I want to be straight about this, because a lot of it isn't finished.

**Works, and is tested:**
- The encrypted store and the search on top of it. Keyword plus vector, merged and ranked. This is the part I'm proud of.
- On-device semantic search. The embedding model runs through Core ML with a regression test that checks the vectors still match a known-good reference.
- Pulling apart text to find the useful bits: names, dates, URLs, and the stuff that should never be stored at all, like a password field or a bank one-time code.
- 535 tests pass on the core.

**Built, but I have not proven it on real hardware:**
- The live screen capture path. All the code exists. It is switched off by default in any build that ships, and I am not going to claim it works until I've watched it run all day on a real machine and measured it.

**Barely started:**
- Encrypted sync between two machines. The crypto is there, the proof that two devices actually converge is not.
- Windows. There's an empty crate with the right shape and nothing in it.

The app is not signed or notarized under my own Apple Developer ID yet, so a build you make yourself will need you to allow it through Gatekeeper by hand.

## Privacy, concretely

The promise is "nothing leaves your machine," so here's what enforces it rather than just my word:

- One encrypted SQLite file, via SQLCipher. The key is wrapped by a Keychain item gated on the Secure Enclave and can't be exported.
- No vector database sitting outside that file. That's why search uses sqlite-vec, which lives inside the same file, instead of something faster and separate.
- Capture is blocked at the source for sensitive surfaces: password prompts, private browsing, DRM video. Blocking at the source matters more than scrubbing afterward, because scrubbing afterward means the data existed.
- On top of that, a second layer looks at extracted text for things like one-time codes and bank alerts and refuses to store them. It's tested against a synthetic corpus of 133 message shapes built from public security writeups, NIST guidance, and OWASP fixtures. Those fixtures are in [core/brain/fixtures/](core/brain/fixtures/). They contain no real messages.
- Deleting a memory crypto-shreds it rather than marking a row hidden.

## The one design decision that shapes everything else

Screen capture has to be written per operating system. Encryption, search, and ranking do not.

So there's exactly one seam in the codebase: a Rust trait called `CaptureSource`. Below it sits a thin native adapter that knows how to talk to macOS. Above it sits everything else, written once in Rust, with no OS-specific code allowed. Adding Windows later should mean writing one adapter, not writing the whole brain a second time.

The other rule is that pixels never cross that seam as a copy. The adapter hands over a borrowed handle to memory the GPU already owns, and the core reads from it and lets go immediately. Copying every frame is the difference between a program you forget is running and a hot laptop.

## Running it

Needs macOS 14 or later on Apple Silicon, and Rust 1.83 or later.

```bash
git clone https://github.com/amyjainberkeley/hippocampus.git
cd hippocampus
cargo test -p mci-brain      # the core: 535 tests
cargo test --workspace       # everything
```

Screen capture stays off unless you set `HIPPOCAMPUS_ENABLE_V2P1`. Leave it off until the verification above is done.

## Layout

| Where | What's in it |
|---|---|
| `core/` | The portable core. The capture seam, encryption, the SQLite store, IPC. |
| `core/brain/` | The interesting part. Search, ranking, episode grouping, embeddings, entity extraction, redaction. |
| `adapters/macos/` | Swift. Screen capture, OCR, hardware encode, and the readers for Mail and Messages. |
| `apps/` | The menu bar app, the recall window, the onboarding flow, the agent bridge. |
| `docs/decisions/` | 37 records of why things are the way they are. |
| `ARCHITECTURE.md` | Read this if you're going to read the code. |

## License

Apache 2.0. See [LICENSE](LICENSE).
