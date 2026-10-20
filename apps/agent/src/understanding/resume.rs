//! `mci-agent resume-plan --item <id> --json`: what Resume would open again
//! for one Working On item, from what was open in its last session
//! (SPEC-DELTA 3): its web pages, documents, code folder and apps, each with
//! whether its checkbox starts ticked, and why not when it can't be opened.
//!
//! Resume sends nothing anywhere and this opens nothing: it only says what
//! the window's Resume sheet lists. The person ticks what to open and
//! clicks; only then does the window ask macOS to open each one.
//!
//! A seam for now: nothing is ever offered, so the sheet has nothing to
//! open. The plan from the item's last session lands with Resume.

use serde::Serialize;

use super::work::is_item_id;
use super::{ReadCommand, ReadError};

/// What Resume would open for one item, in the order the sheet lists it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct ResumePlan {
    /// What was open in the item's last session.
    pub items: Vec<ResumeTarget>,
}

/// One thing Resume could open again.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ResumeTarget {
    /// `"page"`, `"document"`, `"folder"` or `"app"`.
    pub kind: String,
    /// What the sheet calls it: the page's or document's title, the
    /// folder's name or the app's.
    pub title: String,
    /// The bundle id of the app that opens it.
    pub app: Option<String>,
    /// For a page or a linked document, its address without the query and
    /// fragment.
    pub url: Option<String>,
    /// For a local document or a folder, its path with `~` for home.
    pub path: Option<String>,
    /// Whether its checkbox starts ticked.
    pub checked: bool,
    /// Why it can't be opened again, when it can't (shown in place of a
    /// checkbox): "Couldn't find tax.rs".
    pub note: Option<String>,
}

/// `mci-agent resume-plan`: the plan as JSON. `--item <id>` is required.
///
/// # Errors
/// [`ReadError::Usage`] without an item's id; never anything read.
pub fn run_cli(command: &ReadCommand<'_>) -> Result<serde_json::Value, ReadError> {
    item_of(command.args)?;
    serde_json::to_value(ResumePlan::default())
        .map_err(|_| ReadError::Failed("resume-plan could not be written".into()))
}

/// The item `--item` names. The error never repeats what was given.
///
/// # Errors
/// [`ReadError::Usage`] when `--item` is missing or not an item's id.
pub fn item_of(args: &[String]) -> Result<String, ReadError> {
    let at = args
        .iter()
        .position(|arg| arg == "--item")
        .ok_or_else(|| ReadError::Usage("resume-plan requires --item ID".into()))?;
    args.get(at + 1)
        .filter(|id| is_item_id(id))
        .cloned()
        .ok_or_else(|| ReadError::Usage("--item requires an item's id".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|arg| (*arg).to_owned()).collect()
    }

    #[test]
    fn the_item_is_required_and_is_an_id() {
        assert_eq!(item_of(&args(&["--item", "w_9c41e2"])).unwrap(), "w_9c41e2");
        for list in [
            &[][..],
            &["--item"][..],
            &["--item", "--json"][..],
            &["--item", "trailhead shop"][..],
        ] {
            let error = item_of(&args(list)).unwrap_err();
            assert!(matches!(error, ReadError::Usage(_)), "{list:?}");
            assert!(error.to_string().contains("--item"), "{error}");
            assert!(!error.to_string().contains("trailhead"), "{error}");
        }
    }

    #[test]
    fn a_target_is_written_in_the_shape_the_window_reads() {
        let target = ResumeTarget {
            kind: "document".into(),
            title: "Launch checklist".into(),
            app: Some("com.apple.Notes".into()),
            url: None,
            path: None,
            checked: false,
            note: Some("Notes opens the app; Hippocampus can’t open a single note".into()),
        };
        let value = serde_json::to_value(ResumePlan {
            items: vec![target],
        })
        .unwrap();
        assert_eq!(value["items"][0]["kind"], "document");
        assert_eq!(value["items"][0]["checked"], false);
        assert_eq!(
            serde_json::to_value(ResumePlan::default()).unwrap(),
            serde_json::json!({"items": []})
        );
    }
}
