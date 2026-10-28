# Feather licenses and third-party notices

Feather's original source code and artwork are copyright (c) 2026 Feather
contributors and licensed under **GPL-3.0-only**, unless a file states otherwise.
The full GNU General Public License version 3 is in [`LICENSE`](LICENSE).
Feather is distributed without warranty; see that license for its terms.

Bundled third-party material retains the licenses and notices listed below.
These projects do not endorse Feather.

| Material | Version/source | License and local notices |
| --- | --- | --- |
| HaGeZi Multi LIGHT network domains | `2026.1028.0926.19`, upstream commit `6782a0d55068c13b08c5d583395ccd4b3540a84e` | GPL-3.0; [`Blocklist/SOURCE-NOTICES.md`](Feather/Resources/Blocklist/SOURCE-NOTICES.md) and [`LICENSE-HaGeZi.txt`](Feather/Resources/Blocklist/LICENSE-HaGeZi.txt) |
| AdGuard Scriptlets and selected AdGuard Filters | Scriptlets 2.5.1; filter revision `f404d017ca1d47ff8b1bf0c3dd41b9c258b3ca7a` | GPL-3.0; [`YouTube/upstream/LICENSE`](Feather/Resources/YouTube/upstream/LICENSE) and [`SOURCE-NOTICES.md`](Feather/Resources/YouTube/upstream/SOURCE-NOTICES.md) |
| DuckDuckGo autoconsent | 16.60.0, unmodified distribution and compact rules | MPL-2.0; [`Consent/LICENSE.txt`](Feather/Resources/Consent/LICENSE.txt) and [`SOURCE.txt`](Feather/Resources/Consent/SOURCE.txt) |
| Mozilla Readability | 0.6.0, unmodified | Apache-2.0; [`Reader/LICENSE.md`](Feather/Resources/Reader/LICENSE.md), full [`LICENSE-APACHE-2.0.txt`](Feather/Resources/Reader/LICENSE-APACHE-2.0.txt), and [`SOURCE.txt`](Feather/Resources/Reader/SOURCE.txt) |
| Study Tools for Magister | 3.16.3; commit `dcfd27b451f4aeb13f857fbed80133973b209816` | MIT; copyright (c) 2024 Quinten Althues; [`StudyTools/LICENSE`](Feather/Resources/StudyTools/LICENSE) and [`SOURCE-NOTICES.md`](Feather/Resources/StudyTools/SOURCE-NOTICES.md) |
| Edited mechanical keyboard recording | Reina0613, Freesound sound 709460 | CC0-1.0; [`Audio/Typing/LICENSE.txt`](Feather/Resources/Audio/Typing/LICENSE.txt) records source, hash and modifications |
| Synthesized tour music for releases | Original Feather synthesis; reproducible generator `Tools/Release/make-tour-audio.py` | CC0-1.0; [`Audio/README.md`](Feather/Resources/Audio/README.md) records provenance |

The short interface tap is original synthesis in `WelcomeSound.makeClickWave()`.
No Epidemic Sound reference recording is included. The previous user-supplied
tour recording and StevenBlack aggregate network list are excluded from the
public source export and prepared release resources.

## Corresponding source and modifications

Distribute the matching Feather source archive beside each application release,
including `project.yml`, `Support/`, `Feather/`, and the required build/resource
generation tools. Give the source archive an equally visible download link.
The source includes the preferred files and scripts used for Feather changes.

- The network-domain input, upstream license and FAQ, source URLs, hashes, and
  offline adapter are retained in [`Tools/BlocklistSources/`](Tools/BlocklistSources/README.md).
  Feather's changes are recorded in its bundled source notice.
- The AdGuard npm distribution, corresponding released source archive, filter
  snapshot, generator, readable patches and hash pins are retained in
  [`Tools/YouTubeLab/upstream/`](Tools/YouTubeLab/upstream/README.md).
  Feather's compatibility and notification modifications are recorded in the
  bundled upstream notice.
- Autoconsent's unmodified source is available from
  [DuckDuckGo autoconsent v16.60.0](https://github.com/duckduckgo/autoconsent/tree/v16.60.0).
  Its MPL source and license notices are preserved alongside its runtime files.
- Readability source: [Mozilla Readability 0.6.0](https://github.com/mozilla/readability/tree/0.6.0).
- Study Tools source and Feather's worker changes are identified in its bundled
  source notice; the readable bundled JavaScript, styles and translations are
  retained in the source archive.

Apple system frameworks are supplied by macOS and are not redistributed as a
custom browser engine in the DMG.
