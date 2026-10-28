// Builds Feather/Resources/Blocklist/network.json from a hosts-format list.
// Usage: make-blocklist <hosts-file> <output.json>
// Bundled source: pinned HaGeZi Multi LIGHT (GPL-3.0), adapted to hosts format.
// Provenance, exact input, hashes and license: Tools/BlocklistSources/.
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-blocklist <hosts-file> <output.json>\n".utf8))
    exit(2)
}
let hosts = try String(contentsOfFile: arguments[1], encoding: .utf8)
let domains = BlocklistConverter.domains(fromHosts: hosts)
let data = try BlocklistConverter.networkRules(for: domains)
try data.write(to: URL(fileURLWithPath: arguments[2]), options: .atomic)
let written = min(domains.count, BlocklistConverter.maxRules)
print("\(domains.count) domains, \(written) rules, \(data.count / 1024) KB → \(arguments[2])")
