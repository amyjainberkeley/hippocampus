//! Background refresh through a per-user launchd agent.
//!
//! `connect --all` writes `~/Library/LaunchAgents/ai.hippocampus.refresh.plist`
//! and loads it with `launchctl bootstrap gui/<uid>`. Every five minutes
//! launchd runs `mci-agent refresh --budget-ms 20000 --db-path <db>`, which
//! imports new transcript lines and enriches them, so the packet a hook
//! delivers at session start is already current. `disconnect --all` unloads
//! and deletes the plist.
//!
//! The `launchctl` call is injected so tests never touch the real launchd
//! domain; the plist is rendered as a string so its content can be checked
//! exactly.

use std::path::{Path, PathBuf};

/// launchd label and plist basename.
pub const LABEL: &str = "ai.hippocampus.refresh";
/// Seconds between refresh runs.
pub const START_INTERVAL_SECONDS: u32 = 300;
/// Budget handed to `refresh`, in milliseconds.
pub const REFRESH_BUDGET_MS: u32 = 20_000;

/// Runs `launchctl` with the given arguments. Returns stderr-ish detail on failure.
pub type Launchctl<'a> = &'a dyn Fn(&[String]) -> Result<(), String>;

/// What install or removal did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentChange {
    /// The plist was written (new or changed) and the agent was loaded.
    Installed,
    /// The plist already matched; the agent was (re)loaded anyway so a
    /// previously unloaded agent comes back.
    AlreadyInstalled,
    /// The agent was unloaded and the plist deleted.
    Removed,
    /// No plist existed.
    NotInstalled,
}

/// Where the plist lives under `home`.
#[must_use]
pub fn plist_path(home: &Path) -> PathBuf {
    home.join("Library")
        .join("LaunchAgents")
        .join(format!("{LABEL}.plist"))
}

/// Where launchd sends the agent's stdout and stderr.
#[must_use]
pub fn log_path(home: &Path) -> PathBuf {
    home.join("Library")
        .join("Logs")
        .join("MCI")
        .join("refresh-agent.log")
}

fn xml_escape(raw: &str) -> String {
    raw.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// The plist text for `executable refresh --budget-ms 20000 --db-path db`.
#[must_use]
pub fn render_plist(executable: &Path, db_path: &Path, log: &Path) -> String {
    let exe = xml_escape(&executable.to_string_lossy());
    let db = xml_escape(&db_path.to_string_lossy());
    let log = xml_escape(&log.to_string_lossy());
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>{LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>{exe}</string>
		<string>refresh</string>
		<string>--budget-ms</string>
		<string>{REFRESH_BUDGET_MS}</string>
		<string>--db-path</string>
		<string>{db}</string>
	</array>
	<key>StartInterval</key>
	<integer>{START_INTERVAL_SECONDS}</integer>
	<key>RunAtLoad</key>
	<true/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityIO</key>
	<true/>
	<key>StandardOutPath</key>
	<string>{log}</string>
	<key>StandardErrorPath</key>
	<string>{log}</string>
</dict>
</plist>
"#
    )
}

/// Write the plist if it changed, then (re)load it.
///
/// Loading is `bootout` (ignored when the agent is not loaded) followed by
/// `bootstrap`, so a changed plist takes effect and a repeat call is safe.
///
/// # Errors
/// A message when the plist cannot be written or `bootstrap` fails. A failed
/// bootstrap leaves the plist in place so a later login can pick it up.
pub fn install(
    plist: &Path,
    contents: &str,
    uid: u32,
    launchctl: Launchctl<'_>,
) -> Result<AgentChange, String> {
    let unchanged = std::fs::read_to_string(plist).is_ok_and(|existing| existing == contents);
    if !unchanged {
        crate::client_hooks::write_atomic(plist, contents.as_bytes())
            .map_err(|error| error.to_string())?;
    }
    let target = plist.to_string_lossy().into_owned();
    let _ = launchctl(&["bootout".into(), format!("gui/{uid}"), target.clone()]);
    launchctl(&["bootstrap".into(), format!("gui/{uid}"), target])
        .map_err(|error| format!("launchctl bootstrap failed: {error}"))?;
    Ok(if unchanged {
        AgentChange::AlreadyInstalled
    } else {
        AgentChange::Installed
    })
}

/// Unload the agent and delete its plist.
///
/// # Errors
/// A message when the plist exists but cannot be deleted.
pub fn remove(plist: &Path, uid: u32, launchctl: Launchctl<'_>) -> Result<AgentChange, String> {
    let _ = launchctl(&["bootout".into(), format!("gui/{uid}/{LABEL}")]);
    match std::fs::remove_file(plist) {
        Ok(()) => Ok(AgentChange::Removed),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(AgentChange::NotInstalled),
        Err(error) => Err(format!("remove {}: {error}", plist.display())),
    }
}

/// The real thing: `/bin/launchctl` with reusable key variables scrubbed.
///
/// # Errors
/// The command's stderr (or exit status) when it fails.
#[cfg(target_os = "macos")]
pub fn system_launchctl(args: &[String]) -> Result<(), String> {
    let output = crate::child_command_environment::sanitized_command("/bin/launchctl")
        .args(args)
        .output()
        .map_err(|error| error.to_string())?;
    if output.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    let stderr = stderr.trim();
    if stderr.is_empty() {
        Err(format!("exit status {}", output.status))
    } else {
        Err(stderr.to_owned())
    }
}

/// launchd does not exist here; callers print a note and skip.
///
/// # Errors
/// Always.
#[cfg(not(target_os = "macos"))]
pub fn system_launchctl(_args: &[String]) -> Result<(), String> {
    Err("launchd is only available on macOS".into())
}

/// The current user's uid, for the `gui/<uid>` domain target.
#[must_use]
pub fn current_uid() -> u32 {
    rustix::process::getuid().as_raw()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    fn recorder(
        calls: &RefCell<Vec<Vec<String>>>,
    ) -> impl Fn(&[String]) -> Result<(), String> + '_ {
        move |args: &[String]| {
            calls.borrow_mut().push(args.to_vec());
            Ok(())
        }
    }

    #[test]
    fn plist_names_the_refresh_command_and_interval() {
        let text = render_plist(
            Path::new("/Applications/Hippocampus.app/Contents/MacOS/mci-agent"),
            Path::new("/Users/amy/Library/Application Support/MCI/mci.sqlite"),
            Path::new("/Users/amy/Library/Logs/MCI/refresh-agent.log"),
        );
        assert!(text.contains("<string>ai.hippocampus.refresh</string>"));
        assert!(text.contains(
            "\t\t<string>/Applications/Hippocampus.app/Contents/MacOS/mci-agent</string>\n\t\t<string>refresh</string>\n\t\t<string>--budget-ms</string>\n\t\t<string>20000</string>\n\t\t<string>--db-path</string>\n\t\t<string>/Users/amy/Library/Application Support/MCI/mci.sqlite</string>\n"
        ));
        assert!(text.contains("<key>StartInterval</key>\n\t<integer>300</integer>"));
        assert!(text.contains("<key>StandardErrorPath</key>\n\t<string>/Users/amy/Library/Logs/MCI/refresh-agent.log</string>"));
        assert!(text.starts_with("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"));
    }

    #[test]
    fn plist_escapes_xml_in_paths() {
        let text = render_plist(
            Path::new("/odd & <dir>/mci-agent"),
            Path::new("/db"),
            Path::new("/log"),
        );
        assert!(text.contains("<string>/odd &amp; &lt;dir&gt;/mci-agent</string>"));
    }

    #[test]
    fn install_writes_the_plist_and_calls_bootout_then_bootstrap() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path();
        let plist = plist_path(home);
        let calls = RefCell::new(Vec::new());
        let contents = render_plist(Path::new("/exe"), Path::new("/db"), &log_path(home));

        let change = install(&plist, &contents, 501, &recorder(&calls)).unwrap();

        assert_eq!(change, AgentChange::Installed);
        assert_eq!(std::fs::read_to_string(&plist).unwrap(), contents);
        let target = plist.to_string_lossy().into_owned();
        assert_eq!(
            *calls.borrow(),
            vec![
                vec!["bootout".to_owned(), "gui/501".to_owned(), target.clone()],
                vec!["bootstrap".to_owned(), "gui/501".to_owned(), target],
            ]
        );

        calls.borrow_mut().clear();
        let again = install(&plist, &contents, 501, &recorder(&calls)).unwrap();
        assert_eq!(again, AgentChange::AlreadyInstalled);
        assert_eq!(calls.borrow().len(), 2, "reloads even when unchanged");
    }

    #[test]
    fn a_failed_bootstrap_keeps_the_plist_and_reports() {
        let temp = tempfile::tempdir().unwrap();
        let plist = plist_path(temp.path());
        let failing = |args: &[String]| -> Result<(), String> {
            if args[0] == "bootstrap" {
                Err("Bootstrap failed: 5: Input/output error".into())
            } else {
                Ok(())
            }
        };
        let error = install(&plist, "<plist/>", 501, &failing).unwrap_err();
        assert!(error.contains("launchctl bootstrap failed"), "{error}");
        assert!(plist.exists());
    }

    #[test]
    fn remove_unloads_by_label_and_deletes_the_plist() {
        let temp = tempfile::tempdir().unwrap();
        let plist = plist_path(temp.path());
        let calls = RefCell::new(Vec::new());
        assert_eq!(
            remove(&plist, 501, &recorder(&calls)).unwrap(),
            AgentChange::NotInstalled
        );
        assert_eq!(
            *calls.borrow(),
            vec![vec![
                "bootout".to_owned(),
                "gui/501/ai.hippocampus.refresh".to_owned()
            ]]
        );

        install(&plist, "<plist/>", 501, &recorder(&calls)).unwrap();
        assert_eq!(
            remove(&plist, 501, &recorder(&calls)).unwrap(),
            AgentChange::Removed
        );
        assert!(!plist.exists());
    }
}
