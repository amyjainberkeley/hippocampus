// V2-P8a CLI: manual-verification surface for the Mail.app read path.
//
// Sub-commands:
//   discover            — print discovered V<N> root + account UUIDs
//   schema              — print Envelope Index properties.version / minor
//   list [--since SECS] — list recent messages (date_received >= SECS)
//   read PATH           — parse a single emlx and pretty-print metadata
//   watch UUID          — watch an account's tree for new emlx files
//
// READ-ONLY. Nothing here writes to disk outside stdout/stderr. No event
// emission, no brain write. On EPERM (Full Disk Access not granted) the
// CLI prints a one-line hint and exits non-zero.

#![cfg(target_os = "macos")]

use std::env;
use std::path::PathBuf;
use std::process::ExitCode;

use mci_mail_reader::{
    discover::{discover_accounts, MailAccount},
    envelope::{list_recent_messages, schema_version},
    read_message,
    watch::watch_inbox,
    MailReaderError,
};

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    let cmd = args.get(1).map_or("", String::as_str);
    let rest = &args[args.len().min(2)..];

    let result = match cmd {
        "discover" => cmd_discover(),
        "schema" => cmd_schema(),
        "list" => cmd_list(rest),
        "read" => cmd_read(rest),
        "watch" => cmd_watch(rest),
        "" | "-h" | "--help" | "help" => {
            print_usage();
            return ExitCode::SUCCESS;
        }
        other => {
            eprintln!("mail-reader: unknown command {other:?}");
            print_usage();
            return ExitCode::from(2);
        }
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(MailReaderError::AccessDenied { path }) => {
            eprintln!(
                "mail-reader: Mail access denied at {} — grant Full Disk Access \
                 in System Settings → Privacy & Security → Full Disk Access.",
                path.display()
            );
            ExitCode::from(3)
        }
        Err(MailReaderError::DataRootMissing(path)) => {
            eprintln!(
                "mail-reader: Mail data root not found at {} — Mail.app may \
                 not have been launched for this user.",
                path.display()
            );
            ExitCode::from(4)
        }
        Err(e) => {
            eprintln!("mail-reader: {e}");
            ExitCode::from(1)
        }
    }
}

fn print_usage() {
    eprintln!(
        "usage: mail-reader <discover|schema|list|read|watch> [args]\n\
         \n\
         discover              print the discovered ~/Library/Mail/V<N>/ root + account UUIDs\n\
         schema                print Envelope Index properties.version / minor_version\n\
         list [--since SECS]   list messages with date_received >= SECS (default: 0)\n\
         read PATH             parse a single emlx file and print structured metadata\n\
         watch UUID            FSEvents-watch an account's tree; print new emlx paths\n\
         "
    );
}

fn cmd_discover() -> Result<(), MailReaderError> {
    let (root, accounts) = discover_accounts()?;
    println!("data_root       {}", root.path.display());
    println!("data_root_version V{}", root.version);
    println!("accounts        {}", accounts.len());
    for a in &accounts {
        println!("  {}", a.uuid);
    }
    Ok(())
}

fn cmd_schema() -> Result<(), MailReaderError> {
    let (root, _) = discover_accounts()?;
    let (version, minor) = schema_version(&root)?;
    println!(
        "envelope_index_version  {}",
        version.map_or("<missing>".into(), |v| v.to_string())
    );
    println!(
        "envelope_index_minor    {}",
        minor.map_or("<missing>".into(), |v| v.to_string())
    );
    Ok(())
}

fn cmd_list(rest: &[String]) -> Result<(), MailReaderError> {
    let mut since: i64 = 0;
    let mut it = rest.iter();
    while let Some(a) = it.next() {
        if a == "--since" {
            since = it
                .next()
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
        }
    }
    let (root, _) = discover_accounts()?;
    let rows = list_recent_messages(&root, since)?;
    println!("messages_count  {}", rows.len());
    for m in rows.iter().take(50) {
        println!(
            "  rowid={:<6} msgid={:<6} mailbox={:<3} flags={:<3} date_received={:<11} url={}",
            m.rowid,
            m.message_id,
            m.mailbox_rowid,
            m.flags,
            m.date_received,
            m.mailbox_url.as_deref().unwrap_or("")
        );
    }
    if rows.len() > 50 {
        println!("  ... ({} more)", rows.len() - 50);
    }
    Ok(())
}

fn cmd_read(rest: &[String]) -> Result<(), MailReaderError> {
    let Some(path) = rest.first() else {
        eprintln!("mail-reader read: missing PATH argument");
        return Err(MailReaderError::DataRootMissing(PathBuf::from("<arg>")));
    };
    let path = PathBuf::from(path);
    let m = read_message(&path)?;
    println!("path            {}", path.display());
    println!(
        "from            {}",
        m.from
            .iter()
            .map(|a| a.address.as_str())
            .collect::<Vec<_>>()
            .join(", ")
    );
    println!(
        "reply_to        {}",
        m.reply_to
            .iter()
            .map(|a| a.address.as_str())
            .collect::<Vec<_>>()
            .join(", ")
    );
    println!(
        "to              {}",
        m.to.iter()
            .map(|a| a.address.as_str())
            .collect::<Vec<_>>()
            .join(", ")
    );
    println!("subject         {}", m.subject.as_deref().unwrap_or(""));
    println!(
        "message_id      {}",
        m.message_id.as_deref().unwrap_or("")
    );
    println!("headers_count   {}", m.headers.len());
    println!(
        "body_text_bytes {}",
        m.body_text.as_deref().map_or(0, str::len)
    );
    println!(
        "body_html_bytes {}",
        m.body_html.as_deref().map_or(0, str::len)
    );
    println!("plist_trailer_bytes {}", m.plist_trailer.len());
    Ok(())
}

fn cmd_watch(rest: &[String]) -> Result<(), MailReaderError> {
    let Some(uuid) = rest.first() else {
        eprintln!("mail-reader watch: missing UUID argument");
        eprintln!("hint: run `mail-reader discover` to find account UUIDs");
        return Err(MailReaderError::DataRootMissing(PathBuf::from("<arg>")));
    };
    let (root, accounts) = discover_accounts()?;
    let Some(acct): Option<&MailAccount> = accounts.iter().find(|a| a.uuid == *uuid) else {
        eprintln!(
            "mail-reader watch: account UUID {uuid:?} not found under {}",
            root.path.display()
        );
        return Err(MailReaderError::DataRootMissing(root.path));
    };
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");
    rt.block_on(async move {
        let mut w = watch_inbox(acct, 64)?;
        println!("watching        {}", acct.root.display());
        while let Some(ev) = w.next().await {
            println!("new_message     {}", ev.path.display());
        }
        Ok::<(), MailReaderError>(())
    })
}
