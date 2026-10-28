import Foundation
import FoundationModels
import os

/// Apple's on-device language model (Apple Intelligence), used for the smart
/// sidebar and automatic tab groups. It runs on this Mac; nothing is sent
/// anywhere. Requests run one at a time. Page titles and labels are untrusted
/// text, so answers are constrained to a Bool or short group names and tab numbers.
final class AppleIntelligence {
    static let shared = AppleIntelligence()

    private let log = Logger(subsystem: "dev.nesbes.Feather", category: "AppleIntelligence")
    private var queue: Task<Void, Never>?

    var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// Why the model can't be used, in words for Settings; nil when it can.
    var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This Mac doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in System Settings to use this."
        case .unavailable(.modelNotReady): "Apple Intelligence is still getting ready. Try again later."
        case .unavailable: "Apple Intelligence isn't available right now."
        }
    }

    /// Runs requests one after another.
    private func serially<T>(_ work: @escaping () async throws -> T) async throws -> T {
        let previous = queue
        let task = Task { () async throws -> T in
            await previous?.value
            return try await work()
        }
        queue = Task { _ = try? await task.value }
        return try await task.value
    }

    // MARK: Smart sidebar

    @Generable
    struct SidebarAdvice {
        @Guide(description: "true if the browser should hide its own tab sidebar on this site to give the site more room")
        var hideBrowserSidebar: Bool
    }

    private static let sidebarInstructions = """
        A web browser shows its tabs in a sidebar on the left. Some websites have their own navigation panel on the \
        left too, so the page ends up with two sidebars side by side. Decide if the browser should hide its sidebar \
        on this site. Answer true when the site's own left panel is its main navigation, as in mail, chat, AI \
        assistants, video sites, music, documents, project tools, and design tools. Answer false when the left \
        panel is just a table of contents or search filters, as in encyclopedias, articles, documentation, \
        news, search results, and shopping.
        """

    /// Whether Feather's sidebar should step aside on `host`; nil if the model couldn't answer.
    func shouldHideSidebar(host: String, title: String, layout: PageLayout) async -> Bool? {
        guard isAvailable else { return nil }
        var lines = ["Site: \(host)", "Title: \(title.prefix(80))"]
        if let width = layout.ownSidebarWidth {
            let labels = layout.navLabels.prefix(8).joined(separator: ", ")
            lines.append("The page has its own navigation panel on the left, \(width) px wide, with: \(labels).")
        } else {
            lines.append("The page has no panel on the left.")
        }
        lines.append(layout.appLike ? "The page itself doesn't scroll, like an app." : "The page scrolls normally.")
        let prompt = lines.joined(separator: "\n")
        do {
            let hide = try await serially {
                let session = LanguageModelSession(instructions: Self.sidebarInstructions)
                return try await session.respond(to: prompt, generating: SidebarAdvice.self,
                                                 options: GenerationOptions(sampling: .greedy)).content.hideBrowserSidebar
            }
            log.info("Sidebar on \(host, privacy: .public): \(hide ? "hide" : "show", privacy: .public)")
            return hide
        } catch {
            log.error("Sidebar advice failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Tab groups

    // Like Safari's tab clustering: the model describes each tab once (Safari's per-page
    // "intent"), the notes are embedded and clustered (TabClustering), and only then is
    // the model asked to name each group, from that group's tabs alone. One tab per request:
    // listing several tabs in one prompt let neighbouring tabs' notes bleed into each other.

    @Generable
    struct TabNote {
        @Guide(description: "The page's topic in one or two words, like Travel, Swift, AI, Headphones, or Recipes")
        var topic: String
        @Guide(description: "What the person is doing or reading about on this page, in 3 to 8 words, like 'planning a trip to Lisbon' or 'learning the Swift language'")
        var intent: String
    }

    private static let noteInstructions = """
        You describe what a person is doing on one of their open browser tabs, based on its title, site, \
        and description.
        """

    /// "Topic: what you're doing", for one tab; nil if the model couldn't answer.
    func describeTab(title: String, host: String, summary: String?) async -> String? {
        guard isAvailable else { return nil }
        var prompt = "Title: \(title.prefix(120))\nSite: \(host)"
        if let summary, !summary.isEmpty { prompt += "\nDescription: \(summary.prefix(200))" }
        do {
            let note = try await serially {
                let session = LanguageModelSession(instructions: Self.noteInstructions)
                return try await session.respond(to: prompt, generating: TabNote.self,
                                                 options: GenerationOptions(sampling: .greedy)).content
            }
            return "\(note.topic.trimmingCharacters(in: .whitespaces)): \(note.intent.trimmingCharacters(in: .whitespaces))"
        } catch {
            log.error("Tab note failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    @Generable
    struct GroupName {
        @Guide(description: "A name for the group in one to three words, like Lisbon Trip, Swift, AI Research, or Recipes")
        var name: String
    }

    private static let nameInstructions = """
        You name a group of related browser tabs the way a person would label a folder: one to three words, \
        no description. Use the language of the tab titles.
        """

    /// A short name for a group of tabs, from their titles and notes.
    func nameGroup(titles: [String], notes: [String]) async -> String? {
        guard isAvailable else { return nil }
        // Like Safari's deduplicateForTopicGeneration: each title once, a handful at most.
        var seen = Set<String>()
        let lines = zip(titles, notes).filter { seen.insert($0.0).inserted }.prefix(8)
            .map { "- \($0.0.prefix(90)) (\($0.1))" }
        do {
            let name = try await serially {
                let session = LanguageModelSession(instructions: Self.nameInstructions)
                return try await session.respond(to: "Tabs:\n" + lines.joined(separator: "\n"), generating: GroupName.self,
                                                 options: GenerationOptions(sampling: .greedy)).content.name
            }
            return name
        } catch {
            log.error("Group name failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
