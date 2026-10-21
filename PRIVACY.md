# Privacy

Hippocampus remembers what is on your screen so you, and the AI tools you choose, can use it later. This page says what it keeps, where, what leaves your Mac and when, and how to stop it. It links the code that does each thing, so you can check rather than trust.

## In short

- **You can tell.** A solid dot on the hi in the menu bar means it is remembering. A hollow dot means a password field is active and nothing is read. No dot means it is paused or off. While it isn't remembering, the window says so in a line at the top of every page.
- **It stays on your Mac, encrypted.** Hippocampus has no server and no account, and uploads nothing you saw.
- **Some things are skipped before anything is stored.** Password fields, password managers and authenticator apps, private browser windows that show they are private, a list of bank, sign-in and password-manager sites, and text in a few secret shapes, such as card numbers and one-time codes. The rules, and what they miss, are below.
- **Your AI tools get it only if you connect them, or send it yourself.** Ask Claude, and the same button for your other AI tools, opens the tool with your message in its box. Nothing is sent until you press send there. What a tool reads goes to the company that runs it.
- **Your calendar is optional.** Hippocampus reads it only after you turn it on, on this Mac, and never sends it anywhere ([below](#your-calendar)).
- **Resume opens things only when you click.** It sends nothing anywhere ([below](#resume)).
- **You can stop it.** Pause from the menu bar or the window, Quit, or Stop Sharing in macOS.
- **Forgetting is real.** Forget a moment, a page, a session, the last 10 minutes, the last hour, today or everything, and what was learned from those moments goes too.
- **Counts, not keystrokes.** It counts key presses to tell typing from reading. It doesn't record which keys, or any sound. The key that opens Ask (Shift twice, or Fn if you choose it) is noticed from the modifier keys alone, never from what you type.

## What is stored

- Text read from your screen, with the app, the window's title, the time, and the page's address when the optional browser extension gives it, or when you turn on reading addresses through Automation ([below](#what-is-skipped), off by default).
- The window you are working in is read when it changes: at most every 3 seconds plugged in, 6 on battery and 12 in Low Power Mode, and every 15 seconds or more while it keeps moving, as a video does ([FocusedReadPacing.swift](adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/FocusedReadPacing.swift)).
- The other windows you can see, on every display, are read when their text changes: at most every 30 seconds plugged in and every 60 on battery. In Low Power Mode only the window you are working in is read ([CapturePower.swift](adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/CapturePower.swift), [ADR-0041](docs/decisions/0041-browsers-and-reading-cadence.md)).
- After every read the reader rests: three times as long as the read took when plugged in, eight times on battery, sixteen in Low Power Mode ([CaptureReadBudget.swift](adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/CaptureReadBudget.swift)).
- Screenshots of the window you're working in, and of other windows you can see when their text changes, each sealed in its own encrypted file ([below](#where-it-is-kept)). Nothing that is skipped is pictured.
- A picture of another window shows only that window: every window in front of it, and whatever shows past its rounded corners, is blanked out before the picture is made smaller ([WindowPictureCrop.swift](adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/WindowPictureCrop.swift)). None is kept of a call or video app, of a window whose title names a call or a video site such as Google Meet or YouTube, or of a private window that shows it is private; and at most one of a window every 2 minutes unless its title changes, 30 an hour and 300 a day ([SideWindowPicturePolicy.swift](adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/SideWindowPicturePolicy.swift)). The window you're working in has no such rule: its screenshots are kept during a call or a video too, unless macOS blacks the video out ([below](#what-is-skipped)).
- Pictures of other windows use at most 2 GB, or 2% of the disk if that is less; Preferences, under Remembering, changes that to 1, 2 or 5 GB, or turns them off. They are thinned out as they age, the oldest go first when the budget is full, and none is kept while the disk has less than 10 GB free ([side_pictures.rs](core/brain/src/side_pictures.rs)). Text is never thinned. On a Mac that used Hippocampus before this version, pictures of other windows stay off until you turn them on.
- Sessions, a summary of your day, and what it learned about you, each linked to the moments behind it. They are written on this Mac, by Apple Intelligence or by a model you run yourself.
- For each moment, one short line saying what it was about and its text without the window's tabs and bars. They are kept beside what was read, which they never replace, and are deleted with it. The line is written on this Mac, by Apple Intelligence or a model you run yourself, and kept only when its words come from that moment and it makes no guess about you (your work, health, money, relationships or who you are). The model is not asked about a moment that touches one of these, or about a window that was only open beside the one you used. Otherwise the line is made from the window title.
- Search data made from that text, so you can search by meaning.
- What you're working on, by name: code projects, documents, designs and spreadsheets you spent 30 minutes on, named from their window titles on this Mac by fixed rules, not by a model ([subject.rs](core/brain/src/subject.rs), [work.rs](apps/agent/src/understanding/work.rs)). Names that look personal stay out of the sidebar until you show them. Hiding or showing one keeps only a keyed hash of it in the window's settings, never the name.
- Activity counts: how many keys, clicks and scrolls every few seconds. Never which keys.
- **Mail and Messages, only if you turn them on.** Under Preferences, Choose Apps…, these two apps offer "Capture + Deep hook". With that on and Full Disk Access granted, Hippocampus also stores new messages from their files on this Mac, after taking out one-time codes, bank alerts and the text of mail from banks, and leaving out any message that still holds one of the [secret shapes below](#what-is-skipped) ([messages_ingest.rs](apps/agent/src/messages_ingest.rs), [mail_ingest.rs](apps/agent/src/mail_ingest.rs)). Both are off until you choose them.

macOS calls the permission "Screen & System Audio Recording". Hippocampus asks for it to see the screen, and records no sound.

## Your calendar

- **Off until you turn it on,** in Preferences, under General, or with Show Calendar on Today. Turning it on asks macOS, once, for access to your calendars.
- **Read on this Mac only:** each event's title, time, calendar name and place. A link in the place keeps only its site, so meeting codes and passcodes are dropped. Who is invited, the organizer, notes and links are never read ([EventKitCalendarStore.swift](apps/recall-ui/Sources/RecallUIKit/Calendar/EventKitCalendarStore.swift)).
- **What it is used for:** thin bars over Today's day strip, a call named after its meeting, the meetings on a project's page, and Ask's answer to "When did I last meet with …?", from titles and times.
- **What it is never used for:** it is not stored in your memory, nothing is learned about you from it, and Hippocampus never sends it to an AI tool. The part that reads the screen never reads your calendar, whether it is on or off.
- **Turning it off:** in Preferences, or take back access in System Settings, under Privacy & Security, Calendars. Today then drops the bars, and nothing else changes.

## Resume

Resume, on a project's page, on Today and in Ask, reopens what you had open for that project: its pages in the browser you read them in, its documents through their links or their apps, its code folder in your editor, and Terminal in that folder.

- **Nothing opens until you click.** A sheet lists exactly what will open, with a checkbox for each.
- **It sends nothing anywhere.** It asks macOS to open what you ticked.
- **It never offers** private windows, password apps, the sites and apps Hippocampus never reads, or anything you forgot.
- **Tabs already open aren't opened twice,** where the browser can say: in Chrome, Brave, Edge, Vivaldi, Chromium and Arc, Hippocampus asks which tabs are open in normal windows, never private ones, compares their addresses on this Mac and keeps none of them. macOS asks you about this the first time Resume opens tabs in each of those browsers while it is running. Safari's tabs open again, because Safari can't leave its private windows out of the answer. Saying yes doesn't let Hippocampus save page addresses.

## Demo Memory

Option-click the hi in the menu bar, or open Preferences, under About, to use Demo Memory: a made-up week at a made-up company, for videos and screenshots. It is a separate store in its own folder, with its own key, made by a tool in this repo ([mci_seed_brain.rs](apps/agent/src/bin/mci_seed_brain.rs), [apps/demo-memory](apps/demo-memory)). While it is in use, remembering is paused, the window shows a small Demo tag, and the menu, Ask's footer and the window's footer say Demo Memory. Resume says "Made up for the demo, so nothing opens." for the week's files, documents and made-up sites, and for its folders except the project's own, which Demo Memory makes, empty, so Resume can open it in your editor and Terminal; its pages on real sites, and Open Link, open in your own browser. Privacy shows the week's own activity and storage, and its Delete Everything deletes only the week. Leave Demo Memory goes back to your own memory, which is untouched. AI tools you connected still read your own memory while it is in use; disconnect them first if you film one.

## Where it is kept

- Text, sessions and search data are in one encrypted database (SQLCipher) in `~/Library/Application Support/MCI/`. Screenshots are separately encrypted files beside it, in `MCI/blobs/`.
- The key is in your login Keychain and is not synced. AI tools you connect are given a Keychain reference, never the key. A development build can use a file key (`dev.key`, mode 0600) only when `MCI_DEVELOPMENT_FILE_KEY=1` is set; a release build never does.
- If your key was ever in a file (a `dev.key` from a build before 0.1, or a copy of one in this folder), Hippocampus moves your memory to a new key once, the next time it starts: it keeps an encrypted copy until the move is checked, then deletes the file, the copy and the old key. A backup made before the move still holds the old key and opens what was in it then.
- Time Machine doesn't back up `~/Library/Application Support/MCI/` unless you turn on Include my memory in Time Machine backups, in Preferences, under Privacy. A backup can restore your memory, but it also keeps what you delete until that backup expires.
- Everything is kept for 90 days, unless you choose otherwise in Preferences, under Privacy. Anything older is deleted for good.
- Logs and crash records are in `~/Library/Logs/MCI/`.
- The window keeps a plain-text log of what was done to your memory: launches, deletions and exports, with counts, times and an export's file path, never what you saw. It is `~/Library/Application Support/Hippocampus/audit.log`, and deleting your memory leaves it.

The data folders and two background processes (mci-agent, MCICaptureHelper) carry MCI, the project's early working name.

## What leaves your Mac

Hippocampus uploads nothing you saw. What you saw leaves your Mac only in one of these ways:

- **You connect an AI tool**, such as Claude Code or Codex. It is added to the tool as an MCP server named `hippocampus`. While it is connected, the tool can search all of your memory and read moments, sessions, your day and what Hippocampus learned about you. If you let it, each session also starts with up to four lines of recent work and up to six things learned about you, with sources ([query.rs](apps/agent/src/understanding/query.rs)): every Claude Code session, and every Codex session once you allow its hook in Codex; until then, or with Codex's hooks turned off, Codex is asked to fetch your recent work when a task starts, and Codex decides ([SessionContextInstaller.swift](apps/hippocampus/Sources/HippocampusKit/SessionContextInstaller.swift)). Those lines are written on this Mac from what you read on screen, and AI Tools shows them word for word. A line goes only once the model is sure of it and three moments on two different days show it, or once you confirmed it; a line about your health, money, relationships or another sensitive area goes only if you confirm it ([sending.rs](apps/agent/src/understanding/sending.rs)). About You shows each one, and Forget removes it. A connected tool starts its own reader of your memory (`mci-agent mcp-serve`), so it can read while Hippocampus is quit. Connecting Codex writes Hippocampus into Codex's settings file, `~/.codex/config.toml` ([client_registry.rs](apps/agent/src/client_registry.rs)). [OpenAI's documentation](https://developers.openai.com/codex/mcp) says the ChatGPT desktop app shares that file with Codex, so Codex there can look things up too. ChatGPT on the web doesn't read it. What a tool reads goes to the company that runs the tool, under that company's terms. Hippocampus's answers to it, and the session-start lines, have the [secret shapes below](#what-is-skipped) taken out on the way, even if one was stored ([outbound.rs](apps/agent/src/outbound.rs)). The tool also keeps what it reads in its own history on this Mac, unencrypted: Claude Code in `~/.claude`, Codex in `~/.codex`. Hippocampus can't encrypt, expire or delete that copy, so forgetting a moment here doesn't remove it there. When you connect a tool whose history other accounts on this Mac can open, Hippocampus offers to make it private to you, and changes nothing unless you choose Make Private ([ToolHistoryPrivacy.swift](apps/hippocampus/Sources/HippocampusKit/ToolHistoryPrivacy.swift)).
- **You use Ask {your tool}.** Ask Claude, Ask ChatGPT and the rest make the message on this Mac and open the tool with it in the message box, through the tool's own link (`claude://`, `codex://`, `cursor://`). Memory never goes in a web address, which a browser would keep in its history. ChatGPT, and Claude Code without its desktop app, get the message on the clipboard instead. Nothing is sent until you press send in the tool. Just before it opens, lines that look like a password or a code are taken out, links lose their query strings, and moments you forgot since are left out ([handoff_card.rs](apps/agent/src/handoff_card.rs)). A screenshot goes only when you tick Include Screenshot.
- **You use Copy for Your AI.** The text goes to your clipboard, and you paste it where you choose. The copy stays on this Mac (not on your other devices), is marked so clipboard history apps don't keep it, and is cleared after 2 minutes if it is still there ([ClipboardHygiene.swift](apps/recall-ui/Sources/RecallUIKit/Handoff/ClipboardHygiene.swift)).
- **You use a model you run yourself.** If answers come from Ollama or LM Studio, Hippocampus sends that server the text an answer needs. It talks only to servers on this Mac (127.0.0.1, ::1 or localhost), follows no redirects, and skips Ollama's cloud models, whose names end in `-cloud` or `:cloud` ([LocalServerEngine.swift](apps/mind/Sources/MindKit/LocalServerEngine.swift)). Some servers can pass text on to the cloud, so pick a model that runs on your Mac.

These requests carry nothing you saw:

- The updater (Sparkle) asks `github.com/amyjainberkeley/hippocampus/releases/latest/download/appcast.xml`, which GitHub serves from `release-assets.githubusercontent.com`, whether there is a newer version. It asks when you click Check for Updates, or daily if you turn on automatic checks. It checks an update's signature before installing it.
- If you list MCP servers in `~/Library/Application Support/MCI/Config.noindex/mcp-servers.toml` (a folder Spotlight skips, since the file can hold a sign-in header), Hippocampus reads from them. It refuses any address that is not on this Mac.

There is no analytics and no telemetry. The text reader's ONNX Runtime library includes Microsoft's telemetry client: Hippocampus turns it off and runs the reader with no network access ([OCRWorkerSandbox.swift](adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/OCR/OCRWorkerSandbox.swift)). Earlier versions did neither: from 0.2.0, their reader sent ONNX Runtime's usage events and a device ID to Microsoft. The app deletes the two folders that left in `~/Library` (`Caches/hippocampus-ocr`, `HTTPStorages/hippocampus-ocr`) when it starts; ONNX Runtime's own `~/Library/Application Support/Microsoft/DeveloperTools/.onnxruntime` is shared with other apps, so it stays. There is no crash reporting; crash records stay in `~/Library/Logs/MCI/`. ADR-0025, which planned opt-in analytics, is withdrawn.

### Disconnecting an AI tool

In Preferences, under AI Tools, click Disconnect… for a tool, or Disconnect All…. Hippocampus takes out exactly what it added to the tool's settings and leaves the rest as it was ([client_status.rs](apps/agent/src/client_status.rs)). Restart the tool. What it already read stays in its history. The window's AI Tools page shows what each tool can reach and the exact words its sessions start with.

## What is skipped

These checks run before anything is stored. They are rules, so they catch what they were built and tested for, and they can miss.

- **Password fields.** While one is active anywhere on screen, nothing is read, and the menu-bar dot turns hollow.
- **Password managers and authenticator apps, by bundle ID:** Apple's Passwords and Keychain Access, 1Password, Bitwarden, Dashlane, LastPass, KeePassXC, Keeper, NordPass, Proton Pass, Enpass, Yubico Authenticator and the rest of a list of 66 identifier families, which a test checks against 76 identifiers, each with its source ([CaptureAdmissionPolicy.swift](adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Suppression/CaptureAdmissionPolicy.swift), [NeverReadPasswordManagersTests.swift](adapters/macos/MCICaptureHelper/Tests/MCICaptureHelperKitTests/NeverReadPasswordManagersTests.swift)). One that isn't on the list is read like any other app, with the checks below. You can add any app to your own list ([GUIDE.md](docs/GUIDE.md#keep-an-app-out)).
- **These apps too, by bundle ID:** System Settings, sign-in and permission dialogs, the lock screen and the screen saver, and Hippocampus's own windows.
- **Notification banners** stay out of the reads of other windows, because they often carry one-time codes.
- **Protected video.** macOS blacks it out of screen captures, and a blacked-out area stops that read.
- **Private browser windows that show they are private:** Incognito, InPrivate or Private Browsing in the window's title or top bar. A private window that shows none of these is read.
- **A list of bank, sign-in and password-manager sites** (30 addresses, in the same file), when the site's address shows in the window's title or address bar.
- **Text in a few secret shapes** is refused before it is stored: a password, secret, key or token written as `name: value` or `name = value`; an API key or token in the shape Anthropic, OpenAI, GitHub, GitLab, Slack, Google, AWS or Stripe gives it (Stripe's secret and restricted keys, live and test; its publishable keys are public and are kept); a JSON web token; the first line of a private key; a long token after `Bearer`; a credit-card number that passes the Luhn check; and a one-time code: a number of 4 to 8 digits within about 40 characters of words like "verification code", "one-time", "passcode", "OTP" or "2FA". The window's title and the page's address are checked as well as the text. First, an address loses its sign-in parameters, such as `access_token`, `token`, `code`, `key`, `api_key`, `sig`, `signature`, `password`, `secret` or `auth`, and the password in `name:password@`; that is the only address kept. On screen, every saved moment is checked three times: the text as read, the page in reading order, and the exact text saved ([SuppressionCascade.swift](adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Suppression/SuppressionCascade.swift)). Then mci-agent, the one program that writes your memory, checks the text, title and address again for everything it stores, whatever it came from: the screen, the browser extensions, Mail and Messages, sessions imported from Claude Code or Codex, and MCP servers you list. A moment, page, message or session turn that fails is not stored at all ([secret_gate.rs](apps/agent/src/secret_gate.rs), [ocr_secrets.rs](core/brain/src/redaction/ocr_secrets.rs), fixtures in [`core/brain/fixtures/`](core/brain/fixtures/)). These rules lean toward leaving ordinary numbers alone: a card number is skipped only when it passes the Luhn check, so phone numbers, order ids and dates are kept, and a lone code with no nearby word, or a one-time code in a format those words don't name, can still be stored. A bank alert shown on screen is not one of these shapes either; the Messages and Mail deep hook, if you turn it on, takes bank alerts out on its own path.

Browsers are read like every other window, with no extension and no Automation prompt. Hippocampus never asks for Automation while it remembers. Where you allowed it, for Resume or for setup's Safari step, remembering uses it only to tell whether a Chrome-family window is private. Reading page addresses through Automation is a separate setting, off by default and not in Preferences ([GUIDE](docs/GUIDE.md#settings-without-a-switch)), so unless you turn it on, the addresses Today and Looked Up use for your searches come from the browser extension.

## How to stop it

- Pause from the menu bar: for an hour, until 6:00 AM tomorrow, or until you start it again with Start Remembering. A pause lasts across restarts.
- Quit from the menu bar, or press ⌘Q. Everything Hippocampus started stops. A connected AI tool's own reader keeps running until you close that tool.
- Stop Sharing in macOS's screen-recording menu. Hippocampus turns off until you turn it on.
- Take back a permission any time in System Settings, under Privacy & Security.

## How to delete it

- From the window: a moment or a few you picked (⌘⌫, with Undo for a few seconds), an hour of History, a session on Today, a web page or a search, or recent time with Forget Recent… (⇧⌘⌫): the last 10 minutes, the last hour or today. Larger ones ask you first. While Hippocampus is remembering, it holds still while a forget runs, a few seconds or, on a large memory, a minute or more, then carries on.
- The last 24 hours, or everything: on the window's Privacy page. Both ask you to confirm first, and what was learned from those moments goes too. The database file is then rewritten without them, and its log is emptied. Delete Everything also deletes the key, so copies of your memory in earlier backups or snapshots can't be read any more; a new key is made for what comes next.
- You can export every moment, in full, as JSON lines, on the same page. It asks where to save. The file isn't encrypted, only your account can open it, and in Desktop, Documents or iCloud Drive it may sync to iCloud.
- Something it learned about you: Forget, on About You.
- Pictures of other windows only: Forget Pictures of Other Windows…, in Preferences, under Remembering. Their text stays.
- Removing the app: disconnect your AI tools (above), quit Hippocampus, then move it to the Trash. Delete everything first if you want your memory gone too; that deletes its key as well. With Hippocampus quit, `/Applications/Hippocampus.app/Contents/MacOS/mci-agent erase-memory` does the same.

## Threat model

- **Encryption protects the memory at rest.** A copy of the database or a screenshot file, in a backup or on a lost disk, can't be read without the key in your login Keychain. A Time Machine backup that includes your memory also holds that keychain, which opens with your login password; that is why the memory is left out of backups unless you include it.
- **It doesn't protect against software running as you.** A program that runs under your login can read your screen itself, or start Hippocampus's own `mci-agent` and read your memory the way a connected AI tool does. Keep malware off your Mac; Hippocampus can't tell it from you.
- **A connected AI tool can read all of your memory**, a search at a time, for as long as it is connected, including while Hippocampus is quit. Disconnect stops that.
- **Screen text can carry instructions aimed at an AI.** Session-start text and `mci-agent context` begin by telling the AI that memory is reference, never instructions. Search results carry no such line. A page written to steer an AI can still steer one, so review what a connected tool proposes to do.
- **The skipping rules above are pattern rules.** A password shown in plain text in an app they don't know, or a secret in a shape the checks don't catch, can be stored. Then delete it, and report the shape ([SECURITY.md](SECURITY.md)).

## Where this is decided

- [ADR-0001: privacy posture](docs/decisions/0001-privacy-posture-local-first-e2e.md)
- [ADR-0013: what is never read](docs/decisions/0013-native-grade-sensitive-surface-suppression.md)
- [ADR-0041: browsers and how often windows are read](docs/decisions/0041-browsers-and-reading-cadence.md)
- [ADR-0047: pictures of windows beside the front one](docs/decisions/0047-side-window-pictures.md)
- [ADR-0048: Ask {your tool} and Disconnect](docs/decisions/0048-ask-your-tool-and-disconnect.md)
- [ADR-0049: the calendar, optional and on this Mac](docs/decisions/0049-calendar.md)
- [ADR-0050: Demo Memory](docs/decisions/0050-demo-memory.md)
- [SECURITY.md](SECURITY.md) for reporting a gap.
