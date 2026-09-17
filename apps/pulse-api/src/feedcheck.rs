use pulse_core::SourceKind;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

/// Feed bodies are capped well above any real RSS/Atom document.
const MAX_BODY_BYTES: usize = 1024 * 1024;

/// Test-only escape hatch: wiremock binds 127.0.0.1. Never set in production.
fn allow_loopback() -> bool {
    std::env::var("PULSE_ALLOW_LOOPBACK_FEEDS").as_deref() == Ok("1")
}

/// Fetches the URL and checks it parses as RSS or Atom. No LLM here.
///
/// SSRF guard: http(s) only, no credentials, resolved addresses must be public,
/// redirects refused, body capped at `MAX_BODY_BYTES`, transport errors not echoed.
pub async fn validate_feed_url(client: &reqwest::Client, url: &str) -> Result<SourceKind, String> {
    let parsed = reqwest::Url::parse(url).map_err(|_| "invalid URL".to_string())?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return Err("URL must be http(s)".into());
    }
    if !parsed.username().is_empty() || parsed.password().is_some() {
        return Err("URL must not contain credentials".into());
    }
    let host = parsed
        .host_str()
        .ok_or_else(|| "invalid URL".to_string())?
        .to_string();
    let port = parsed
        .port_or_known_default()
        .ok_or_else(|| "invalid URL".to_string())?;

    let addrs: Vec<IpAddr> = tokio::net::lookup_host((host.as_str(), port))
        .await
        .map_err(|_| "URL does not resolve".to_string())?
        .map(|a| a.ip())
        .collect();
    if addrs.is_empty() {
        return Err("URL does not resolve".into());
    }
    for ip in &addrs {
        if !is_public_ip(*ip) && !(ip.is_loopback() && allow_loopback()) {
            return Err("URL must resolve to a public address".into());
        }
    }

    let resp = client.get(parsed).send().await.map_err(|e| {
        tracing::debug!(error = %e, "feed fetch failed");
        "could not fetch URL".to_string()
    })?;
    if resp.status().is_redirection() {
        return Err("URL redirects; use the final feed URL".into());
    }
    let mut resp = resp.error_for_status().map_err(|e| {
        tracing::debug!(error = %e, "feed fetch failed");
        "could not fetch URL".to_string()
    })?;
    if resp
        .content_length()
        .is_some_and(|len| len > MAX_BODY_BYTES as u64)
    {
        return Err("feed exceeds 1MiB size limit".into());
    }

    let mut body = Vec::new();
    while let Some(chunk) = resp.chunk().await.map_err(|e| {
        tracing::debug!(error = %e, "feed read failed");
        "could not fetch URL".to_string()
    })? {
        body.extend_from_slice(&chunk);
        if body.len() > MAX_BODY_BYTES {
            return Err("feed exceeds 1MiB size limit".into());
        }
    }

    if rss::Channel::read_from(&body[..]).is_ok() {
        return Ok(SourceKind::Rss);
    }
    if atom_syndication::Feed::read_from(&body[..]).is_ok() {
        return Ok(SourceKind::Atom);
    }
    Err("URL is not an RSS or Atom feed".into())
}

/// True if `ip` is globally routable: not loopback, private, link-local, CGNAT,
/// unique-local, or unspecified/broadcast — including IPv4-mapped IPv6 forms of those.
fn is_public_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_public_ipv4(v4),
        IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => is_public_ipv4(v4),
            None => {
                !(v6.is_loopback()
                    || v6.is_unspecified()
                    || is_unique_local_v6(v6)
                    || is_link_local_v6(v6))
            }
        },
    }
}

fn is_public_ipv4(v4: Ipv4Addr) -> bool {
    !(v4.is_loopback()
        || v4.is_private()
        || v4.is_link_local()
        || v4.is_broadcast()
        || v4.is_unspecified()
        || is_cgnat(v4))
}

/// 100.64.0.0/10, the carrier-grade NAT range (RFC 6598).
fn is_cgnat(v4: Ipv4Addr) -> bool {
    let o = v4.octets();
    o[0] == 100 && (64..=127).contains(&o[1])
}

/// fc00::/7.
fn is_unique_local_v6(v6: Ipv6Addr) -> bool {
    (v6.segments()[0] & 0xfe00) == 0xfc00
}

/// fe80::/10.
fn is_link_local_v6(v6: Ipv6Addr) -> bool {
    (v6.segments()[0] & 0xffc0) == 0xfe80
}

pub fn kind_str(k: SourceKind) -> &'static str {
    match k {
        SourceKind::Rss => "rss",
        SourceKind::Atom => "atom",
        SourceKind::HackerNews => "hackernews",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_public_ip_rejects_non_global_addresses() {
        let non_global = [
            "127.0.0.1",        // loopback
            "10.0.0.1",         // private
            "169.254.169.254",  // link-local / cloud metadata
            "100.64.1.1",       // CGNAT
            "172.16.0.1",       // private
            "192.168.1.1",      // private
            "0.0.0.0",          // unspecified
            "255.255.255.255",  // broadcast
            "::1",              // loopback
            "::",               // unspecified
            "fd00::1",          // unique-local
            "fe80::1",          // link-local
            "::ffff:127.0.0.1", // IPv4-mapped loopback
            "::ffff:10.0.0.1",  // IPv4-mapped private
        ];
        for ip in non_global {
            let addr: IpAddr = ip.parse().unwrap();
            assert!(!is_public_ip(addr), "{ip} should not be public");
        }
    }

    #[test]
    fn is_public_ip_accepts_global_addresses() {
        let global = ["1.1.1.1", "8.8.8.8", "2606:4700::1111"];
        for ip in global {
            let addr: IpAddr = ip.parse().unwrap();
            assert!(is_public_ip(addr), "{ip} should be public");
        }
    }
}
