//! V2-MCP-2 URL validation integration suite. Pinned acceptance
//! evidence for the ADR-0001 amendment loopback gate per the driver-
//! CSO audit table (row #1 + the dispatch's ACCEPT/REJECT enumeration).
//!
//! Distinct from the lib-internal tests in
//! `src/transport/loopback.rs` to keep the acceptance list in a place
//! a PR reviewer can grep for: `cargo test -p mci-mcp-client --test
//! url_validation`.

use mci_mcp_client::{LoopbackError, LoopbackHost};

// ─── ACCEPT cases (Audit row #1: registration-time gate) ───

#[tokio::test]
async fn accept_ipv4_loopback_default_port() {
    let h = LoopbackHost::parse("http://127.0.0.1/mcp").await.unwrap();
    assert_eq!(h.host, "127.0.0.1");
    assert_eq!(h.port, 80);
}

#[tokio::test]
async fn accept_ipv4_loopback_custom_port() {
    let h = LoopbackHost::parse("http://127.0.0.1:7890/mcp")
        .await
        .unwrap();
    assert_eq!(h.port, 7890);
}

#[tokio::test]
async fn accept_localhost_when_dns_resolves_loopback() {
    // `localhost` MUST resolve to a loopback address on every system
    // we support. A misconfigured /etc/hosts would correctly fail.
    let h = LoopbackHost::parse("http://localhost/mcp").await.unwrap();
    assert!(h.host.contains("localhost") || h.host == "localhost");
}

#[tokio::test]
async fn accept_ipv6_loopback() {
    let h = LoopbackHost::parse("http://[::1]/mcp").await.unwrap();
    assert_eq!(h.host, "::1");
}

#[tokio::test]
async fn accept_https_loopback_at_validation_time() {
    // HTTPS is admitted by the URL validator; the transport itself
    // refuses HTTPS at connect time with a clear "deferred to a
    // follow-up" error message per the ADR-0001 amendment §TLS posture.
    let h = LoopbackHost::parse("https://127.0.0.1/mcp").await.unwrap();
    assert_eq!(h.port, 443);
}

// ─── REJECT cases (Audit rows #3, #4) ───

#[tokio::test]
async fn reject_non_loopback_dns() {
    let err = LoopbackHost::parse("http://example.com/mcp")
        .await
        .expect_err("example.com must be rejected");
    assert!(matches!(
        err,
        LoopbackError::NonLoopbackDns
            | LoopbackError::DnsResolutionFailed
            | LoopbackError::DnsResolutionEmpty
    ));
}

#[tokio::test]
async fn reject_non_loopback_ipv6_literal() {
    let err = LoopbackHost::parse("http://[2001:db8::1]/mcp")
        .await
        .expect_err("2001:db8::1 must be rejected");
    assert_eq!(err, LoopbackError::NonLoopbackLiteral);
}

#[tokio::test]
async fn reject_non_loopback_ipv4_literal() {
    let err = LoopbackHost::parse("http://192.168.1.1/mcp")
        .await
        .expect_err("192.168.1.1 must be rejected");
    assert_eq!(err, LoopbackError::NonLoopbackLiteral);
}

#[tokio::test]
async fn reject_zero_address() {
    // 0.0.0.0 is the unspecified address — binds to all interfaces.
    // Audit row #4: must NOT pass for loopback.
    let err = LoopbackHost::parse("http://0.0.0.0/mcp")
        .await
        .expect_err("0.0.0.0 must be rejected");
    assert_eq!(err, LoopbackError::NonLoopbackLiteral);
}

#[tokio::test]
async fn reject_ftp_scheme() {
    let err = LoopbackHost::parse("ftp://127.0.0.1/mcp")
        .await
        .expect_err("ftp must be rejected");
    assert_eq!(err, LoopbackError::UnsupportedScheme);
}

#[tokio::test]
async fn reject_file_scheme() {
    let err = LoopbackHost::parse("file:///etc/passwd")
        .await
        .expect_err("file scheme must be rejected");
    // file:// has no authority — parse path treats it as missing host
    // (LoopbackError::MissingHost) before scheme is checked. Either
    // refusal is a stop.
    assert!(matches!(
        err,
        LoopbackError::UnsupportedScheme | LoopbackError::MissingHost | LoopbackError::Parse
    ));
}

#[tokio::test]
async fn reject_userinfo_in_url() {
    // Audit row #3: credential-in-URL is a refusal at the gate. The
    // auth_header field is the only auth path admitted.
    let err = LoopbackHost::parse("http://user:pass@127.0.0.1/mcp")
        .await
        .expect_err("userinfo must be rejected");
    assert_eq!(err, LoopbackError::UserinfoNotAllowed);
}

#[tokio::test]
async fn reject_dns_resolving_off_loopback() {
    // A hostname that points at a non-loopback address must NOT be
    // admitted, even at registration time — the helpful error
    // requirement of the dispatch.
    let err = LoopbackHost::parse("http://localhost.example.com/mcp")
        .await
        .expect_err("localhost.example.com is not loopback");
    assert!(matches!(
        err,
        LoopbackError::NonLoopbackDns
            | LoopbackError::DnsResolutionFailed
            | LoopbackError::DnsResolutionEmpty
    ));
}
