//! MCI Workspace Server binary.
//!
//! Reads `PORT` env (default 3100), binds localhost, serves.
//! Logs to stderr — NO content logs, counts only.

use std::sync::Arc;

use mci_server::handlers::{router, AppState};
use mci_server::store::InMemoryWorkspaceStore;

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

    let store = InMemoryWorkspaceStore::new();
    let state = Arc::new(AppState::new(store));
    let app = router(state);

    let listener = tokio::net::TcpListener::bind(format!("127.0.0.1:{port}"))
        .await
        .expect("bind failed");

    tracing::info!("mci-server listening on 127.0.0.1:{port}");
    axum::serve(listener, app).await.expect("server error");
}
