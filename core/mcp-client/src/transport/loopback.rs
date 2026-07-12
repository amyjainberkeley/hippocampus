//! [`LoopbackHost`] — parses + validates a URL against the ADR-0001
//! 2026-05-31 amendment's loopback-only contract.
//!
//! The amendment admits HTTP+SSE traffic to ONE narrow set of hosts:
//!
//! - IPv4: any address in `127.0.0.0/8`.
//! - IPv6: `::1`.
//! - DNS hostname: accepted only when every resolved A/AAAA address is
//!   in the loopback set above.
//!
//! Defense-in-depth: every URL flows through [`LoopbackHost::parse`] at
//! registration time AND through [`LoopbackHost::resolve_now`] at
//! per-call connect time. A bug in either gate alone cannot leak a
//! non-loopback connect.
//!
//! Rejected URLs never reach the transport's connect path. Errors are
//! typed via [`LoopbackError`] so the registration UI can render an
//! actionable message without leaking the bytes the user typed.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::str::FromStr;

use http::Uri;
use thiserror::Error;

/// Outcome of [`LoopbackHost::parse`]: the URL passes the registration-
/// time loopback gate.
///
/// Field access is `pub` so the transport can re-validate at connect
/// time without re-parsing the original string.
#[derive(Debug, Clone)]
pub struct LoopbackHost {
    /// Normalized URL string (kept verbatim modulo scheme lowercasing).
    /// Re-parsable as a [`http::Uri`] without further validation.
    pub url: String,
    /// Scheme — always `http` or `https`, lowercased.
    pub scheme: Scheme,
    /// Host portion of the authority (without `[]` brackets for IPv6).
    pub host: String,
    /// Port, with the scheme's default applied when absent.
    pub port: u16,
    /// The kind of host the validator accepted.
    pub kind: HostKind,
}

/// Allowed schemes. https is accepted by the URL validator; the
/// transport implementation may degrade gracefully if it has no TLS
/// stack at compile time (see [`super::http_sse`] for the connect-time
/// posture).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scheme {
    /// HTTP/1.1 plaintext. Acceptable for loopback because no packet
    /// leaves the device's loopback interface.
    Http,
    /// HTTPS. Acceptable at URL-validation time; TLS support in the
    /// transport is gated separately.
    Https,
}

impl Scheme {
    /// Default port per scheme.
    #[must_use]
    pub const fn default_port(self) -> u16 {
        match self {
            Scheme::Http => 80,
            Scheme::Https => 443,
        }
    }

    /// Stable string form.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Scheme::Http => "http",
            Scheme::Https => "https",
        }
    }
}

/// Which loopback shape the URL named.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostKind {
    /// An IPv4 literal in `127.0.0.0/8` (e.g., `127.0.0.1`).
    Ipv4Literal(Ipv4Addr),
    /// The IPv6 loopback literal `::1`.
    Ipv6Literal(Ipv6Addr),
    /// A DNS hostname (e.g., `localhost`). Resolution happens at the
    /// registration-time gate via [`LoopbackHost::parse`] and again at
    /// connect time via [`LoopbackHost::resolve_now`].
    Dns(String),
}

/// Every way [`LoopbackHost::parse`] can refuse a URL.
///
/// Error variants are content-free — they describe the *shape* of the
/// rejection without echoing the offending bytes (no
/// `format!("got {url}")` anywhere). The §5.4 content-free-telemetry
/// discipline applies; the onboarding UI renders these into
/// human-readable strings at the call site if needed.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum LoopbackError {
    /// The URL did not parse as a syntactically valid URI.
    #[error("URL did not parse")]
    Parse,
    /// The URL is missing a scheme (e.g., `127.0.0.1/mcp` with no
    /// `http://` prefix). The validator does not silently inject one.
    #[error("URL is missing a scheme; only http and https are accepted")]
    MissingScheme,
    /// The URL's scheme is not `http` or `https` (e.g. `ftp://`,
    /// `file://`, `data:`).
    #[error("URL scheme is not http or https")]
    UnsupportedScheme,
    /// The URL embeds `user:password@host` in its authority. Rejected
    /// to prevent credential-in-URL leakage and to keep the auth-
    /// header surface as the single auth path. CSO sign-off item.
    #[error("URL must not embed userinfo (user:password@)")]
    UserinfoNotAllowed,
    /// The URL had no authority / no host (e.g., `http:///mcp`).
    #[error("URL is missing a host")]
    MissingHost,
    /// The host is a non-loopback IP literal (e.g., `192.168.1.1`,
    /// `0.0.0.0`, `8.8.8.8`, `[2001:db8::1]`).
    #[error("URL host is a non-loopback IP literal")]
    NonLoopbackLiteral,
    /// The host is a DNS name whose A/AAAA resolution does not stay
    /// inside the loopback set.
    #[error("URL host resolves to a non-loopback address")]
    NonLoopbackDns,
    /// The DNS name resolved to zero addresses. Treated as a hard
    /// refusal: the validator never admits a URL it cannot verify.
    #[error("URL host did not resolve to any address")]
    DnsResolutionEmpty,
    /// The DNS resolver returned an error. Treated as a hard refusal
    /// for the same reason.
    #[error("URL host resolution failed")]
    DnsResolutionFailed,
}

impl LoopbackHost {
    /// Parse a user-provided URL and validate it against the loopback
    /// contract.
    ///
    /// IP literals are validated synchronously by the literal's bits.
    /// DNS hostnames are validated by resolving via
    /// [`tokio::net::lookup_host`] and requiring every returned address
    /// to be loopback. Empty resolutions are refused.
    ///
    /// # Errors
    /// See [`LoopbackError`].
    pub async fn parse(raw: &str) -> Result<Self, LoopbackError> {
        let parsed = parse_uri(raw)?;
        match parsed.kind.clone() {
            HostKind::Dns(name) => {
                // DNS hostnames must resolve entirely inside the
                // loopback set. `lookup_host` returns `SocketAddr`s so
                // we attach the parsed port and re-check the IP half
                // of each resolution.
                let target = format!("{name}:{}", parsed.port);
                let resolved = tokio::net::lookup_host(target.as_str())
                    .await
                    .map_err(|_| LoopbackError::DnsResolutionFailed)?;
                let addrs: Vec<_> = resolved.collect();
                if addrs.is_empty() {
                    return Err(LoopbackError::DnsResolutionEmpty);
                }
                for addr in &addrs {
                    if !is_loopback(&addr.ip()) {
                        return Err(LoopbackError::NonLoopbackDns);
                    }
                }
                Ok(parsed)
            }
            HostKind::Ipv4Literal(_) | HostKind::Ipv6Literal(_) => Ok(parsed),
        }
    }

    /// Re-validate this host at per-call connect time and return the
    /// concrete socket address to dial.
    ///
    /// IP literals always re-pass (the bits cannot change). DNS
    /// hostnames are re-resolved and re-checked — defense-in-depth
    /// against time-of-check / time-of-use (a hostname could have
    /// resolved to `127.0.0.1` at registration and now resolve to a
    /// public address; this gate refuses the call).
    ///
    /// # Errors
    /// Re-validation errors mirror those from [`Self::parse`].
    pub async fn resolve_now(&self) -> Result<std::net::SocketAddr, LoopbackError> {
        match &self.kind {
            HostKind::Ipv4Literal(addr) => {
                Ok(std::net::SocketAddr::new(IpAddr::V4(*addr), self.port))
            }
            HostKind::Ipv6Literal(addr) => {
                Ok(std::net::SocketAddr::new(IpAddr::V6(*addr), self.port))
            }
            HostKind::Dns(name) => {
                let target = format!("{name}:{}", self.port);
                let resolved = tokio::net::lookup_host(target.as_str())
                    .await
                    .map_err(|_| LoopbackError::DnsResolutionFailed)?;
                let addrs: Vec<_> = resolved.collect();
                if addrs.is_empty() {
                    return Err(LoopbackError::DnsResolutionEmpty);
                }
                let mut chosen: Option<std::net::SocketAddr> = None;
                for addr in &addrs {
                    if !is_loopback(&addr.ip()) {
                        return Err(LoopbackError::NonLoopbackDns);
                    }
                    if chosen.is_none() {
                        chosen = Some(*addr);
                    }
                }
                // `chosen` is Some because addrs is non-empty and the
                // first iteration set it (no iteration returned early
                // because every address was loopback).
                Ok(chosen.expect("non-empty + all-loopback ⇒ chosen set"))
            }
        }
    }
}

/// Parse + structurally validate the URL (scheme, authority, host) but
/// do NOT perform DNS resolution. Shared by both gates.
fn parse_uri(raw: &str) -> Result<LoopbackHost, LoopbackError> {
    let uri: Uri = raw.parse().map_err(|_| LoopbackError::Parse)?;

    let scheme_str = uri.scheme_str().ok_or(LoopbackError::MissingScheme)?;
    let scheme = match scheme_str.to_ascii_lowercase().as_str() {
        "http" => Scheme::Http,
        "https" => Scheme::Https,
        _ => return Err(LoopbackError::UnsupportedScheme),
    };

    let authority = uri.authority().ok_or(LoopbackError::MissingHost)?;
    let authority_str = authority.as_str();

    // `http::Authority` accepts `user:pass@host` and stores it. The
    // contract is "no userinfo" — flag any '@' before the host.
    if authority_str.contains('@') {
        return Err(LoopbackError::UserinfoNotAllowed);
    }

    let host_raw_full = authority.host();
    if host_raw_full.is_empty() {
        return Err(LoopbackError::MissingHost);
    }
    let port = authority.port_u16().unwrap_or(scheme.default_port());

    // `http::Authority::host()` returns IPv6 literals WITH the
    // surrounding `[]`. Strip them so the `Ipv6Addr::from_str` parse
    // succeeds — `[::1]` does not parse as an IpAddr; `::1` does.
    let host_raw = if host_raw_full.starts_with('[') && host_raw_full.ends_with(']') {
        &host_raw_full[1..host_raw_full.len() - 1]
    } else {
        host_raw_full
    };

    // Try IPv6 first (more specific shape), then IPv4, then fall
    // through to DNS.
    if let Ok(addr) = Ipv6Addr::from_str(host_raw) {
        return if is_ipv6_loopback(&addr) {
            Ok(LoopbackHost {
                url: rebuild_url(
                    scheme,
                    host_raw,
                    port,
                    uri.path_and_query().map(|p| p.as_str()),
                )?,
                scheme,
                host: host_raw.to_owned(),
                port,
                kind: HostKind::Ipv6Literal(addr),
            })
        } else {
            Err(LoopbackError::NonLoopbackLiteral)
        };
    }
    if let Ok(addr) = Ipv4Addr::from_str(host_raw) {
        return if is_ipv4_loopback(&addr) {
            Ok(LoopbackHost {
                url: rebuild_url(
                    scheme,
                    host_raw,
                    port,
                    uri.path_and_query().map(|p| p.as_str()),
                )?,
                scheme,
                host: host_raw.to_owned(),
                port,
                kind: HostKind::Ipv4Literal(addr),
            })
        } else {
            Err(LoopbackError::NonLoopbackLiteral)
        };
    }

    // DNS hostname. Reject obvious bogus shapes early; resolution is
    // performed by the async caller (parse / resolve_now).
    if host_raw.parse::<IpAddr>().is_ok() {
        // Defensive: if `http::Authority` somehow accepts an IP-shaped
        // string the two specific parses missed, refuse it rather than
        // letting it fall through to DNS.
        return Err(LoopbackError::NonLoopbackLiteral);
    }

    Ok(LoopbackHost {
        url: rebuild_url(
            scheme,
            host_raw,
            port,
            uri.path_and_query().map(|p| p.as_str()),
        )?,
        scheme,
        host: host_raw.to_owned(),
        port,
        kind: HostKind::Dns(host_raw.to_owned()),
    })
}

fn rebuild_url(
    scheme: Scheme,
    host: &str,
    port: u16,
    path_and_query: Option<&str>,
) -> Result<String, LoopbackError> {
    let host_display = if host.contains(':') {
        format!("[{host}]")
    } else {
        host.to_owned()
    };
    let path = path_and_query.unwrap_or("/");
    let port_part = if port == scheme.default_port() {
        String::new()
    } else {
        format!(":{port}")
    };
    Ok(format!(
        "{}://{}{}{}",
        scheme.as_str(),
        host_display,
        port_part,
        path
    ))
}

fn is_loopback(addr: &IpAddr) -> bool {
    match addr {
        IpAddr::V4(v4) => is_ipv4_loopback(v4),
        IpAddr::V6(v6) => is_ipv6_loopback(v6),
    }
}

fn is_ipv4_loopback(addr: &Ipv4Addr) -> bool {
    // Standard library Ipv4Addr::is_loopback matches the 127.0.0.0/8
    // range. Restate the contract here to avoid surprise from any
    // future stdlib semantics shift.
    addr.octets()[0] == 127
}

fn is_ipv6_loopback(addr: &Ipv6Addr) -> bool {
    // ADR-0001 amendment: ONLY `::1`. The IPv6 loopback prefix is
    // exactly one address, not a range.
    *addr == Ipv6Addr::LOCALHOST
}

#[cfg(test)]
mod tests {
    use super::*;

    // ─── ACCEPT cases ───

    #[tokio::test]
    async fn ipv4_loopback_127_0_0_1_accepted() {
        let h = LoopbackHost::parse("http://127.0.0.1/mcp").await.unwrap();
        assert_eq!(h.scheme, Scheme::Http);
        assert_eq!(h.host, "127.0.0.1");
        assert_eq!(h.port, 80);
        assert!(matches!(h.kind, HostKind::Ipv4Literal(_)));
    }

    #[tokio::test]
    async fn ipv4_loopback_127_0_0_1_with_port_accepted() {
        let h = LoopbackHost::parse("http://127.0.0.1:7890/mcp")
            .await
            .unwrap();
        assert_eq!(h.port, 7890);
    }

    #[tokio::test]
    async fn ipv4_loopback_127_anything_in_range_accepted() {
        // 127.0.0.0/8 covers e.g. 127.0.0.1, 127.1.2.3 — all of them
        // are loopback.
        let h = LoopbackHost::parse("http://127.1.2.3:8080/x")
            .await
            .unwrap();
        assert!(matches!(h.kind, HostKind::Ipv4Literal(_)));
    }

    #[tokio::test]
    async fn ipv6_loopback_accepted() {
        let h = LoopbackHost::parse("http://[::1]/mcp").await.unwrap();
        assert!(matches!(h.kind, HostKind::Ipv6Literal(_)));
        assert_eq!(h.host, "::1");
    }

    #[tokio::test]
    async fn localhost_dns_accepted_when_loopback() {
        // `localhost` typically resolves to 127.0.0.1 and / or ::1 on
        // every supported dev environment. If for some reason this
        // host resolves it elsewhere, this test would correctly fail —
        // signaling a misconfigured /etc/hosts that the validator
        // refuses on principle.
        let h = LoopbackHost::parse("http://localhost/mcp").await;
        assert!(h.is_ok(), "localhost must resolve to loopback: {h:?}");
        let h = h.unwrap();
        assert!(matches!(h.kind, HostKind::Dns(_)));
    }

    #[tokio::test]
    async fn https_loopback_accepted_at_validation_time() {
        let h = LoopbackHost::parse("https://127.0.0.1/mcp").await.unwrap();
        assert_eq!(h.scheme, Scheme::Https);
        assert_eq!(h.port, 443);
    }

    // ─── REJECT cases (each from the dispatch's audit row #4) ───

    #[tokio::test]
    async fn non_loopback_dns_rejected() {
        let err = LoopbackHost::parse("http://example.com/mcp")
            .await
            .expect_err("example.com is not loopback");
        // Either DNS resolves to a non-loopback address (most common)
        // or DNS fails in CI sandboxes; both shapes are refusals.
        assert!(
            matches!(
                err,
                LoopbackError::NonLoopbackDns
                    | LoopbackError::DnsResolutionFailed
                    | LoopbackError::DnsResolutionEmpty
            ),
            "unexpected variant: {err:?}"
        );
    }

    #[tokio::test]
    async fn non_loopback_ipv6_literal_rejected() {
        let err = LoopbackHost::parse("http://[2001:db8::1]/mcp")
            .await
            .expect_err("2001:db8::1 is not loopback");
        assert_eq!(err, LoopbackError::NonLoopbackLiteral);
    }

    #[tokio::test]
    async fn non_loopback_ipv4_literal_rejected() {
        let err = LoopbackHost::parse("http://192.168.1.1/mcp")
            .await
            .expect_err("192.168.1.1 is not loopback");
        assert_eq!(err, LoopbackError::NonLoopbackLiteral);
    }

    #[tokio::test]
    async fn zero_address_rejected() {
        let err = LoopbackHost::parse("http://0.0.0.0/mcp")
            .await
            .expect_err("0.0.0.0 is not loopback");
        assert_eq!(err, LoopbackError::NonLoopbackLiteral);
    }

    #[tokio::test]
    async fn ftp_scheme_rejected() {
        let err = LoopbackHost::parse("ftp://127.0.0.1/mcp")
            .await
            .expect_err("ftp scheme is rejected");
        assert_eq!(err, LoopbackError::UnsupportedScheme);
    }

    #[tokio::test]
    async fn userinfo_in_url_rejected() {
        let err = LoopbackHost::parse("http://user:pass@127.0.0.1/mcp")
            .await
            .expect_err("userinfo is rejected");
        assert_eq!(err, LoopbackError::UserinfoNotAllowed);
    }

    #[tokio::test]
    async fn unparseable_url_rejected() {
        let err = LoopbackHost::parse("not a url at all")
            .await
            .expect_err("garbage is rejected");
        // The http crate's Uri parser refuses this shape; the exact
        // variant is Parse or MissingScheme depending on the bytes.
        assert!(matches!(
            err,
            LoopbackError::Parse | LoopbackError::MissingScheme
        ));
    }

    #[tokio::test]
    async fn missing_scheme_rejected() {
        let err = LoopbackHost::parse("127.0.0.1/mcp")
            .await
            .expect_err("schemeless is rejected");
        assert!(matches!(
            err,
            LoopbackError::Parse | LoopbackError::MissingScheme
        ));
    }

    // ─── resolve_now sanity ───

    #[tokio::test]
    async fn resolve_now_returns_loopback_for_ipv4_literal() {
        let h = LoopbackHost::parse("http://127.0.0.1:9999/mcp")
            .await
            .unwrap();
        let addr = h.resolve_now().await.unwrap();
        assert!(addr.ip().is_loopback());
        assert_eq!(addr.port(), 9999);
    }

    #[tokio::test]
    async fn resolve_now_returns_loopback_for_ipv6_literal() {
        let h = LoopbackHost::parse("http://[::1]:9999/mcp").await.unwrap();
        let addr = h.resolve_now().await.unwrap();
        assert!(addr.ip().is_loopback());
        assert_eq!(addr.port(), 9999);
    }
}
