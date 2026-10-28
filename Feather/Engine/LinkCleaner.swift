import Foundation

/// Removes tracking parameters (`utm_source`, `fbclid`, `si`, …) from links you
/// open and URLs you copy. Only parameters that exist purely for tracking are
/// removed, so pages still work; affiliate tags are left alone.
nonisolated enum LinkCleaner {
    /// Tracking parameters on any site.
    private static let parameters: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "ttclid", "twclid", "li_fat_id",
        "mc_cid", "mc_eid", "igshid", "igsh", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking",
        "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_id", "vero_conv", "epik", "_gl", "rb_clickid", "s_kwcid",
        "ef_id", "wickedid", "srsltid", "mibextid", "__tn__",
    ]
    private static let prefixes = ["utm_", "__cft__"]

    /// Extra parameters by site (registrable domain).
    private static let siteParameters: [String: Set<String>] = [
        "youtube.com": ["si", "pp", "feature"],
        "youtu.be": ["si", "feature"],
        "spotify.com": ["si", "context"],
        "x.com": ["s", "t", "ref_src", "ref_url"],
        "twitter.com": ["s", "t", "ref_src", "ref_url"],
        "instagram.com": ["igsh", "img_index"],
        "tiktok.com": ["_t", "_r", "is_from_webapp", "sender_device", "is_copy_url"],
        "linkedin.com": ["trk", "trackingid", "lipi", "refid"],
        "reddit.com": ["share_id", "rdt"],
        "amazon.com": ["ref_", "_encoding", "crid", "sprefix", "dib", "dib_tag", "qid", "sr", "content-id"],
    ]
    private static let sitePrefixes: [String: [String]] = ["amazon.com": ["pd_rd_", "pf_rd_"]]

    /// The URL without tracking parameters, or the same URL when there are none.
    static func clean(_ url: URL) -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty else { return url }
        let site = siteKey(for: url.host()?.lowercased() ?? "")
        let kept = items.filter { !isTracking($0.name.lowercased(), site: site) }
        guard kept.count != items.count else { return url }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }

    private static func isTracking(_ name: String, site: String) -> Bool {
        parameters.contains(name) || prefixes.contains { name.hasPrefix($0) }
            || siteParameters[site]?.contains(name) == true
            || sitePrefixes[site]?.contains { name.hasPrefix($0) } == true
    }

    /// "www.amazon.co.uk" → "amazon.com" so one entry covers every Amazon store.
    private static func siteKey(for host: String) -> String {
        let domain = SiteMatcher.registrableDomain(host)
        if domain.hasPrefix("amazon.") { return "amazon.com" }
        return domain
    }
}
