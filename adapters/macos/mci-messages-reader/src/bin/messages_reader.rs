// V2-P7 CLI: manual-verification surface for the Messages.app read path.
//
// Sub-commands:
//   discover                    print discovered chat.db location
//   list [--since SECS]         list recent messages (date_unix >= SECS)
//   thread CHAT_ROWID           print participants + ordered messages
//   watch                       watch chat.db touches; print event paths
//
// READ-ONLY. Nothing here writes to disk outside stdout/stderr. No event
// emission, no brain write. On EPERM (Full Disk Access not granted) the
// CLI prints a one-line hint and exits non-zero — the V2-P10 onboarding
// surface will wire this to a proper UI gate per ADR-0032 §3(d).

#![cfg(target_os = "macos")]

use std::env;
use std::process::ExitCode;

use mci_messages_reader::{
    discover_chat_db, list_recent_messages, read_thread, watch_inbox, MessagesReaderError,
};

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    let cmd = args.get(1).map_or("", String::as_str);
    let rest = &args[args.len().min(2)..];

    let result = match cmd {
        "discover" => cmd_discover(),
        "list" => cmd_list(rest),
        "thread" => cmd_thread(rest),
        "watch" => cmd_watch(),
        "" | "-h" | "--help" | "help" => {
            print_usage();
            return ExitCode::SUCCESS;
        }
        other => {
            eprintln!("messages-reader: unknown command {other:?}");
            print_usage();
            return ExitCode::from(2);
        }
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(MessagesReaderError::AccessDenied { path }) => {
            // V2-P10 onboarding stub (ADR-0032 §3(d)): the user-facing
            // permission gate replaces this one-liner with a guided UX.
            eprintln!(
                "messages-reader: Messages access denied at {} — grant Full Disk Access \
                 in System Settings → Privacy & Security → Full Disk Access.",
                path.display()
            );
            ExitCode::from(3)
        }
        Err(MessagesReaderError::ChatDbMissing(path)) => {
            eprintln!(
                "messages-reader: chat.db not found at {} — Messages.app may \
                 not have been launched for this user.",
                path.display()
            );
            ExitCode::from(4)
        }
        Err(e) => {
            eprintln!("messages-reader: {e}");
            ExitCode::from(1)
        }
    }
}

fn print_usage() {
    eprintln!(
        "usage: messages-reader <discover|list|thread|watch> [args]\n\
         \n\
         discover              print the discovered ~/Library/Messages/chat.db location\n\
         list [--since SECS]   list messages with date_unix >= SECS (default: 0)\n\
         thread CHAT_ROWID     print participants + ordered messages for chat.ROWID\n\
         watch                 FSEvents-watch the Messages tree; print touched paths\n\
         "
    );
}

fn cmd_discover() -> Result<(), MessagesReaderError> {
    let loc = discover_chat_db()?;
    println!("chat_db       {}", loc.path.display());
    println!("root          {}", loc.root.display());
    Ok(())
}

fn cmd_list(rest: &[String]) -> Result<(), MessagesReaderError> {
    let mut since: i64 = 0;
    let mut it = rest.iter();
    while let Some(a) = it.next() {
        if a == "--since" {
            since = it.next().and_then(|s| s.parse().ok()).unwrap_or(0);
        }
    }
    let loc = discover_chat_db()?;
    let rows = list_recent_messages(&loc, since)?;
    println!("messages_count  {}", rows.len());
    for m in rows.iter().take(50) {
        let body_preview = m.body.as_deref().map_or_else(
            || "<attachment-only>".to_string(),
            |b| b.chars().take(40).collect::<String>(),
        );
        println!(
            "  rowid={:<6} from_me={} svc={:<8} date_unix={:<11} sender={:<25} body={}",
            m.rowid,
            u8::from(m.is_from_me),
            m.service.as_str(),
            m.date_unix,
            m.sender_handle.as_deref().unwrap_or(""),
            body_preview,
        );
    }
    if rows.len() > 50 {
        println!("  ... ({} more)", rows.len() - 50);
    }
    Ok(())
}

fn cmd_thread(rest: &[String]) -> Result<(), MessagesReaderError> {
    let Some(arg) = rest.first() else {
        eprintln!("messages-reader thread: missing CHAT_ROWID argument");
        return Ok(());
    };
    let Ok(rowid) = arg.parse::<i64>() else {
        eprintln!("messages-reader thread: CHAT_ROWID must be an integer");
        return Ok(());
    };
    let loc = discover_chat_db()?;
    let Some(t) = read_thread(&loc, rowid)? else {
        eprintln!("messages-reader thread: no chat with ROWID {rowid}");
        return Ok(());
    };
    println!("chat_rowid    {}", t.chat_rowid);
    println!("guid          {}", t.guid);
    println!("style         {}", t.style);
    println!(
        "display_name  {}",
        t.display_name.as_deref().unwrap_or("")
    );
    println!("participants  {}", t.participants.len());
    for p in &t.participants {
        println!("  rowid={:<3} svc={:<8} id={}", p.rowid, p.service.as_str(), p.id);
    }
    println!("messages      {}", t.messages.len());
    for m in t.messages.iter().take(50) {
        let body_preview = m.body.as_deref().map_or_else(
            || "<attachment-only>".to_string(),
            |b| b.chars().take(40).collect::<String>(),
        );
        println!(
            "  rowid={:<6} from_me={} date_unix={:<11} body={}",
            m.rowid,
            u8::from(m.is_from_me),
            m.date_unix,
            body_preview,
        );
    }
    Ok(())
}

fn cmd_watch() -> Result<(), MessagesReaderError> {
    let loc = discover_chat_db()?;
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");
    rt.block_on(async move {
        let mut w = watch_inbox(&loc, 64)?;
        println!("watching        {}", loc.root.display());
        while let Some(ev) = w.next().await {
            println!("chat_db_touch   {}", ev.path.display());
        }
        Ok::<(), MessagesReaderError>(())
    })
}
