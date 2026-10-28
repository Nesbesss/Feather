# Network and cosmetic content rules

`network.json` is adapted from HaGeZi Multi LIGHT, list version
`2026.1028.0926.19`, copyright its upstream authors and contributors,
published under GPL-3.0. The full upstream license is in `LICENSE-HaGeZi.txt`.

Source repository: https://github.com/hagezi/dns-blocklists

Pinned commit: `6782a0d55068c13b08c5d583395ccd4b3540a84e`

Published input:
https://raw.githubusercontent.com/hagezi/dns-blocklists/6782a0d55068c13b08c5d583395ccd4b3540a84e/wildcard/light-onlydomains.txt

Input SHA-256: `40d3230f935c6f1e437fa2d7dfda1e01c333ad52b1dfa647fa53007830e2eb03`

Generated JSON SHA-256: `46439726803f2b0c148dc6d2690a97c9a770e4db326ba38ca07dd9a2da6e4a28`

Feather modifications (2026-10-28): convert the 73,103 published domains to
hosts-format input, apply the existing domain normalization/deduplication, and
generate 73,103 WebKit content rules limited to third-party requests. Domain
matching also covers subdomains. These rules are not the upstream DNS format.

The exact preferred input list, license, upstream FAQ, hash manifest and
regeneration tools are in `Tools/BlocklistSources/` in the matching Feather
source distribution. Run `Tools/make-blocklist.sh --check` to reproduce offline.

`cosmetic.json` contains two Feather-authored cosmetic rules under Feather's
GPL-3.0-only license. It is independent of the HaGeZi domain snapshot.
