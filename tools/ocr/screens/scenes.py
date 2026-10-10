"""Synthetic app screens with complete, ordered ground truth.

Each scene is laid out as absolutely positioned blocks (a sidebar, a message
pane, an editor). Every visible string is listed, so the truth is complete:
an engine that reads chrome or labels is not reading text the truth lacks.
Reading order is block order, then line order inside a block. Text never
wraps, so each truth line is exactly one visual row of one block.

The text is fabricated. No real person, message or credential appears.
"""
import html

SANS = "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif"
MONO = "Menlo, 'SF Mono', monospace"


def block(x, y, lines, *, size=13, color='#1d1d1f', font=SANS, weight=400,
          line_height=1.55, bold=()):
    return {'x': x, 'y': y, 'lines': lines, 'size': size, 'color': color,
            'font': font, 'weight': weight, 'line_height': line_height,
            'bold': set(bold)}


SCENES = {}

SCENES['chat_light'] = {
    'background': '#ffffff',
    'panels': [(0, 0, 250, 900, '#f4f4f6'), (250, 0, 1190, 52, '#ffffff')],
    'blocks': [
        block(20, 22, ['Northwind Studio', 'Channels', '# general', '# design-review',
                       '# launch-plan', '# eng-oncall', 'Direct messages', 'Maya Chen',
                       'Ravi Patel', 'Jonas Weber'], size=14, color='#3a3a3c', bold=(0, 1, 6)),
        block(280, 16, ['# design-review'], size=16, weight=600),
        block(280, 80, [
            'Maya Chen  10:42 AM',
            'Pushed the new onboarding flow to staging. The permissions step is now one screen.',
            'Can someone check the copy on the screen recording prompt before 3 PM?',
            'Ravi Patel  10:47 AM',
            'Looks good. One nit: "Allow capture" should say "Turn on memory" to match the menu.',
            'Also the retention picker defaults to 90 days, which matches the spec (DOC-2291).',
            'Jonas Weber  11:05 AM',
            'Benchmarks from last night: recall p95 is 41 ms on the 100k-event brain.',
            'Embedding backfill finished in 6m 12s; 0 events skipped, 3 retried.',
            'Maya Chen  11:09 AM',
            'Great. Shipping 0.2.1 to the beta group after lunch unless anyone objects.',
        ], size=14, bold=(0, 3, 6, 9)),
        block(280, 840, ['Message #design-review'], size=14, color='#8e8e93'),
    ],
}

SCENES['code_dark'] = {
    'background': '#1e1e1e',
    'panels': [(0, 0, 260, 900, '#252526'), (0, 870, 1440, 30, '#007acc')],
    'blocks': [
        block(16, 14, ['EXPLORER', 'HIPPOCAMPUS', 'apps', 'agent', 'src', 'brain_ingest.rs',
                       'retention_worker.rs', 'today.rs', 'core', 'scripts', 'install.sh',
                       'README.md'], size=12, color='#cccccc'),
        block(280, 12, ['retention_worker.rs'], size=13, color='#ffffff'),
        block(280, 56, [
            'use std::time::Duration;',
            '',
            '/// Delete events older than the configured window, oldest first.',
            'pub fn sweep(store: &Store, config: RetentionConfig) -> Result<u64, SweepError> {',
            '    let Some(cutoff_us) = config.cutoff_us(now_us()) else {',
            '        return Ok(0);',
            '    };',
            '    let mut deleted = 0_u64;',
            '    for batch in store.events_before(cutoff_us).chunks(512) {',
            '        deleted += store.delete_batch(batch)?;',
            '        std::thread::sleep(Duration::from_millis(25));',
            '    }',
            '    if deleted > 0 {',
            '        store.vacuum()?; // reclaim pages so deleted text is gone',
            '    }',
            '    Ok(deleted)',
            '}',
        ], size=13, color='#d4d4d4', font=MONO, line_height=1.6),
        block(12, 876, ['main  0 errors, 2 warnings  Ln 14, Col 37  UTF-8  Rust'],
              size=12, color='#ffffff'),
    ],
}

SCENES['article_columns'] = {
    'background': '#ffffff',
    'panels': [(0, 0, 1440, 56, '#fafafa')],
    'blocks': [
        block(40, 18, ['The Field Notes          Research     Essays     Archive     Subscribe'],
              size=14, color='#333333'),
        block(40, 90, ['Why your computer', 'forgets everything'], size=30, weight=700,
              line_height=1.25),
        block(40, 190, [
            'Every day a laptop sees the paper you',
            'skimmed, the number in the dashboard and',
            'the error you fixed in March. Then it',
            'forgets all of it, and you do the',
            'remembering: scrolling history, searching',
            'files for a word you are not sure you used.',
        ], size=16, line_height=1.6),
        block(500, 190, [
            'People remember situations, not names.',
            'The pricing page from last Tuesday, read',
            'while annoyed, is easy to recall and hard',
            'to search for. A memory that keeps what',
            'was on screen, and when, can answer the',
            'question the way it was actually asked.',
        ], size=16, line_height=1.6),
        block(1000, 190, ['Related', 'On-device OCR, measured', 'A year of local search',
                          'Encryption at rest, explained', 'Most read this week'],
              size=13, color='#555555', bold=(0, 4)),
    ],
}

SCENES['terminal_dark'] = {
    'background': '#0c0c0c',
    'panels': [],
    'blocks': [
        block(20, 16, [
            'amy@studio hippocampus % cargo test -p mci-agent --test handoff_cli',
            '   Compiling mci-agent v0.2.1 (/Users/amy/hippo-work/usable/apps/agent)',
            '    Finished `test` profile [unoptimized + debuginfo] target(s) in 41.07s',
            '     Running tests/handoff_cli.rs (target/debug/deps/handoff_cli-73790ef006b0f461)',
            'test today_prints_the_daily_packet ... FAILED',
            "thread 'today_prints_the_daily_packet' panicked at apps/agent/tests/handoff_cli.rs:266:5:",
            'assertion failed: text.contains("## hippocampus (")',
            'error[E0308]: mismatched types: expected `u64`, found `i64`',
            'test result: FAILED. 8 passed; 1 failed; 0 ignored; finished in 1.91s',
            'amy@studio hippocampus % git log --oneline -3',
            '539ece6 fix(recall): return degraded rankings as labelled hits',
            '328afb9 Qualify retained JPEG screenshots through local OCR',
            'afed4a3 Allow explicit screenshot re-read to recover key access',
            'amy@studio hippocampus % shasum -a 256 dist/Hippocampus-0.2.1.dmg',
            '14443edcdcb43c00455a86d9b454b2c19aeb990b250d99ecb435e7dc643fc823',
            'amy@studio hippocampus % curl -I https://example.com/v1/status?id=42&mode=full',
        ], size=13, color='#e5e5e5', font=MONO, line_height=1.55),
    ],
}

SCENES['email_panes'] = {
    'background': '#ffffff',
    'panels': [(0, 0, 200, 900, '#f2f2f7'), (200, 0, 420, 900, '#fbfbfd')],
    'blocks': [
        block(18, 24, ['Inbox', 'Flagged', 'Drafts', 'Sent', 'Archive', 'Receipts',
                       'Travel'], size=14, color='#3a3a3c'),
        block(222, 24, [
            'Priya Natarajan  9:14 AM',
            'Offsite agenda, final',
            'Room is booked for Thursday, 10 to 4.',
            'Linear  8:02 AM',
            'HIP-412 moved to In Review',
            'Persistent OCR worker: ready for review.',
            'Daniel Okafor  Yesterday',
            'Contract redlines (v3)',
            'Two changes in section 4.2, both minor.',
        ], size=13, bold=(0, 3, 6), line_height=1.7),
        block(650, 24, [
            'Offsite agenda, final',
            'From: Priya Natarajan    To: Team',
            'Hi all,',
            'The room is booked for Thursday from 10:00 to 16:00 at 410 Townsend.',
            'Morning: roadmap review and the Q4 hiring plan.',
            'Afternoon: customer interviews readout, then the launch checklist.',
            'Please send slides by Wednesday at noon so we can print handouts.',
            'Thanks, Priya',
        ], size=14, bold=(0,), line_height=1.75),
    ],
}

SCENES['table_light'] = {
    'background': '#ffffff',
    'panels': [(0, 0, 1440, 40, '#f5f5f7')],
    'blocks': [
        block(16, 10, ['Q3 pipeline.xlsx'], size=13, weight=600),
        block(40, 70, [
            'Account          Stage        Owner     ARR (USD)   Close date',
            'Acme Robotics    Negotiation  M. Chen   $184,000    2026-10-21',
            'Blue Harbor      Proposal     R. Patel  $92,500     2026-11-03',
            'Cedar & Pine     Discovery    J. Weber  $47,250     2026-12-15',
            'Delta Freight    Closed won   M. Chen   $310,800    2026-09-30',
            'Evergreen Labs   Negotiation  D. Okafor $128,000    2026-10-28',
            'Total                                   $762,550',
        ], size=13, font=MONO, line_height=1.9),
    ],
}

SCENES['small_labels'] = {
    'background': '#ececec',
    'panels': [(0, 0, 220, 900, '#e3e3e3')],
    'blocks': [
        block(16, 20, ['General', 'Capture', 'Privacy', 'Storage', 'Shortcuts', 'About'],
              size=12, color='#4a4a4a'),
        block(250, 20, ['Capture'], size=15, weight=600),
        block(250, 60, [
            'Remember what is on screen',
            'Text is read on this Mac and stored encrypted. Nothing is uploaded.',
            'Excluded apps',
            '1Password, Keychain Access, System Settings, Hippocampus',
            'Keep memories for',
            '90 days (about 2.4 GB on this Mac)',
            'Last capture: 2 minutes ago  ·  3,288 memories  ·  index healthy',
            'Version 0.2.1 (build 8e82e03)  ·  macOS 26.5  ·  Apple M3',
        ], size=11, color='#6e6e73', line_height=1.9, bold=(0, 2, 4)),
    ],
}

SCENES['doc_notes'] = {
    'background': '#ffffff',
    'panels': [(0, 0, 240, 900, '#f7f6f3')],
    'blocks': [
        block(18, 22, ['Workspace', 'Product notes', 'Meeting notes', 'Roadmap',
                       'Reading list'], size=14, color='#37352f'),
        block(300, 40, ['Launch checklist'], size=28, weight=700),
        block(300, 100, [
            'Owner: Maya Chen   Due: Oct 21   Status: In progress',
            'Before the beta',
            '1. Notarize the DMG and staple the ticket.',
            '2. Publish the Homebrew cask and the install script.',
            '3. Record a 30-second demo with synthetic data only.',
            'Open questions',
            '- Should retention default to 30 or 90 days?',
            '- Which apps are excluded on first run?',
            '- Do we show a capture indicator in the menu bar?',
        ], size=15, color='#37352f', line_height=1.8, bold=(1, 5)),
    ],
}


def render_html(scene):
    parts = ['<!doctype html><html><head><meta charset="utf-8"><style>',
             'html,body{margin:0;width:1440px;height:900px;overflow:hidden;',
             f'background:{scene["background"]};-webkit-font-smoothing:antialiased}}',
             '.b{position:absolute;white-space:pre}</style></head><body>']
    for x, y, w, h, color in scene['panels']:
        parts.append(f'<div style="position:absolute;left:{x}px;top:{y}px;width:{w}px;'
                     f'height:{h}px;background:{color}"></div>')
    for b in scene['blocks']:
        style = (f'left:{b["x"]}px;top:{b["y"]}px;font-family:{b["font"]};'
                 f'font-size:{b["size"]}px;line-height:{b["line_height"]};color:{b["color"]};'
                 f'font-weight:{b["weight"]}')
        rows = []
        for i, line in enumerate(b['lines']):
            text = html.escape(line) if line else '&nbsp;'
            weight = 'font-weight:600' if i in b['bold'] else ''
            rows.append(f'<div style="{weight}">{text}</div>')
        parts.append(f'<div class="b" style="{style}">' + ''.join(rows) + '</div>')
    parts.append('</body></html>')
    return ''.join(parts)


def truth_lines(scene):
    """Ground truth in reading order: blocks, then rows. Blank rows dropped."""
    return [line for b in scene['blocks'] for line in b['lines'] if line.strip()]


def truth_blocks(scene):
    return [[line for line in b['lines'] if line.strip()] for b in scene['blocks']]
