//! Sign-in tokens in page addresses: what is removed from every address
//! before it is stored or handed on.
//!
//! A browser can show only a site's name while its address carries
//! `access_token=…` or a signed link's `X-Amz-Signature=…`, so the window's
//! text is clean and the address is not. [`strip_secret_params`] drops every
//! query or fragment parameter whose name is a credential's (see
//! [`is_secret_param`]) and the password in `user:password@host`, and keeps
//! everything else byte for byte. The checks in [`super::ocr_secrets`] then
//! run on what is left, so a secret anywhere else in the address still stops
//! the moment.
//!
//! The capture helper does the same in Swift
//! (`SuppressionCascade.urlWithoutSecretParams`) before its own check. Both
//! are byte scans with no URL parser, and both answer every case in
//! `core/brain/fixtures/url-secret-params-corpus.json`.

use std::borrow::Cow;

/// Parameter names that are a credential on their own, lower-case.
/// MUST stay identical to Swift `SuppressionCascade.secretURLParamNames`;
/// the shared corpus is the check.
pub const SECRET_PARAM_NAMES: [&str; 10] = [
    "auth",
    "authorization",
    "code",
    "jwt",
    "key",
    "otp",
    "session",
    "session_id",
    "sessionid",
    "sig",
];

/// Endings that make a parameter name a credential's: `access_token`,
/// `id_token`, `refresh_token`, `csrf_token`, `client_secret`, `x-api-key`,
/// `X-Amz-Signature`, `X-Amz-Credential` and the like. They are also every
/// key name the key-value secret pattern looks for, so an address keeps none
/// of them for that pattern to find. MUST stay identical to Swift
/// `SuppressionCascade.secretURLParamEndings`.
pub const SECRET_PARAM_ENDINGS: [&str; 10] = [
    "api-key",
    "api_key",
    "apikey",
    "bearer",
    "credential",
    "passwd",
    "password",
    "secret",
    "signature",
    "token",
];

/// Whether a query or fragment parameter called `name` carries a credential.
/// Matched case-insensitively, after percent-decoding, and with an
/// HTML-escaped `amp;` in front of it ignored.
#[must_use]
pub fn is_secret_param(name: &str) -> bool {
    let decoded = percent_decoded_lower(name);
    let decoded = decoded.strip_prefix("amp;").unwrap_or(&decoded);
    SECRET_PARAM_NAMES.contains(&decoded)
        || SECRET_PARAM_ENDINGS
            .iter()
            .any(|ending| decoded.ends_with(ending))
}

/// `url` without credential parameters in its query or fragment, and without
/// the password in a `user:password@host` part. Borrowed and unchanged when
/// it has none. A query or fragment left empty goes with its `?` or `#`.
///
/// A fragment is read as parameters when it has an `=`: OAuth's implicit
/// flow puts `#access_token=…` there, and a page that routes in its fragment
/// puts `#/callback?token=…`. `#section-2` is a place on the page and stays.
#[must_use]
pub fn strip_secret_params(url: &str) -> Cow<'_, str> {
    let (before_fragment, fragment) = match url.find('#') {
        Some(at) => (&url[..at], Some(&url[at + 1..])),
        None => (url, None),
    };
    let (base, query) = match before_fragment.find('?') {
        Some(at) => (&before_fragment[..at], Some(&before_fragment[at + 1..])),
        None => (before_fragment, None),
    };
    let kept_base = without_userinfo_password(base);
    let kept_query = query.map(without_secret_params);
    let kept_fragment = fragment.map(fragment_without_secret_params);
    let changed = matches!(kept_base, Cow::Owned(_))
        || matches!(kept_query, Some(Cow::Owned(_)))
        || matches!(kept_fragment, Some(Cow::Owned(_)));
    if !changed {
        return Cow::Borrowed(url);
    }
    let mut out = String::with_capacity(url.len());
    out.push_str(&kept_base);
    if let Some(query) = kept_query.filter(|query| !query.is_empty()) {
        out.push('?');
        out.push_str(&query);
    }
    if let Some(fragment) = kept_fragment.filter(|fragment| !fragment.is_empty()) {
        out.push('#');
        out.push_str(&fragment);
    }
    Cow::Owned(out)
}

/// Whether [`strip_secret_params`] would change `url`.
#[must_use]
pub fn has_secret_params(url: &str) -> bool {
    matches!(strip_secret_params(url), Cow::Owned(_))
}

/// `scheme://user:password@host/…` without `:password`. Only the part
/// before the first `/` after `://` is the authority; an `@` later in the
/// path is left alone.
fn without_userinfo_password(base: &str) -> Cow<'_, str> {
    let Some(scheme_end) = base.find("://") else {
        return Cow::Borrowed(base);
    };
    let authority_start = scheme_end + 3;
    let authority_end = base[authority_start..]
        .find('/')
        .map_or(base.len(), |at| authority_start + at);
    let authority = &base[authority_start..authority_end];
    let Some(at) = authority.rfind('@') else {
        return Cow::Borrowed(base);
    };
    let Some(colon) = authority[..at].find(':') else {
        return Cow::Borrowed(base);
    };
    let mut out = String::with_capacity(base.len());
    out.push_str(&base[..authority_start + colon]);
    out.push_str(&base[authority_start + at..]);
    Cow::Owned(out)
}

/// A fragment without credential parameters: after a `?` when it has one
/// (`#/route?token=…`), else the whole fragment when it has an `=`.
fn fragment_without_secret_params(fragment: &str) -> Cow<'_, str> {
    if let Some(at) = fragment.find('?') {
        let (route, params) = (&fragment[..at], &fragment[at + 1..]);
        return match without_secret_params(params) {
            Cow::Borrowed(_) => Cow::Borrowed(fragment),
            Cow::Owned(kept) if kept.is_empty() => Cow::Owned(route.to_owned()),
            Cow::Owned(kept) => Cow::Owned(format!("{route}?{kept}")),
        };
    }
    if fragment.contains('=') {
        without_secret_params(fragment)
    } else {
        Cow::Borrowed(fragment)
    }
}

/// `params` (`a=1&b=2`) without the pieces whose name is a credential's, the
/// rest joined with `&` as they were. Borrowed when nothing is removed.
fn without_secret_params(params: &str) -> Cow<'_, str> {
    if !params.split('&').any(is_secret_piece) {
        return Cow::Borrowed(params);
    }
    Cow::Owned(
        params
            .split('&')
            .filter(|piece| !is_secret_piece(piece))
            .collect::<Vec<_>>()
            .join("&"),
    )
}

fn is_secret_piece(piece: &str) -> bool {
    let name = piece.split_once('=').map_or(piece, |(name, _)| name);
    !name.is_empty() && is_secret_param(name)
}

/// ASCII lower-case of `name` with `%XX` escapes decoded. A `%` not followed
/// by two hex digits stays as it is.
fn percent_decoded_lower(name: &str) -> String {
    let bytes = name.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(high), Some(low)) = (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                out.push(high * 16 + low);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).to_ascii_lowercase()
}

fn hex(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_address_without_credentials_is_borrowed_unchanged() {
        for url in [
            "https://app.larch.example/",
            "https://example.com/search?q=larch&page=2",
            "https://example.com/docs#section-2",
            "https://example.com/?tokens=3&keyword=larch&author=sam&codec=h264",
            "/Users/someone/src/project",
            "",
        ] {
            assert!(
                matches!(strip_secret_params(url), Cow::Borrowed(same) if same == url),
                "{url}"
            );
            assert!(!has_secret_params(url), "{url}");
        }
    }

    #[test]
    fn credential_parameters_go_and_the_rest_stays_in_order() {
        assert_eq!(
            strip_secret_params("https://app.example/cb?a=1&access_token=SYNTH&b=2"),
            "https://app.example/cb?a=1&b=2"
        );
        assert_eq!(
            strip_secret_params("https://app.example/cb?token=SYNTH"),
            "https://app.example/cb"
        );
        assert_eq!(
            strip_secret_params("https://app.example/cb#access_token=SYNTH&token_type=bearer"),
            "https://app.example/cb#token_type=bearer"
        );
        assert_eq!(
            strip_secret_params("https://app.example/#/cb?id_token=SYNTH&next=home"),
            "https://app.example/#/cb?next=home"
        );
        assert_eq!(
            strip_secret_params("https://app.example/cb?Access%5FToken=SYNTH&x=1"),
            "https://app.example/cb?x=1"
        );
        assert_eq!(
            strip_secret_params("https://sam:SYNTHpass@host.example/path?q=1"),
            "https://sam@host.example/path?q=1"
        );
    }

    #[test]
    fn a_lone_percent_sign_is_kept_as_it_is() {
        assert_eq!(percent_decoded_lower("a%"), "a%");
        assert_eq!(percent_decoded_lower("a%4"), "a%4");
        assert_eq!(percent_decoded_lower("%4B%65y"), "key");
    }
}
