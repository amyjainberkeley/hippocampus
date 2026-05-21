//! MCI Workspace Server binary.
//!
//! Reads `PORT` env (default 3100), binds localhost, serves.
//! `MCI_SERVER_DB_PATH` selects `SQLite` store; absent = in-memory (backwards-compat).
//! Logs to stderr — NO content logs, counts only.

use std::sync::Arc;

use mci_server::crash_report::{crash_report_router, CrashReportLog, CrashReportLogConfig};
use mci_server::handlers::{router, AppState};
use mci_server::store::{InMemoryWorkspaceStore, SqliteWorkspaceStore, WorkspaceStore};

fn build_store() -> Box<dyn WorkspaceStore> {
    match std::env::var("MCI_SERVER_DB_PATH") {
        Ok(path) if !path.is_empty() => {
            tracing::info!(path = %path, "opening SQLite workspace store");
            let store = SqliteWorkspaceStore::open(std::path::Path::new(&path))
                .expect("failed to open SQLite store");
            Box::new(store)
        }
        _ => {
            tracing::info!("no MCI_SERVER_DB_PATH set — using in-memory store (non-durable)");
            Box::new(InMemoryWorkspaceStore::new())
        }
    }
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "mci_server=info".parse().expect("valid filter")),
        )
        .with_writer(std::io::stderr)
        .init();

    let port: u16 = std::env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(3100);

    let store = build_store();
    let state = Arc::new(AppState::new(store));
    let workspace_app = router(state);

    let crash_log = Arc::new(CrashReportLog::new(CrashReportLogConfig::from_env()));
    let crash_app = crash_report_router(crash_log);

    let app = workspace_app.merge(crash_app);

    let listener = tokio::net::TcpListener::bind(format!("127.0.0.1:{port}"))
        .await
        .expect("bind failed");

    tracing::info!("mci-server listening on 127.0.0.1:{port}");
    axum::serve(listener, app).await.expect("server error");
}
