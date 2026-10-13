"""Mock app windows that look like real ones, with a role on every string.

The scenes in scenes.py are text on flat panels. Real windows also have title
bars, tab strips, icon bars, sidebars, gutters, toolbars and status bars, and
that is where a transcript goes wrong. Each window here is one HTML page; every
string a person could read sits in an element tagged with its role:

    content     what the window is showing; must be read, in reading order
    navigation  lists of other places (folders, channels, other messages);
                may be left out of the reading or put after it
    chrome      the interface (bars, tabs, buttons, counts, line numbers,
                placeholders); must not be in the reading

Icons are line drawings with no text, the kind an engine misreads as letters.
Bullets, avatars and formatting buttons are untagged marks.

Three kinds of window:
- six realistic windows (editor, chat, mail, article, video, notes), the set
  the transcript work was measured on;
- `messages`, a two-sided bubble chat, where who said what lives in the
  indentation;
- six decoys whose look invites a chrome rule but whose text is content: a
  ticket's properties panel, an order summary, a to-do list beside notes, a
  full-screen document whose first and last rows are text, a receipt whose
  rows sit between rules that span it, and an invitation whose date sits alone
  on a centred line. A rule that moves any of that out of the reading is wrong.

The text is fabricated. No real person, message or credential appears.
"""
import html
from html.parser import HTMLParser

CONTENT, NAVIGATION, CHROME = 'content', 'navigation', 'chrome'

CSS = (
    'html, body { margin: 0; width: 1440px; height: 900px; overflow: hidden; '
    'font: 13px/1.45 -apple-system, "Helvetica Neue", sans-serif; -webkit-font-smoothing: antialiased; }\n'
    '* { box-sizing: border-box; }\n'
    '.row { display: flex; align-items: center; }\n'
    '.col { display: flex; flex-direction: column; }\n'
    'svg.i { width: 16px; height: 16px; flex: none; fill: none; stroke: currentColor; stroke-width: 1.6; }\n'
    '.mono { font-family: Menlo, "SF Mono", monospace; }\n'
    '.dots { display: flex; gap: 8px; padding: 0 12px; } '
    '.dots i { width: 12px; height: 12px; border-radius: 50%; display: block; }\n'
    '.dots i:nth-child(1) { background: #ff5f57 } .dots i:nth-child(2) { background: #febc2e } '
    '.dots i:nth-child(3) { background: #28c840 }\n'
    '.trunc { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }\n'
)


def _icon(body):
    return f'<svg class="i" viewBox="0 0 16 16">{body}</svg>'


I = {name: _icon(body) for name, body in {
    'files': '<path d="M4 2h5l3 3v9H4z"/><path d="M9 2v3h3"/>',
    'search': '<circle cx="7" cy="7" r="4"/><path d="M10 10l4 4"/>',
    'branch': '<circle cx="4" cy="4" r="1.6"/><circle cx="4" cy="12" r="1.6"/><circle cx="12" cy="6" r="1.6"/>'
              '<path d="M4 5.6v4.8M12 7.6c0 2.4-8 1-8 2.8"/>',
    'gear': '<circle cx="8" cy="8" r="2.2"/><path d="M8 1.5v2M8 12.5v2M1.5 8h2M12.5 8h2M3.4 3.4l1.4 1.4'
            'M11.2 11.2l1.4 1.4M3.4 12.6l1.4-1.4M11.2 4.8l1.4-1.4"/>',
    'close': '<path d="M4 4l8 8M12 4l-8 8"/>',
    'plus': '<path d="M8 3v10M3 8h10"/>',
    'star': '<path d="M8 2l1.8 3.8 4.2.6-3 2.9.7 4.1L8 11.4 4.3 13.4l.7-4.1-3-2.9 4.2-.6z"/>',
    'box': '<rect x="2.5" y="2.5" width="11" height="11" rx="2"/>',
    'split': '<rect x="2" y="3" width="12" height="10" rx="1.5"/><path d="M8 3v10"/>',
    'bell': '<path d="M4 11V7a4 4 0 018 0v4l1.5 1.5h-11z"/><path d="M6.5 14h3"/>',
    'chevron': '<path d="M6 4l4 4-4 4"/>',
    'back': '<path d="M10 3L5 8l5 5"/>',
    'fwd': '<path d="M6 3l5 5-5 5"/>',
    'reload': '<path d="M13 8a5 5 0 11-1.5-3.5M13 2.5v3h-3"/>',
    'lock': '<rect x="4" y="7" width="8" height="6" rx="1.2"/><path d="M5.5 7V5.5a2.5 2.5 0 015 0V7"/>',
    'play': '<path d="M5 3.5v9l7-4.5z"/>',
    'menu': '<path d="M3 4.5h10M3 8h10M3 11.5h10"/>',
    'send': '<path d="M2 8l12-5-4 11-2.5-4.5z"/>',
    'smile': '<circle cx="8" cy="8" r="5.5"/><path d="M6 9.5c1 1.2 3 1.2 4 0M6 6.5h.01M10 6.5h.01"/>',
    'clip': '<path d="M11 5.5l-4.5 4.5a1.6 1.6 0 002.2 2.2l5-5a3 3 0 00-4.3-4.3l-5 5a4.4 4.4 0 006.2 6.2L13 11.5"/>',
    'trash': '<path d="M3 4.5h10M6 4.5V3h4v1.5M4.5 4.5l.6 8.5h5.8l.6-8.5"/>',
    'inbox': '<path d="M2.5 9l2-5.5h7l2 5.5v3.5h-11z"/><path d="M2.5 9h3l1 1.5h3l1-1.5h3"/>',
    'folder': '<path d="M2 4.5h4l1.5 1.5H14v6.5H2z"/>',
    'thumb': '<path d="M5 7.5l2.5-5c1 0 1.7.8 1.5 1.8L8.5 6.5h3.8c.8 0 1.4.8 1.2 1.6l-1 4c-.2.6-.7.9-1.2.9H5z'
             'M2.5 7.5H5V13H2.5z"/>',
}.items()}


def _tag(role):
    def tagged(text, style=''):
        style = f' style="{style}"' if style else ''
        return f'<span data-role="{role}"{style}>{html.escape(text, quote=False)}</span>'
    return tagged


c, n, x = _tag(CONTENT), _tag(NAVIGATION), _tag(CHROME)


def _page(body, size=(1440, 900)):
    css = CSS.replace('width: 1440px; height: 900px;', f'width: {size[0]}px; height: {size[1]}px;')
    return f'<!doctype html><html><head><meta charset="utf-8"><style>{css}</style></head><body>{body}</body></html>'


EDITOR_CODE = [
    'use std::time::Duration;', '',
    '/// Delete events older than the configured window, oldest first.',
    'pub fn sweep(store: &Store, config: RetentionConfig) -> Result<u64, SweepError> {',
    '    let Some(cutoff_us) = config.cutoff_us(now_us()) else {',
    '        return Ok(0);', '    };',
    '    let mut deleted = 0_u64;',
    '    for batch in store.events_before(cutoff_us).chunks(512) {',
    '        deleted += store.delete_batch(batch)?;',
    '        std::thread::sleep(Duration::from_millis(25));', '    }',
    '    if deleted > 0 {',
    '        store.vacuum()?; // reclaim pages so deleted text is gone', '    }',
    '    Ok(deleted)', '}',
]


def _editor():
    tree = ['apps', 'agent', 'src', 'brain_ingest.rs', 'retention_worker.rs', 'today.rs', 'understanding',
            'core', 'docs', 'scripts', 'install.sh', 'Cargo.toml', 'README.md']
    code = EDITOR_CODE
    chat = [
        ('You', 'Why does the sweep sleep between batches?'),
        ('Assistant', 'So a long sweep never holds the writer for more than one batch. Each batch deletes at '
                      'most 512 events, then yields for 25 ms so capture can write.'),
        ('You', 'Could we make the batch size configurable?'),
        ('Assistant', 'Yes. Add batch_size to RetentionConfig with a default of 512 and clamp it between 64 '
                      'and 4096. I can draft the change and a test that checks the clamp.'),
    ]
    term = ['$ cargo test -p mci-agent retention', '   Compiling mci-agent v0.3.0',
            '    Finished `test` profile in 41.07s', 'running 6 tests',
            'test retention::sweep_deletes_oldest_first ... ok', 'test retention::sweep_stops_at_cutoff ... ok',
            'test result: ok. 6 passed; 0 failed']
    tree_rows = ''.join(
        f'<div class="row" style="padding:2px {44 if 2 < i < 7 else 26}px;gap:6px;'
        f'{"background:#37373d;color:#fff" if t == "retention_worker.rs" else ""}">'
        f'{I["files"] if "." in t else I["folder"]}{n(t)}</div>' for i, t in enumerate(tree))
    tabs = ''.join(
        f'<div class="row" style="height:35px;padding:0 10px;gap:8px;border-right:1px solid #1e1e1e;'
        f'{"background:#1e1e1e;color:#fff" if i == 1 else ""}">{I["files"]}{x(t)}{I["close"]}</div>'
        for i, t in enumerate(['brain_ingest.rs', 'retention_worker.rs', 'Hippocampus end-to-end usab…',
                               'today.rs']))
    code_rows = ''.join(
        f'<div class="row"><span data-role="{CHROME}" style="width:52px;text-align:right;padding-right:16px;'
        f'color:#858585">{i + 1}</span>{c(line, "color:#d4d4d4") if line else ""}</div>'
        for i, line in enumerate(code))
    chat_rows = ''.join(
        f'<div class="col" style="gap:3px"><div style="font-weight:600;color:#fff">{c(who)}</div>'
        f'<div>{c(text)}</div></div>' for who, text in chat)
    term_rows = ''.join(f'<div>{c(line)}</div>' for line in term)
    return _page(f'''
<div class="col" style="height:900px;background:#1e1e1e;color:#ccc">
  <div class="row" style="height:36px;background:#323233;font-size:12.5px"><div class="dots"><i></i><i></i><i></i></div><div style="flex:1;text-align:center">{x('retention_worker.rs — hippocampus')}</div><div class="row" style="gap:12px;padding:0 12px">{I['split']}{I['box']}</div></div>
  <div class="row" style="flex:1;min-height:0;align-items:stretch">
    <div class="col" style="width:48px;background:#333;align-items:center;gap:22px;padding-top:14px;color:#858585">{I['files']}{I['search']}{I['branch']}{I['play']}{I['box']}<div style="flex:1"></div>{I['gear']}</div>
    <div class="col" style="width:230px;background:#252526;padding:10px 0;font-size:12.5px">
      <div style="padding:0 16px 8px;font-size:11px;letter-spacing:.04em">{x('EXPLORER')}</div>
      <div class="row" style="padding:2px 10px;gap:4px;font-weight:600">{I['chevron']}{x('HIPPOCAMPUS')}</div>
      {tree_rows}
      <div style="flex:1"></div>
      <div class="row" style="padding:4px 10px;gap:4px;font-size:11px">{I['chevron']}{x('OUTLINE')}</div><div class="row" style="padding:4px 10px;gap:4px;font-size:11px">{I['chevron']}{x('TIMELINE')}</div>
    </div>
    <div class="col" style="flex:1;min-width:0">
      <div class="row" style="height:35px;background:#252526;font-size:12.5px">
        {tabs}
        <div style="flex:1"></div><div class="row" style="gap:12px;padding:0 12px">{I['split']}{I['menu']}</div>
      </div>
      <div class="row" style="height:22px;padding:0 16px;gap:6px;font-size:12px;color:#a0a0a0">{x('apps')}{I['chevron']}{x('agent')}{I['chevron']}{x('src')}{I['chevron']}{x('retention_worker.rs')}</div>
      <div class="row" style="flex:1;min-height:0;align-items:stretch">
        <div class="mono" style="flex:1;padding:6px 0;font-size:12.5px;line-height:19px;white-space:pre;overflow:hidden">{code_rows}</div>
        <div class="col" style="width:380px;border-left:1px solid #333;background:#1e1e1e">
          <div class="row" style="height:35px;padding:0 12px;gap:8px;font-size:11px;letter-spacing:.04em;border-bottom:1px solid #333">{x('CHAT')}<div style="flex:1"></div>{I['plus']}{I['gear']}{I['close']}</div>
          <div class="col" style="flex:1;padding:12px;gap:12px;font-size:13px">{chat_rows}</div>
          <div class="row" style="margin:12px;padding:8px 10px;border:1px solid #444;border-radius:6px;color:#858585;gap:8px">{x('Ask about your code…')}<div style="flex:1"></div>{I['clip']}{I['send']}</div>
        </div>
      </div>
      <div class="col" style="height:190px;border-top:1px solid #333">
        <div class="row" style="height:30px;padding:0 16px;gap:22px;font-size:11px;letter-spacing:.04em">{x('PROBLEMS')}{x('OUTPUT')}{x('DEBUG CONSOLE')}<span style="color:#fff;border-bottom:1px solid #fff">{x('TERMINAL')}</span>{x('PORTS')}<div style="flex:1"></div>{I['plus']}{I['trash']}{I['close']}</div>
        <div class="mono" style="padding:4px 16px;font-size:12px;line-height:18px;white-space:pre">{term_rows}</div>
      </div>
    </div>
  </div>
  <div class="row" style="height:22px;background:#007acc;color:#fff;font-size:12px;padding:0 10px;gap:16px">{I['branch']}{x('claude/hippocampus-0.3')}{x('0 ⚠ 0')}<div style="flex:1"></div>{x('Ln 9, Col 34')}{x('Spaces: 4')}{x('UTF-8')}{x('LF')}{x('Rust')}{I['bell']}</div>
</div>''')


def _chat():
    channels = ['general', 'design-review', 'launch-plan', 'eng-oncall', 'random']
    dms = ['Maya Chen', 'Ravi Patel', 'Jonas Weber']
    msgs = [
        ('Maya Chen', '10:42 AM', ['Pushed the new onboarding flow to staging. The permissions step is now one screen.',
                                   'Can someone check the copy on the screen recording prompt before 3 PM?']),
        ('Ravi Patel', '10:47 AM', ['Looks good. One nit: "Allow capture" should say "Turn on memory" to match the menu.']),
        ('Jonas Weber', '11:05 AM', ['Benchmarks from last night: recall p95 is 41 ms on the 100k-event store.',
                                     'Embedding backfill finished in 6m 12s; 0 events skipped, 3 retried.']),
        ('Maya Chen', '11:09 AM', ['Great. Shipping 0.3 to the beta group after lunch unless anyone objects.']),
        ('Ravi Patel', '11:12 AM', ['Let’s land Team at $18 a seat, billed annually. I still need an answer on seat minimums.']),
    ]
    channel_rows = ''.join(
        f'<div class="row" style="padding:4px 16px;gap:8px;'
        f'{"background:#1164a3;color:#fff" if ch == "launch-plan" else ""}">'
        f'<span style="opacity:.7">#</span>{n(ch)}</div>' for ch in channels)
    dm_rows = ''.join(
        f'<div class="row" style="padding:4px 16px;gap:8px"><i style="width:9px;height:9px;border-radius:50%;'
        f'background:#2bac76;display:block"></i>{n(d)}</div>' for d in dms)
    msg_rows = ''.join(
        f'<div class="row" style="align-items:flex-start;gap:10px"><div style="width:36px;height:36px;'
        f'border-radius:6px;background:#{len(who) * 2317 % 4096:03x};flex:none"></div>'
        f'<div class="col" style="gap:2px"><div class="row" style="gap:8px"><b>{c(who)}</b>'
        f'<span style="font-size:12px;color:#616061">{c(when)}</span></div>'
        + ''.join(f'<div>{c(line)}</div>' for line in lines) + '</div></div>'
        for who, when, lines in msgs)
    return _page(f'''
<div class="row" style="height:900px;align-items:stretch;background:#fff;color:#1d1c1d">
  <div class="col" style="width:64px;background:#3f0e40;align-items:center;gap:18px;padding-top:44px;color:#cfc3cf">{I['box']}{I['inbox']}{I['bell']}{I['star']}<div style="flex:1"></div>{I['plus']}{I['gear']}</div>
  <div class="col" style="width:250px;background:#4a154b;color:#cfc3cf;font-size:14px">
    <div class="row" style="height:48px;padding:0 16px;font-weight:700;color:#fff;gap:6px">{x('Northwind Studio')}{I['chevron']}<div style="flex:1"></div>{I['plus']}</div>
    <div class="row" style="padding:6px 16px;gap:8px">{I['inbox']}{x('Threads')}</div><div class="row" style="padding:6px 16px;gap:8px">{I['send']}{x('Drafts & sent')}</div>
    <div style="padding:14px 16px 4px;font-size:13px">{x('Channels')}</div>
    {channel_rows}
    <div style="padding:14px 16px 4px;font-size:13px">{x('Direct messages')}</div>
    {dm_rows}
  </div>
  <div class="col" style="flex:1;min-width:0">
    <div class="row" style="height:36px;background:#350d36;color:#cfc3cf;padding:0 12px;gap:10px">{I['back']}{I['fwd']}<div class="row" style="flex:1;height:24px;background:#5d3d5e;border-radius:6px;padding:0 10px;gap:8px;font-size:13px">{I['search']}{x('Search Northwind Studio')}</div>{I['bell']}</div>
    <div class="row" style="height:50px;padding:0 20px;gap:10px;border-bottom:1px solid #e3e3e3;font-weight:700;font-size:16px"><span># {x('launch-plan')}</span>{I['star']}<div style="flex:1"></div><span style="font-weight:400;font-size:13px;color:#616061">{x('14 members')}</span>{I['box']}{I['menu']}</div>
    <div class="col" style="flex:1;padding:16px 20px;gap:16px;font-size:15px">
      <div class="row" style="justify-content:center;font-size:13px;color:#616061">{x('Today')}</div>
      {msg_rows}
      <div class="row" style="gap:6px;margin-left:46px"><span style="border:1px solid #ddd;border-radius:12px;padding:1px 8px;font-size:12px">👍 {x('3')}</span><span style="border:1px solid #ddd;border-radius:12px;padding:1px 8px;font-size:12px">🎉 {x('1')}</span></div>
    </div>
    <div class="col" style="margin:0 20px 20px;border:1px solid #bbb;border-radius:8px">
      <div class="row" style="padding:8px 12px;gap:12px;color:#616061;border-bottom:1px solid #eee"><b>B</b><i>I</i><s>S</s>{I['clip']}{I['menu']}</div>
      <div class="row" style="padding:10px 12px;color:#8a8a8a;font-size:15px">{x('Message #launch-plan')}<div style="flex:1"></div>{I['smile']}{I['send']}</div>
    </div>
  </div>
</div>''')


def _mail():
    labels = ['Inbox', 'Starred', 'Snoozed', 'Sent', 'Drafts', 'Invoices', 'Travel']
    listing = [
        ('Dana Whitfield', 'Invoice 4471 for phase two', 'Hi Sam, phase two is wrapped up. The invoice is attached…', '11:02 AM'),
        ('Ravi Patel', 'Re: Team plan pricing', 'Seat minimums: I’d say three. Anything lower and support…', '10:20 AM'),
        ('Calendar', 'Reminder: beta review at 2 PM', 'You have a meeting with Maya Chen and Jonas Weber…', '9:00 AM'),
        ('Northwind Billing', 'Your receipt from Northwind', 'Thanks for your payment of $300.00 for the icon set…', 'Oct 9'),
        ('Jonas Weber', 'Benchmarks, round three', 'Recall p95 is down to 41 ms. Details in the doc…', 'Oct 9'),
    ]
    body = [
        'Hi Sam,',
        'Phase two of the brand refresh is wrapped up, and the final files are in the shared folder. The invoice '
        'for this phase is attached: 2,000.00 for the refresh and 300.00 for the icon set, 2,300.00 in total.',
        'Payment is due October 30 by bank transfer. If the purchase order number has changed since phase one, '
        'let me know and I will reissue it.',
        'It has been a pleasure working on this. I would love to hear how the launch goes.',
        'Best,', 'Dana',
    ]
    label_rows = ''.join(
        f'<div class="row" style="padding:6px 24px;gap:16px;'
        f'{"background:#d3e3fd;border-radius:0 16px 16px 0;font-weight:700" if i == 0 else ""}">'
        f'{I["inbox"] if i == 0 else I["star"] if i == 1 else I["folder"]}{n(label)}<div style="flex:1"></div>'
        f'{x("12") if i == 0 else ""}</div>' for i, label in enumerate(labels))
    list_rows = ''.join(
        f'<div class="col" style="padding:10px 16px;gap:2px;border-bottom:1px solid #f0f0f0;'
        f'{"background:#f2f6fc" if i == 0 else ""}"><div class="row" style="gap:8px"><b>{n(sender)}</b>'
        f'<div style="flex:1"></div><span style="font-size:12px;color:#5f6368">{n(when)}</span></div>'
        f'<div>{n(subject)}</div><div class="trunc" style="color:#5f6368;max-width:400px">{n(snippet)}</div></div>'
        for i, (sender, subject, snippet, when) in enumerate(listing))
    body_rows = ''.join(f'<div>{c(p)}</div>' for p in body)
    return _page(f'''
<div class="col" style="height:900px;background:#f6f8fc;color:#202124">
  <div class="row" style="height:64px;padding:0 16px;gap:16px">{I['menu']}<b style="font-size:20px;color:#5f6368">{x('Mail')}</b><div class="row" style="flex:1;max-width:720px;height:46px;background:#eaf1fb;border-radius:24px;padding:0 16px;gap:12px;color:#5f6368;font-size:16px">{I['search']}{x('Search mail')}<div style="flex:1"></div>{I['menu']}</div><div style="flex:1"></div>{I['gear']}{I['box']}<div style="width:32px;height:32px;border-radius:50%;background:#7b5ea7"></div></div>
  <div class="row" style="flex:1;min-height:0;align-items:stretch">
    <div class="col" style="width:240px;padding:8px 0;font-size:14px">
      <div class="row" style="margin:0 8px 14px;width:140px;height:56px;background:#c2e7ff;border-radius:16px;justify-content:center;gap:10px;font-weight:500">{I['plus']}{x('Compose')}</div>
      {label_rows}
    </div>
    <div class="col" style="width:440px;background:#fff;border-radius:16px 0 0 0;font-size:13.5px">
      <div class="row" style="height:48px;padding:0 16px;gap:18px;color:#5f6368;border-bottom:1px solid #eee">{I['box']}{I['reload']}{I['menu']}<div style="flex:1"></div><span style="font-size:12px">{x('1–50 of 1,284')}</span>{I['back']}{I['fwd']}</div>
      {list_rows}
    </div>
    <div class="col" style="flex:1;background:#fff;border-left:1px solid #eee;padding:0 28px;min-width:0">
      <div class="row" style="height:48px;gap:18px;color:#5f6368">{I['back']}{I['inbox']}{I['trash']}{I['folder']}<div style="flex:1"></div>{I['menu']}</div>
      <div style="font-size:22px;padding:8px 0 14px">{c('Invoice 4471 for phase two')}</div>
      <div class="row" style="gap:12px;padding-bottom:16px"><div style="width:40px;height:40px;border-radius:50%;background:#e8710a;flex:none"></div><div class="col"><div class="row" style="gap:8px"><b>{c('Dana Whitfield')}</b><span style="color:#5f6368;font-size:12px">{c('<dana@northwind.example>')}</span></div><span style="color:#5f6368;font-size:12px">{x('to me')}</span></div><div style="flex:1"></div><span style="color:#5f6368;font-size:12px">{c('11:02 AM')}</span>{I['star']}{I['menu']}</div>
      <div class="col" style="gap:12px;font-size:14px;line-height:1.55;max-width:620px">{body_rows}</div>
      <div class="row" style="margin-top:22px;gap:10px;border:1px solid #ddd;border-radius:8px;padding:10px 14px;width:260px">{I['files']}<div class="col"><b style="font-size:13px">{c('invoice-4471.pdf')}</b><span style="font-size:12px;color:#5f6368">{x('84 KB')}</span></div></div>
      <div class="row" style="margin-top:22px;gap:10px"><span style="border:1px solid #747775;border-radius:18px;padding:8px 20px">{x('Reply')}</span><span style="border:1px solid #747775;border-radius:18px;padding:8px 20px">{x('Forward')}</span></div>
    </div>
  </div>
</div>''')


def _article():
    tabs = ['Per-seat or tiered? How to price a team plan', 'Stripe Docs', 'Inbox (12) - sam@example.com',
            'hippocampus/README.md at main']
    marks = ['Docs', 'Pricing notes', 'Roadmap', 'Design system', 'Analytics']
    paras = [
        'Most teams choose between charging for every seat and charging by tier. Per-seat pricing is easy to '
        'explain and grows with the customer, but it punishes the customers who invite the most colleagues.',
        'Tiered pricing hides that penalty. A team of four and a team of nine pay the same, so nobody hesitates '
        'before adding a colleague. The cost is a harder first decision: which tier am I?',
        'A seat minimum is the usual compromise. Charge per seat, but start every team at three. Small teams get '
        'a predictable bill, and the price still follows growth after that.',
        'Whichever you choose, write the price down in one sentence. If the sentence needs the word “depending”, '
        'the plan is not finished.',
    ]
    tab_rows = ''.join(
        f'<div class="row" style="width:230px;height:32px;padding:0 10px;gap:8px;font-size:12px;'
        f'border-radius:8px 8px 0 0;{"background:#fff" if i == 0 else ""}"><div style="width:14px;height:14px;'
        f'border-radius:3px;background:#{["d93025", "635bff", "1a73e8", "24292f"][i]};flex:none"></div>'
        f'<span class="trunc" style="flex:1">{x(t)}</span>{I["close"]}</div>' for i, t in enumerate(tabs))
    mark_rows = ''.join(f'<span class="row" style="gap:6px">{I["folder"]}{x(m)}</span>' for m in marks)
    para_rows = ''.join(f'<div style="font:17px/1.6 Georgia,serif">{c(p)}</div>' for p in paras)
    related = ''.join(f'<div>{n(r)}</div>' for r in ['When to raise prices', 'The case against free tiers',
                                                    'Annual billing, explained', 'What a seat minimum signals'])
    return _page(f'''
<div class="col" style="height:900px;background:#fff;color:#1f1f1f">
  <div class="row" style="height:40px;background:#dee1e6;padding-left:0;align-items:flex-end"><div class="dots" style="align-self:center"><i></i><i></i><i></i></div>
    {tab_rows}{I['plus']}</div>
  <div class="row" style="height:40px;padding:0 10px;gap:12px;color:#5f6368">{I['back']}{I['fwd']}{I['reload']}<div class="row" style="flex:1;height:30px;background:#f1f3f4;border-radius:15px;padding:0 12px;gap:8px;font-size:13px;color:#202124">{I['lock']}{x('pricingnotes.example/team-plans/per-seat-or-tiered')}<div style="flex:1"></div>{I['star']}</div>{I['box']}{I['menu']}</div>
  <div class="row" style="height:30px;padding:0 12px;gap:18px;font-size:12px;border-bottom:1px solid #e0e0e0;color:#3c4043">{mark_rows}</div>
  <div class="col" style="flex:1;min-height:0;overflow:hidden">
    <div class="row" style="height:56px;padding:0 60px;gap:28px;border-bottom:1px solid #eee;font-size:14px"><b style="font-size:18px">{x('Pricing Notes')}</b>{n('Guides')}{n('Case studies')}{n('Calculator')}<div style="flex:1"></div>{x('Sign in')}<span style="background:#111;color:#fff;border-radius:6px;padding:6px 14px">{x('Subscribe')}</span></div>
    <div class="row" style="align-items:flex-start;padding:36px 60px;gap:60px">
      <div class="col" style="width:680px;gap:16px">
        <div style="font-size:13px;color:#b0462c;letter-spacing:.06em">{x('TEAM PLANS')}</div>
        <div style="font:700 34px/1.15 Georgia,serif">{c('Per-seat or tiered? How to price a team plan')}</div>
        <div style="font-size:13px;color:#666">{c('By Lena Ortiz · October 3, 2026 · 6 min read')}</div>
        {para_rows}
      </div>
      <div class="col" style="width:300px;gap:10px;font-size:14px;border-left:1px solid #eee;padding-left:28px">
        <div style="font-size:12px;letter-spacing:.06em;color:#666">{x('RELATED')}</div>
        {related}
        <div style="margin-top:16px;padding:16px;background:#f6f3ee;border-radius:8px"><b>{x('Get one pricing note a week')}</b><div class="row" style="margin-top:10px;border:1px solid #ccc;border-radius:6px;padding:8px;color:#999;background:#fff">{x('you@example.com')}</div></div>
      </div>
    </div>
  </div>
</div>''')


def _video():
    rail = [('How memory works in the brain', 'Neuro Explained', '1.2M views'),
            ('The hippocampus in ten minutes', 'MedSchool Now', '310K views'),
            ('Why we forget', 'Curious Minds', '2.4M views'),
            ('Sleep and memory consolidation', 'Lab Notes', '88K views'),
            ('Place cells, explained', 'Neuro Explained', '640K views')]
    comments = [('@studies_at_3am', 'The part about replay during sleep finally made this click for me.'),
                ('@lena.o', 'Is the 2014 Nobel work covered in the follow-up? Place cells deserve their own video.')]
    tab_rows = ''.join(
        f'<div class="row" style="width:240px;height:32px;padding:0 10px;gap:8px;font-size:12px;'
        f'border-radius:8px 8px 0 0;{"background:#35363a" if i == 0 else ""}"><div style="width:14px;height:14px;'
        f'border-radius:3px;background:#f00;flex:none"></div><span class="trunc" style="flex:1">{x(t)}</span>'
        f'{I["close"]}</div>' for i, t in enumerate(['General user models, explained - VidTube', 'Stripe Docs']))
    comment_rows = ''.join(
        f'<div class="row" style="align-items:flex-start;gap:12px"><div style="width:36px;height:36px;'
        f'border-radius:50%;background:#555;flex:none"></div><div class="col" style="gap:2px;font-size:14px">'
        f'<b style="font-size:13px">{c(who)}</b><div>{c(text)}</div></div></div>' for who, text in comments)
    rail_rows = ''.join(
        f'<div class="row" style="gap:10px;align-items:flex-start"><div style="width:168px;height:94px;'
        f'border-radius:8px;background:#{["243b55", "4a2545", "1f4a3a", "4a3a1f", "2b2b55"][i]};flex:none"></div>'
        f'<div class="col" style="gap:3px;font-size:13px"><b style="font-size:14px;line-height:1.3">{n(title)}</b>'
        f'<span style="color:#aaa">{n(channel)}</span><span style="color:#aaa">{n(views)}</span></div></div>'
        for i, (title, channel, views) in enumerate(rail))
    return _page(f'''
<div class="col" style="height:900px;background:#0f0f0f;color:#f1f1f1">
  <div class="row" style="height:40px;background:#202124;align-items:flex-end"><div class="dots" style="align-self:center"><i></i><i></i><i></i></div>
    {tab_rows}{I['plus']}</div>
  <div class="row" style="height:40px;background:#35363a;padding:0 10px;gap:12px;color:#bdc1c6">{I['back']}{I['fwd']}{I['reload']}<div class="row" style="flex:1;height:30px;background:#202124;border-radius:15px;padding:0 12px;gap:8px;font-size:13px">{I['lock']}{x('vidtube.example/watch?v=gum-explained')}</div>{I['menu']}</div>
  <div class="row" style="height:56px;padding:0 20px;gap:18px">{I['menu']}<b style="font-size:18px">{x('VidTube')}</b><div style="flex:1"></div><div class="row" style="width:520px;height:38px;border:1px solid #303030;border-radius:20px;padding:0 16px;color:#888">{x('Search')}<div style="flex:1"></div>{I['search']}</div><div style="flex:1"></div>{I['plus']}{I['bell']}<div style="width:30px;height:30px;border-radius:50%;background:#7b5ea7"></div></div>
  <div class="row" style="flex:1;min-height:0;align-items:flex-start;padding:8px 24px;gap:24px">
    <div class="col" style="width:940px;gap:10px">
      <div style="height:440px;border-radius:12px;background:linear-gradient(135deg,#1b2a4a,#3a1b4a);position:relative">
        <div style="position:absolute;left:60px;top:70px;font:600 30px/1.2 -apple-system">{c('A general user model learns from everything you do')}</div>
        <div style="position:absolute;left:0;right:0;bottom:54px;text-align:center"><span style="background:rgba(0,0,0,.75);padding:4px 10px;font-size:20px">{c('so the computer can stop asking you to explain yourself')}</span></div>
        <div class="row" style="position:absolute;left:12px;right:12px;bottom:8px;gap:14px;font-size:13px">{I['play']}{x('4:12 / 18:40')}<div style="flex:1;height:3px;background:#f00"></div>{I['gear']}{I['box']}</div>
      </div>
      <div style="font:600 20px/1.3 -apple-system">{c('General user models, explained')}</div>
      <div class="row" style="gap:12px"><div style="width:40px;height:40px;border-radius:50%;background:#2f6bff"></div><div class="col"><b>{c('Lab Notes')}</b><span style="font-size:12px;color:#aaa">{x('412K subscribers')}</span></div><span style="background:#f1f1f1;color:#0f0f0f;border-radius:18px;padding:8px 16px;font-weight:600">{x('Subscribe')}</span><div style="flex:1"></div><span class="row" style="gap:8px;background:#272727;border-radius:18px;padding:8px 14px">{I['thumb']}{x('18K')}</span><span class="row" style="gap:8px;background:#272727;border-radius:18px;padding:8px 14px">{I['send']}{x('Share')}</span></div>
      <div class="col" style="background:#272727;border-radius:12px;padding:12px;gap:6px;font-size:14px"><b>{c('231K views · 3 weeks ago')}</b><div>{c('How a system that watches the screen can build a model of what a person is doing, why it must stay on the device, and what it gets wrong.')}</div></div>
      <div style="font:600 16px -apple-system">{x('412 Comments')}</div>
      {comment_rows}
    </div>
    <div class="col" style="flex:1;gap:10px">{rail_rows}</div>
  </div>
</div>''')


def _notes():
    folders = ['All iCloud', 'Notes', 'Launch', 'Personal', 'Recently Deleted']
    counts = [42, 17, 6, 19, 3]
    listing = [('Launch plan', '2:31 PM', 'Team plan price before the beta?'),
               ('Pricing ideas', 'Yesterday', 'Per seat with a minimum of three'),
               ('Groceries', 'Monday', 'Oat milk, lemons, rice'),
               ('Reading list', 'Oct 2', 'The Design of Everyday Things')]
    note = [
        ('h', 'Launch plan'),
        ('p', 'The beta opens on October 21. Everything below has to be true by then, and nothing else is in scope.'),
        ('h2', 'Pricing'),
        ('li', 'Team plan at $18 a seat, billed annually (Ravi and Maya agreed on Tuesday).'),
        ('li', 'Open question: seat minimums. Ravi suggests three.'),
        ('li', 'Update the pricing page before the announcement goes out.'),
        ('h2', 'Onboarding'),
        ('p', 'Four screens, two permissions, and a moment of proof at the end. If a new person has not seen it '
              'work on their own screen within a minute, the flow has failed.'),
        ('h2', 'Open loops'),
        ('li', 'Reply to Dana about invoice 4471.'),
        ('li', 'Send Jonas the benchmark doc.'),
    ]
    folder_rows = ''.join(
        f'<div class="row" style="padding:5px 18px;gap:8px;'
        f'{"background:#fbd96b;border-radius:6px;margin:0 8px;padding:5px 10px" if i == 2 else ""}">'
        f'{I["folder"]}{n(folder)}<div style="flex:1"></div><span style="color:#888">{x(str(counts[i]))}</span></div>'
        for i, folder in enumerate(folders))
    list_rows = ''.join(
        f'<div class="col" style="padding:10px 18px;gap:2px;border-bottom:1px solid #eee;'
        f'{"background:#fde68a" if i == 0 else ""}"><b>{n(title)}</b><div class="row" style="gap:8px;color:#666">'
        f'<span>{n(when)}</span><span class="trunc">{n(snippet)}</span></div></div>'
        for i, (title, when, snippet) in enumerate(listing))

    def part(kind, text):
        if kind == 'h':
            return f'<div style="font:700 26px/1.2 -apple-system">{c(text)}</div>'
        if kind == 'h2':
            return f'<div style="font:700 19px/1.3 -apple-system;margin-top:10px">{c(text)}</div>'
        if kind == 'li':
            return f'<div class="row" style="gap:10px;align-items:flex-start"><span>•</span><div>{c(text)}</div></div>'
        return f'<div style="max-width:640px">{c(text)}</div>'

    note_rows = ''.join(part(kind, text) for kind, text in note)
    return _page(f'''
<div class="col" style="height:900px;background:#fff;color:#1d1d1f">
  <div class="row" style="height:52px;background:#f6f6f6;border-bottom:1px solid #ddd;padding-right:14px"><div class="dots"><i></i><i></i><i></i></div><div style="width:170px"></div>{I['menu']}<div style="width:18px"></div>{I['box']}<div style="flex:1"></div><div class="row" style="gap:20px;color:#666">{I['trash']}{I['plus']}<b style="font-size:15px">Aa</b>{I['menu']}{I['lock']}{I['send']}</div><div class="row" style="margin-left:20px;width:200px;height:28px;background:#e9e9eb;border-radius:8px;padding:0 8px;gap:6px;color:#888">{I['search']}{x('Search')}</div></div>
  <div class="row" style="flex:1;min-height:0;align-items:stretch">
    <div class="col" style="width:210px;background:#f0f0f2;padding:10px 0;font-size:13.5px">
      <div style="padding:4px 18px;font-size:11px;color:#888;font-weight:600">{x('iCloud')}</div>
      {folder_rows}
      <div style="flex:1"></div><div class="row" style="padding:8px 18px;gap:8px;color:#666">{I['plus']}{x('New Folder')}</div>
    </div>
    <div class="col" style="width:280px;border-right:1px solid #e3e3e3;font-size:13.5px">
      {list_rows}
    </div>
    <div class="col" style="flex:1;padding:18px 48px;gap:8px;font-size:15px;line-height:1.5;min-width:0">
      <div style="text-align:center;font-size:12px;color:#999">{x('October 12, 2026 at 2:31 PM')}</div>
      {note_rows}
    </div>
  </div>
</div>''')


def _messages():
    people = [('Maya Chen', '9:41 AM', 'I will send it tonight'),
              ('Ravi Patel', 'Yesterday', 'Sent the pricing doc'),
              ('Jonas Weber', 'Monday', 'Benchmarks look good'),
              ('Dana Whitfield', 'Oct 9', 'Invoice attached')]
    # (side, text): who said what is only in where the bubble sits.
    thread = [('in', 'Are we still on for 3?'),
              ('out', 'Yes, running five minutes late'),
              ('in', 'See you there'),
              ('in', 'Can you bring the printed badges?'),
              ('out', 'Already in my bag'),
              ('out', 'The venue wants a final headcount by Friday'),
              ('in', 'I will send it tonight')]
    people_rows = ''.join(
        f'<div class="row" style="padding:10px 14px;gap:10px;align-items:flex-start;'
        f'{"background:#dcdcde;border-radius:8px;margin:0 6px;padding:10px 8px" if i == 0 else ""}">'
        f'<div style="width:38px;height:38px;border-radius:50%;background:#{["8e8e93", "a2845e", "5e8ea2", "8e5ea2"][i]};'
        f'flex:none"></div><div class="col" style="flex:1;min-width:0;gap:2px"><div class="row"><b>{n(name)}</b>'
        f'<div style="flex:1"></div><span style="font-size:12px;color:#8e8e93">{n(when)}</span></div>'
        f'<span class="trunc" style="color:#6e6e73">{n(last)}</span></div></div>'
        for i, (name, when, last) in enumerate(people))

    def bubble(side, text):
        if side == 'in':
            return (f'<div class="row"><span style="background:#e9e9eb;border-radius:18px;padding:7px 13px;'
                    f'max-width:60%">{c(text)}</span></div>')
        return (f'<div class="row" style="justify-content:flex-end"><span style="background:#0a84ff;color:#fff;'
                f'border-radius:18px;padding:7px 13px;max-width:60%">{c(text)}</span></div>')

    bubbles = ''.join(bubble(side, text) for side, text in thread)
    return _page(f'''
<div class="row" style="height:760px;align-items:stretch;background:#fff;color:#1d1d1f;font-size:14px">
  <div class="col" style="width:300px;background:#f5f5f7;border-right:1px solid #dcdcde">
    <div class="row" style="height:52px;padding:0 14px"><div class="dots" style="padding:0"><i></i><i></i><i></i></div><div style="flex:1"></div>{I['box']}</div>
    <div class="row" style="margin:0 12px 10px;height:30px;background:#e3e3e6;border-radius:8px;padding:0 8px;gap:6px;color:#8e8e93">{I['search']}{x('Search')}</div>
    {people_rows}
  </div>
  <div class="col" style="flex:1;min-width:0">
    <div class="row" style="height:52px;padding:0 18px;gap:6px;border-bottom:1px solid #e5e5ea"><span style="color:#8e8e93">{x('To:')}</span>{x('Maya Chen')}<div style="flex:1"></div>{I['play']}{I['menu']}</div>
    <div class="col" style="flex:1;padding:14px 18px;gap:7px">
      <div class="row" style="justify-content:center;font-size:12px;color:#8e8e93;padding-bottom:6px">{x('Today 9:30 AM')}</div>
      {bubbles}
    </div>
    <div class="row" style="margin:0 14px 14px;height:34px;border:1px solid #d1d1d6;border-radius:17px;padding:0 14px;color:#8e8e93;gap:10px">{x('iMessage')}<div style="flex:1"></div>{I['smile']}</div>
  </div>
</div>''', size=(1100, 760))


def _issue_properties():
    """A ticket. Its properties panel is a narrow column of short rows on the
    right, the look of a sidebar, and every row in it is content."""
    teams = [('Engineering', ['Issues', 'Cycles', 'Projects']), ('Design', []), ('Marketing', [])]
    team_rows = ''.join(
        f'<div class="row" style="padding:5px 14px;gap:8px">{I["folder"]}{n(team)}</div>'
        + ''.join(f'<div class="row" style="padding:5px 14px 5px 40px;'
                  f'{"background:#e8e8ec;border-radius:6px;margin:0 6px;padding-left:34px" if item == "Issues" else ""}">'
                  f'{n(item)}</div>' for item in items)
        for team, items in teams)
    props = [('Status', ['In Progress']), ('Priority', ['High']), ('Assignee', ['Maya Chen']),
             ('Labels', ['Bug', 'Capture']), ('Project', ['Launch']), ('Cycle', ['Cycle 14']),
             ('Estimate', ['3']), ('Due date', ['Oct 21'])]
    prop_rows = ''.join(
        f'<div class="row" style="gap:12px;min-height:26px"><span style="width:84px;color:#6b6b73">{c(label)}</span>'
        + ''.join(f'<span style="{"border:1px solid #dedee3;border-radius:10px;padding:1px 8px" if label == "Labels" else ""}">'
                  f'{c(value)}</span>' for value in values) + '</div>'
        for label, values in props)
    steps = ['1. Close the lid for ten minutes.', '2. Open it and switch to any window with text.',
             '3. Compare the first two reads in the trace.']
    return _page(f'''
<div class="row" style="height:900px;align-items:stretch;background:#fff;color:#1b1b1f">
  <div class="col" style="width:232px;background:#f5f5f6;border-right:1px solid #e4e4e7;padding:12px 0;font-size:13px">
    <div class="row" style="padding:4px 14px 10px;gap:8px;font-weight:600"><div style="width:20px;height:20px;border-radius:5px;background:#5e6ad2"></div>{x('Northwind')}{I['chevron']}<div style="flex:1"></div>{I['search']}</div>
    <div class="row" style="padding:5px 14px;gap:8px">{I['inbox']}{n('Inbox')}</div>
    <div class="row" style="padding:5px 14px;gap:8px">{I['box']}{n('My issues')}</div>
    <div class="row" style="padding:5px 14px;gap:8px">{I['menu']}{n('Views')}</div>
    <div style="padding:16px 14px 4px;font-size:12px;color:#6b6b73">{x('Your teams')}</div>
    {team_rows}
  </div>
  <div class="col" style="flex:1;min-width:0">
    <div class="row" style="height:44px;padding:0 20px;gap:8px;border-bottom:1px solid #ececef;font-size:13px;color:#6b6b73">{x('Engineering')}{I['chevron']}{x('ENG-412')}<div style="flex:1"></div>{I['star']}{I['menu']}</div>
    <div class="row" style="flex:1;min-height:0;align-items:stretch">
      <div class="col" style="flex:1;padding:28px 48px 20px;gap:14px;min-width:0;font-size:15px;line-height:1.55">
        <div style="font:600 24px/1.25 -apple-system">{c('The OCR worker drops the first frame after wake')}</div>
        <div style="max-width:720px">{c('After the Mac wakes from sleep, the first window read comes back empty. The second read is fine, so the problem is the warm worker, not the screen.')}</div>
        <div style="font:600 16px -apple-system;margin-top:6px">{c('Steps to reproduce')}</div>
        {''.join(f'<div>{c(step)}</div>' for step in steps)}
        <div style="font:600 16px -apple-system;margin-top:6px">{c('Activity')}</div>
        <div class="row" style="gap:10px;align-items:flex-start"><div style="width:28px;height:28px;border-radius:50%;background:#a2845e;flex:none"></div><div class="col" style="gap:2px"><div class="row" style="gap:8px"><b>{c('Ravi Patel')}</b><span style="font-size:12px;color:#6b6b73">{c('2 hours ago')}</span></div><div>{c('Seen on two machines. Both were on battery.')}</div></div></div>
        <div style="flex:1"></div>
        <div class="row" style="border:1px solid #e4e4e7;border-radius:8px;padding:10px 12px;color:#8a8a93;gap:10px">{x('Leave a comment…')}<div style="flex:1"></div>{I['clip']}{I['send']}</div>
      </div>
      <div class="col" style="width:300px;border-left:1px solid #ececef;background:#fbfbfc;padding:24px 20px;gap:12px;font-size:13px">
        {prop_rows}
      </div>
    </div>
  </div>
</div>''')


def _order_summary():
    """A checkout page. The order summary on the right is short rows in a narrow
    column, and every row in it is content."""
    tab_rows = ''.join(
        f'<div class="row" style="width:230px;height:32px;padding:0 10px;gap:8px;font-size:12px;'
        f'border-radius:8px 8px 0 0;{"background:#fff" if i == 0 else ""}"><div style="width:14px;height:14px;'
        f'border-radius:3px;background:#2e7d5b;flex:none"></div><span class="trunc" style="flex:1">{x(t)}</span>'
        f'{I["close"]}</div>' for i, t in enumerate(['Checkout · Northwind Supply', 'Linen notebook · Northwind Supply']))
    items = [('Linen notebook', '$18.00'), ('Brass pen × 2', '$28.00')]
    totals = [('Subtotal', '$46.00'), ('Shipping', '$5.00'), ('Tax', '$4.14')]

    def line(label, amount, bold=False):
        weight = 'font-weight:700;font-size:16px' if bold else ''
        return f'<div class="row" style="{weight}">{c(label)}<div style="flex:1"></div>{c(amount)}</div>'

    def heading(text):
        return f'<div style="font:600 17px -apple-system;margin-top:10px">{c(text)}</div>'

    return _page(f'''
<div class="col" style="height:800px;background:#fff;color:#1f1f1f">
  <div class="row" style="height:40px;background:#dee1e6;align-items:flex-end"><div class="dots" style="align-self:center"><i></i><i></i><i></i></div>
    {tab_rows}{I['plus']}</div>
  <div class="row" style="height:40px;padding:0 10px;gap:12px;color:#5f6368">{I['back']}{I['fwd']}{I['reload']}<div class="row" style="flex:1;height:30px;background:#f1f3f4;border-radius:15px;padding:0 12px;gap:8px;font-size:13px;color:#202124">{I['lock']}{x('shop.northwind.example/checkout')}<div style="flex:1"></div>{I['star']}</div>{I['menu']}</div>
  <div class="row" style="height:60px;padding:0 48px;gap:28px;border-bottom:1px solid #eee;border-top:1px solid #e0e0e0;font-size:14px"><b style="font-size:19px">{x('Northwind Supply')}</b>{n('Notebooks')}{n('Pens')}{n('Paper')}<div style="flex:1"></div>{x('Cart (3)')}</div>
  <div class="row" style="flex:1;min-height:0;align-items:flex-start;padding:30px 48px;gap:56px;font-size:15px;line-height:1.5">
    <div class="col" style="flex:1;gap:6px">
      <div style="font:700 28px/1.2 -apple-system;margin-bottom:6px">{c('Checkout')}</div>
      {heading('Shipping address')}
      <div>{c('Sam Rivera')}</div><div>{c('41 Harbor Street')}</div><div>{c('Portland, OR 97209')}</div>
      {heading('Delivery')}
      <div>{c('Standard shipping, 3 to 5 business days')}</div>
      {heading('Payment')}
      <div>{c('Visa ending in 4242')}</div>
      <div style="margin-top:22px"><span style="background:#2e7d5b;color:#fff;border-radius:8px;padding:10px 22px;font-weight:600">{x('Place order')}</span></div>
    </div>
    <div class="col" style="width:330px;background:#f6f6f4;border-radius:10px;padding:20px 22px;gap:10px">
      <div style="font:600 17px -apple-system">{c('Order summary')}</div>
      {''.join(line(label, amount) for label, amount in items)}
      <div style="border-top:1px solid #ddd;margin:4px 0"></div>
      {''.join(line(label, amount) for label, amount in totals)}
      <div style="border-top:1px solid #ddd;margin:4px 0"></div>
      {line('Total', '$55.14', bold=True)}
    </div>
  </div>
  <div class="row" style="height:40px;padding:0 48px;gap:24px;border-top:1px solid #eee;font-size:12px;color:#6b6b6b">{x('Returns')}{x('Privacy')}{x('Terms')}</div>
</div>''', size=(1200, 800))


def _todo_beside_notes():
    """A notes page with a to-do list beside the notes. The to-do column is
    narrow, short-lined and on the left, the look of navigation, and it is
    content. The real navigation is the sidebar in its own pane."""
    pages = ['Weekly review', 'Launch plan', 'Reading list', 'Recipes', 'Travel']
    page_rows = ''.join(
        f'<div class="row" style="padding:4px 14px;gap:8px;{"background:#e9e9e6;border-radius:5px;margin:0 6px;padding-left:8px" if i == 0 else ""}">'
        f'{I["files"]}{n(p)}</div>' for i, p in enumerate(pages))
    todos = [('Book the venue', True), ('Email the caterer', True), ('Print the badges', False),
             ('Call Ravi about pricing', False), ('Order stamps', False)]
    todo_rows = ''.join(
        f'<div class="row" style="gap:8px"><span style="width:14px;height:14px;border:1.5px solid #9b9a97;border-radius:3px;'
        f'flex:none;{"background:#2f6bff;border-color:#2f6bff" if done else ""}"></span>{c(text)}</div>'
        for text, done in todos)
    notes = ['The venue holds 80 people, so the guest list stays under 70.',
             'Ravi wants the Team plan settled before the beta. Maya is fine with three seats as the minimum.',
             'Next week: a dry run of the demo on Tuesday, then badges on Thursday.']
    return _page(f'''
<div class="row" style="height:800px;align-items:stretch;background:#fff;color:#37352f;font-size:14px">
  <div class="col" style="width:220px;background:#f7f7f5;border-right:1px solid #e9e9e7;padding:10px 0">
    <div class="row" style="padding:6px 14px 12px;gap:8px;font-weight:600">{x('Workspace')}{I['chevron']}</div>
    {page_rows}
    <div style="flex:1"></div>
    <div class="row" style="padding:8px 14px;gap:8px;color:#787774">{I['plus']}{x('New page')}</div>
  </div>
  <div class="col" style="flex:1;min-width:0">
    <div class="row" style="height:44px;padding:0 16px;gap:6px;font-size:13px;color:#787774">{x('Workspace')}<span>/</span>{x('Weekly review')}<div style="flex:1"></div>{x('Share')}{I['star']}{I['menu']}</div>
    <div class="col" style="padding:40px 96px;gap:10px;line-height:1.5">
      <div style="font:700 32px/1.2 -apple-system">{c('Weekly review')}</div>
      <div style="color:#787774;margin-bottom:14px">{c('Week of October 12')}</div>
      <div class="row" style="align-items:flex-start;gap:56px">
        <div class="col" style="width:230px;gap:8px">
          <div style="font:600 18px -apple-system">{c('To do')}</div>
          {todo_rows}
        </div>
        <div class="col" style="flex:1;gap:10px;font-size:15px">
          <div style="font:600 18px -apple-system">{c('Notes')}</div>
          {''.join(f'<div>{c(p)}</div>' for p in notes)}
        </div>
      </div>
    </div>
  </div>
</div>''', size=(1280, 800))


def _fullscreen_doc():
    """A document read full screen: no title bar, no status bar. Its first row
    and its last row are lines of text, where a bar would be."""
    paragraphs = [
        'Six teams used the memory for four weeks. Each kept its usual tools and was asked one question a day '
        'about work from the week before.',
        'Answers grounded in a remembered window were right far more often than answers from search alone, and '
        'people stopped retyping context into their AI tools after the first week.',
    ]
    table = [('Week', 'Sessions', 'Questions'), ('1', '212', '48'), ('2', '240', '61'), ('3', '236', '57')]
    table_rows = ''.join(
        f'<div class="row" style="{"font-weight:600;border-bottom:1px solid #ddd" if i == 0 else ""};padding:4px 0">'
        + ''.join(f'<span style="width:150px">{c(cell)}</span>' for cell in cells) + '</div>'
        for i, cells in enumerate(table))
    return _page(f'''
<div style="height:900px;background:#fff;color:#222;position:relative;font:17px/1.6 Georgia,serif">
  <div style="position:absolute;left:340px;top:8px;width:760px">{c('which is why the pilot ran for four weeks instead of two.')}</div>
  <div class="col" style="position:absolute;left:340px;top:90px;width:760px;gap:18px">
    <div style="font:700 30px/1.2 Georgia,serif">{c('Results')}</div>
    {''.join(f'<div>{c(p)}</div>' for p in paragraphs)}
    <div class="col" style="font:15px/1.5 -apple-system;margin-top:6px">{table_rows}</div>
    <div>{c('Questions per session stayed flat, so the gain is not more asking.')}</div>
  </div>
  <div style="position:absolute;left:340px;top:862px;width:760px">{c('Retention fell to 61 percent in week three, then recovered.')}</div>
</div>''')


def _receipt():
    """A receipt opened in its own mail window. Each row sits between rules
    that span the message, so the window divides into one pane per row, the
    look of a stack of bars, and every row is content."""
    rows = [('Linen notebook', '$18.00'), ('Brass pen × 2', '$28.00'), ('Shipping', '$5.00'),
            ('Tax', '$4.14'), ('Total paid', '$55.14')]
    row_html = ''.join(
        f'<div class="row" style="padding:12px 0;border-top:1px solid #d2d2d7;'
        f'{"font-weight:700" if label == "Total paid" else ""}">{c(label)}<div style="flex:1"></div>{c(amount)}</div>'
        for label, amount in rows)
    return _page(f'''
<div class="col" style="height:760px;background:#fff;color:#1d1d1f;font-size:15px">
  <div class="row" style="height:52px;background:#f3f3f5;border-bottom:1px solid #d2d2d7;padding:0 14px;gap:18px;color:#6e6e73"><div class="dots" style="padding:0"><i></i><i></i><i></i></div><div style="flex:1;text-align:center;font-size:13px;font-weight:600;color:#1d1d1f">{x('Your receipt from Northwind')}</div>{I['trash']}{I['folder']}{I['back']}{I['send']}</div>
  <div class="col" style="padding:24px 28px 0;gap:6px">
    <div style="font:600 22px/1.3 -apple-system">{c('Your receipt from Northwind')}</div>
    <div class="row" style="color:#6e6e73;font-size:13px">{c('Northwind Supply <orders@northwind.example>')}<div style="flex:1"></div>{c('October 9, 2026 at 4:12 PM')}</div>
  </div>
  <div class="col" style="padding:22px 28px">
    <div style="padding-bottom:14px">{c('Thanks for your order, Sam. Here is what you paid for.')}</div>
    {row_html}
    <div style="border-top:1px solid #d2d2d7"></div>
    <div style="padding-top:16px">{c('Questions? Write to us at any time and we will help.')}</div>
  </div>
</div>''', size=(1100, 760))


def _invitation():
    """An invitation in a word processor. Its date sits alone on a centred
    line, the look of a divider between messages, and it is content; so is
    its last line, which starts the way a reply box does."""
    tools = ['View', 'Zoom', 'Insert', 'Table', 'Chart', 'Text', 'Shape', 'Media', 'Comment', 'Share', 'Format',
             'Document']
    tool_html = ''.join(f'<div class="col" style="align-items:center;gap:2px;font-size:11px;color:#555">'
                        f'{I["box"]}{x(t)}</div>' for t in tools)
    body = [('font:700 30px/1.25 Georgia,serif;margin-bottom:10px', 'You are invited to the launch party'),
            ('', 'Saturday, October 21 at 7 PM'), ('', '41 Harbor Street, Portland'),
            ('margin-top:28px', 'Bring a friend. Dinner and drinks are on us.'),
            ('', 'Reply to Maya by October 18.')]
    body_html = ''.join(f'<div style="{style}">{c(text)}</div>' for style, text in body)
    return _page(f'''
<div class="col" style="height:900px;background:#e5e5e8;color:#1d1d1f">
  <div class="col" style="background:#f6f6f6;border-bottom:1px solid #cfcfd4">
    <div class="row" style="height:28px"><div class="dots"><i></i><i></i><i></i></div><div style="flex:1;text-align:center;font-size:13px;font-weight:600">{x('Launch party')}</div><div style="width:84px"></div></div>
    <div class="row" style="height:52px;padding:0 18px;gap:24px">{tool_html}</div>
  </div>
  <div class="row" style="flex:1;min-height:0;justify-content:center;padding-top:30px">
    <div class="col" style="width:720px;background:#fff;padding:110px 80px;gap:10px;align-items:center;text-align:center;font:19px/1.5 Georgia,serif">{body_html}</div>
  </div>
</div>''')


# Every window: its page, the app that shows it, the title the window reports,
# its size in points, a plain label for the side-by-side page and, for an
# editor, the code lines in the order shown.
WINDOWS = {
    'editor': {'page': _editor(), 'app': 'com.microsoft.VSCode', 'label': 'Code editor',
               'title': 'retention_worker.rs — hippocampus', 'size': (1440, 900), 'code': EDITOR_CODE},
    'chat': {'page': _chat(), 'app': 'com.tinyspeck.slackmacgap', 'label': 'Team chat',
             'title': 'launch-plan (Channel) - Northwind Studio - Slack', 'size': (1440, 900)},
    'mail': {'page': _mail(), 'app': 'com.mimestream.Mimestream', 'label': 'Mail', 'title': 'Inbox',
             'size': (1440, 900)},
    'article': {'page': _article(), 'app': 'com.google.Chrome', 'label': 'Web article',
                'title': 'Per-seat or tiered? How to price a team plan', 'size': (1440, 900)},
    'video': {'page': _video(), 'app': 'com.google.Chrome', 'label': 'Video page',
              'title': 'General user models, explained - VidTube', 'size': (1440, 900)},
    'notes': {'page': _notes(), 'app': 'com.apple.Notes', 'label': 'Notes', 'title': 'Launch plan',
              'size': (1440, 900)},
    'messages': {'page': _messages(), 'app': 'com.apple.MobileSMS', 'label': 'Messages', 'title': 'Maya Chen',
                 'size': (1100, 760)},
    'issue_properties': {'page': _issue_properties(), 'app': 'com.linear', 'label': 'Ticket',
                         'title': 'ENG-412 The OCR worker drops the first frame after wake', 'size': (1440, 900),
                         'decoy': True},
    'order_summary': {'page': _order_summary(), 'app': 'com.google.Chrome', 'label': 'Checkout',
                      'title': 'Checkout · Northwind Supply', 'size': (1200, 800), 'decoy': True},
    'todo_beside_notes': {'page': _todo_beside_notes(), 'app': 'notion.id', 'label': 'To-do list beside notes',
                          'title': 'Weekly review', 'size': (1280, 800), 'decoy': True},
    'fullscreen_doc': {'page': _fullscreen_doc(), 'app': 'com.apple.iWork.Pages', 'label': 'Full-screen document',
                       'title': 'Pilot report', 'size': (1440, 900), 'decoy': True},
    'receipt': {'page': _receipt(), 'app': 'com.apple.mail', 'label': 'Receipt',
                'title': 'Your receipt from Northwind', 'size': (1100, 760), 'decoy': True},
    'invitation': {'page': _invitation(), 'app': 'com.apple.iWork.Pages', 'label': 'Invitation',
                   'title': 'Launch party', 'size': (1440, 900), 'decoy': True},
}


class _Tagged(HTMLParser):
    """Collects the text of every element that carries a role, in page order."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.items = []
        self.open = []  # one entry per open element: its role, or None

    def handle_starttag(self, tag, attrs):
        if tag in ('path', 'circle', 'rect', 'meta'):
            return
        role = dict(attrs).get('data-role')
        if role:
            self.items.append({'role': role, 'text': ''})
        self.open.append(role)

    def handle_endtag(self, tag):
        if tag in ('path', 'circle', 'rect', 'meta'):
            return
        self.open.pop()

    def handle_data(self, data):
        if self.open and self.open[-1]:
            self.items[-1]['text'] += data


def truth_items(page):
    """Every tagged string of `page` as {role, text}, in page order."""
    parser = _Tagged()
    parser.feed(page)
    items = [{'role': item['role'], 'text': ' '.join(item['text'].split())} for item in parser.items]
    return [item for item in items if item['text']]
