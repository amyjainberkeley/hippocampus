//! ADR-0030 §3(b) — `SensitiveDomainTable` accessor.
//!
//! Reads `docs/research/sensitive-domains.toml` at compile time via
//! [`include_str!`] and parses the seed list of bank, credit-union,
//! international-bank, fintech, auth-provider, and URL-pattern entries
//! into an immutable, lazily-initialized table.
//!
//! # Matching semantics (ADR-0030 §3(b))
//!
//! - `domain` matches the **registrable domain (eTLD+1)**. Subdomains
//!   match: `chase.com` matches `secure01.chase.com`, `app.chase.com`.
//! - Case-insensitive — `Chase.com` matches `chase.com` matches
//!   `CHASE.COM`.
//! - `oauth_callback_hosts` entries may carry a leading `*.` wildcard
//!   (e.g. `*.auth0.com`) which is treated as a domain-suffix match.
//! - `url_pattern.regex` matches the FULL URL via the
//!   [`regex::Regex`] crate (Rust regex, no PCRE features).
//!
//! # Privacy invariant
//!
//! The compiled table is content-free — only public marketing domains
//! and OWASP/RFC URL pattern shapes. No tokens, no PII, no
//! user-specific entries. This module never opens a network socket,
//! never reads a file at runtime, never receives a dynamic update.
//! Refresh is a recompile after editing `sensitive-domains.toml` (a
//! CSO-signed PR per ADR-0030 §3(b)).

use std::collections::HashSet;
use std::sync::OnceLock;

use regex::Regex;
use serde::Deserialize;

/// The TOML file is bundled into the binary at compile time. Per
/// ADR-0030 §3(b) `docs/research/sensitive-domains.toml` is the
/// single source of truth; the Rust accessor reads from there only.
const RAW_TOML: &str = include_str!("../../../../docs/research/sensitive-domains.toml");

/// Lazily-initialized table. The `OnceLock<SensitiveDomainTable>` is
/// populated on first call to [`matches_sensitive_domain`] (or any of
/// the read-side helpers). Parse failure is a compile-time-tested
/// invariant — [`tests::table_loads`] is the trip-wire.
static TABLE: OnceLock<SensitiveDomainTable> = OnceLock::new();

/// Read-only view of the parsed `sensitive-domains.toml`.
///
/// Materialized once at first read via [`get`]. The struct exposes
/// targeted accessors ([`matches_domain`], [`matches_url_pattern`])
/// rather than raw fields so callers cannot mutate the cached state.
#[derive(Debug)]
pub struct SensitiveDomainTable {
    /// All `domains = […]` entries (and `oauth_callback_hosts` entries
    /// with the leading `*.` stripped) — lowercased.
    /// Lookup is by eTLD+1 (or any suffix match against this set).
    domains: HashSet<String>,
    /// Compiled URL-pattern regexes from `[[url_pattern]]`. Order
    /// matches the TOML — the first match wins; callers only need to
    /// know "did any pattern fire."
    url_patterns: Vec<Regex>,
}

/// Get-or-initialize the global [`SensitiveDomainTable`].
///
/// First call parses [`RAW_TOML`] + compiles every `url_pattern.regex`.
/// Subsequent calls return the cached table.
///
/// # Panics
///
/// Panics if the embedded TOML cannot be parsed or any URL-pattern
/// regex fails to compile. These are compile-time-asserted invariants
/// covered by [`tests::table_loads`]; a panic here means an editor
/// landed a malformed TOML or an invalid regex into
/// `docs/research/sensitive-domains.toml` — the trip-wire test in
/// `cargo test -p mci-brain` is the gate that catches this before
/// landing.
#[must_use]
pub fn get() -> &'static SensitiveDomainTable {
    TABLE.get_or_init(SensitiveDomainTable::load)
}

impl SensitiveDomainTable {
    /// Parse [`RAW_TOML`] and compile all URL-pattern regexes.
    fn load() -> Self {
        let parsed: RawTable = toml::from_str(RAW_TOML)
            .expect("docs/research/sensitive-domains.toml failed to parse");

        let mut domains: HashSet<String> = HashSet::new();
        for entry in &parsed.us_bank {
            for d in &entry.domains {
                domains.insert(d.to_ascii_lowercase());
            }
        }
        for entry in &parsed.us_credit_union {
            for d in &entry.domains {
                domains.insert(d.to_ascii_lowercase());
            }
        }
        for entry in &parsed.intl_bank {
            for d in &entry.domains {
                domains.insert(d.to_ascii_lowercase());
            }
        }
        for entry in &parsed.fintech {
            for d in &entry.domains {
                domains.insert(d.to_ascii_lowercase());
            }
        }
        for entry in &parsed.auth_provider {
            for d in &entry.domains {
                domains.insert(d.to_ascii_lowercase());
            }
            for h in &entry.oauth_callback_hosts {
                let lower = h.to_ascii_lowercase();
                // Strip leading `*.` wildcard — the suffix-match below
                // already handles subdomains, so the stripped form is
                // equivalent.
                let stripped = lower.strip_prefix("*.").unwrap_or(&lower);
                domains.insert(stripped.to_owned());
            }
        }

        let mut url_patterns: Vec<Regex> = Vec::with_capacity(parsed.url_pattern.len());
        for entry in &parsed.url_pattern {
            let re = Regex::new(&entry.regex).unwrap_or_else(|err| {
                panic!(
                    "url_pattern {:?} failed to compile: {err}",
                    entry.name.as_deref().unwrap_or("<unnamed>")
                );
            });
            url_patterns.push(re);
        }

        Self {
            domains,
            url_patterns,
        }
    }

    /// True iff `host` matches a known sensitive domain.
    ///
    /// `host` is normalized to lowercase. Match succeeds when the host
    /// exactly equals a table entry, OR when the host ends with `.` +
    /// a table entry (subdomain match). Wildcards in the table (e.g.
    /// `*.auth0.com`) were stripped to `auth0.com` at parse time.
    #[must_use]
    pub fn matches_domain(&self, host: &str) -> bool {
        let host_lower = host.to_ascii_lowercase();
        // Strip a trailing dot — `chase.com.` is a fully-qualified DNS
        // form occasionally seen in headers.
        let host_trim = host_lower.trim_end_matches('.');
        if self.domains.contains(host_trim) {
            return true;
        }
        // Suffix match — `secure01.chase.com` matches `chase.com`.
        // Walk every dot-separated suffix; `set.contains` is O(1).
        let mut rest = host_trim;
        while let Some(idx) = rest.find('.') {
            rest = &rest[idx + 1..];
            if rest.is_empty() {
                break;
            }
            if self.domains.contains(rest) {
                return true;
            }
        }
        false
    }

    /// True iff `url` matches any `[[url_pattern]]` regex.
    #[must_use]
    pub fn matches_url_pattern(&self, url: &str) -> bool {
        self.url_patterns.iter().any(|re| re.is_match(url))
    }

    /// Count of distinct domain entries. Surface for trip-wire tests.
    #[must_use]
    pub fn domain_count(&self) -> usize {
        self.domains.len()
    }

    /// Count of distinct URL-pattern regexes. Surface for trip-wire
    /// tests.
    #[must_use]
    pub fn url_pattern_count(&self) -> usize {
        self.url_patterns.len()
    }
}

/// True iff `domain_or_url` matches the sensitive-domain table or any
/// URL-pattern regex.
///
/// Convenience for the cascade-twice caller — equivalent to a
/// combined domain+URL probe. Accepts:
///
/// - A bare host (e.g. `chase.com`, `login.microsoftonline.com`).
/// - A full URL (e.g. `https://accounts.google.com/oauth/authorize?...`).
///   The host is extracted via a lightweight scheme + authority parser
///   (no `url` crate dep; the parse is privacy-irrelevant and only
///   covers `http(s)://host[:port][/…]` shapes).
///
/// Match path:
///
/// 1. If the input contains `://`, the host portion is extracted and
///    domain-matched.
/// 2. The full input is also tested against every URL-pattern regex.
/// 3. If the input is a bare host (no `://`), it is domain-matched.
#[must_use]
pub fn matches_sensitive_domain(domain_or_url: &str) -> bool {
    let table = get();
    let trimmed = domain_or_url.trim();
    if trimmed.is_empty() {
        return false;
    }
    if let Some(host) = extract_host(trimmed) {
        if table.matches_domain(host) {
            return true;
        }
        if table.matches_url_pattern(trimmed) {
            return true;
        }
        return false;
    }
    // Bare host or `email@domain` shape.
    let host = trimmed.rsplit('@').next().unwrap_or(trimmed);
    table.matches_domain(host)
}

/// Extract the host portion of a `scheme://host[:port][/…]` URL.
///
/// Returns `None` for inputs that do not contain `://` — those are
/// treated as bare hosts by the caller. The parse is intentionally
/// lightweight (no `url` crate dep): privacy doesn't depend on
/// URL-parse perfection, since any failure falls back to the bare-host
/// path which still domain-matches the input as a whole.
fn extract_host(s: &str) -> Option<&str> {
    let rest = s.split_once("://")?.1;
    let authority_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..authority_end];
    // Strip optional userinfo (`user:pass@`).
    let after_userinfo = authority.rsplit_once('@').map_or(authority, |(_, h)| h);
    // Strip optional port.
    let host = after_userinfo
        .split_once(':')
        .map_or(after_userinfo, |(h, _)| h);
    if host.is_empty() {
        None
    } else {
        Some(host)
    }
}

// ---------------------------------------------------------------------------
// Raw TOML shape — kept private to this module.
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize, Default)]
struct RawTable {
    #[serde(default)]
    us_bank: Vec<RawBank>,
    #[serde(default)]
    us_credit_union: Vec<RawBank>,
    #[serde(default)]
    intl_bank: Vec<RawBank>,
    #[serde(default)]
    fintech: Vec<RawBank>,
    #[serde(default)]
    auth_provider: Vec<RawAuthProvider>,
    #[serde(default)]
    url_pattern: Vec<RawUrlPattern>,
}

#[derive(Debug, Deserialize)]
struct RawBank {
    #[allow(dead_code)]
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    domains: Vec<String>,
    // Other fields (sender_short_codes, country) are intentionally
    // ignored — this PR only consumes domains. Future ADR-0030
    // refinements may wire short-codes once Messages-sender metadata
    // surfaces in the OCR event payload.
}

#[derive(Debug, Deserialize)]
struct RawAuthProvider {
    #[allow(dead_code)]
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    domains: Vec<String>,
    #[serde(default)]
    oauth_callback_hosts: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct RawUrlPattern {
    #[serde(default)]
    name: Option<String>,
    regex: String,
    #[allow(dead_code)]
    #[serde(default)]
    notes: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn table_loads() {
        let table = get();
        // Cycle-8.14 seed PR ships >50 domains. Use a generous lower
        // bound so future entry additions don't break the test, but
        // catch a parse failure that lands an empty table.
        assert!(
            table.domain_count() >= 50,
            "expected ≥50 sensitive-domain entries, got {}",
            table.domain_count()
        );
        assert!(
            table.url_pattern_count() >= 5,
            "expected ≥5 url_pattern regexes, got {}",
            table.url_pattern_count()
        );
    }

    #[test]
    fn matches_us_bank_exact() {
        assert!(matches_sensitive_domain("chase.com"));
        assert!(matches_sensitive_domain("CHASE.COM"));
        assert!(matches_sensitive_domain("bankofamerica.com"));
        assert!(matches_sensitive_domain("wellsfargo.com"));
        assert!(matches_sensitive_domain("americanexpress.com"));
    }

    #[test]
    fn matches_us_bank_subdomain() {
        assert!(matches_sensitive_domain("secure01.chase.com"));
        assert!(matches_sensitive_domain("login.bankofamerica.com"));
        assert!(matches_sensitive_domain("app.wellsfargo.com"));
        assert!(matches_sensitive_domain("appleid.apple.com"));
    }

    #[test]
    fn matches_fintech_and_crypto() {
        assert!(matches_sensitive_domain("paypal.com"));
        assert!(matches_sensitive_domain("venmo.com"));
        assert!(matches_sensitive_domain("coinbase.com"));
        assert!(matches_sensitive_domain("kraken.com"));
        assert!(matches_sensitive_domain("robinhood.com"));
    }

    #[test]
    fn matches_auth_provider() {
        assert!(matches_sensitive_domain("auth0.com"));
        assert!(matches_sensitive_domain("login.microsoftonline.com"));
        assert!(matches_sensitive_domain("accounts.google.com"));
        assert!(matches_sensitive_domain("clerk.com"));
        assert!(matches_sensitive_domain("supabase.co"));
    }

    #[test]
    fn matches_oauth_callback_wildcard() {
        // `*.auth0.com` stripped to `auth0.com` → subdomain match.
        assert!(matches_sensitive_domain("my-tenant.auth0.com"));
        assert!(matches_sensitive_domain("acme.okta.com"));
    }

    #[test]
    fn matches_email_address_extracts_domain() {
        assert!(matches_sensitive_domain("secure@chase.com"));
        assert!(matches_sensitive_domain("alerts@bankofamerica.com"));
        assert!(matches_sensitive_domain("notifications@appleid.apple.com"));
    }

    #[test]
    fn matches_full_url() {
        assert!(matches_sensitive_domain(
            "https://www.chase.com/digital/security"
        ));
        assert!(matches_sensitive_domain(
            "http://secure01.chase.com:8080/login"
        ));
        assert!(matches_sensitive_domain(
            "https://accounts.google.com/oauth/authorize?client_id=abc"
        ));
    }

    #[test]
    fn matches_password_reset_url_pattern() {
        // Reset-path regex catches /reset, /reset-password, /recovery, etc.
        assert!(matches_sensitive_domain(
            "https://example.com/reset?t=abc123"
        ));
        assert!(matches_sensitive_domain(
            "https://example.org/reset-password/abc"
        ));
        assert!(matches_sensitive_domain(
            "https://x.example/account-recovery?token=xyz"
        ));
    }

    #[test]
    fn matches_oauth_callback_pattern() {
        assert!(matches_sensitive_domain(
            "https://app.example.com/oauth/callback?code=xyz"
        ));
        assert!(matches_sensitive_domain(
            "https://example.com/oauth2/authorize?response_type=code"
        ));
    }

    #[test]
    fn matches_magic_link_pattern() {
        assert!(matches_sensitive_domain(
            "https://example.com/magic-link?t=abc"
        ));
        assert!(matches_sensitive_domain(
            "https://example.org/passwordless?token=abc"
        ));
    }

    #[test]
    fn ignores_unrelated_domains() {
        assert!(!matches_sensitive_domain("example.com"));
        assert!(!matches_sensitive_domain("wikipedia.org"));
        assert!(!matches_sensitive_domain("hackernews.com"));
        assert!(!matches_sensitive_domain(""));
        assert!(!matches_sensitive_domain("https://example.com/products"));
    }

    #[test]
    fn ignores_homoglyph_and_prefix_misses() {
        // chase.com is sensitive; chase.com.attacker.example is NOT —
        // the registrable-domain match is right-anchored on dot
        // boundary, so a prefix-spoof does not match.
        assert!(!matches_sensitive_domain("chase.com.attacker.example"));
        // A domain that contains "chase" as a substring but is not a
        // subdomain of chase.com is NOT a match.
        assert!(!matches_sensitive_domain("notchase.com"));
        // An attacker-controlled subdomain *under* attacker.example is
        // not matched just because the path mentions /chase.com/.
        assert!(!matches_sensitive_domain(
            "https://attacker.example/chase.com/login"
        ));
    }

    #[test]
    fn extract_host_handles_common_shapes() {
        assert_eq!(extract_host("https://chase.com/login"), Some("chase.com"));
        assert_eq!(
            extract_host("http://user:pass@chase.com:8080/x"),
            Some("chase.com")
        );
        assert_eq!(
            extract_host("https://chase.com?next=1"),
            Some("chase.com")
        );
        assert_eq!(extract_host("chase.com/login"), None);
        assert_eq!(extract_host(""), None);
    }
}
