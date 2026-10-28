import Foundation

nonisolated struct TourProgress {
    enum Step: Int, CaseIterable {
        case intro, newTab, address, favorite, spaces, finished
    }
    enum Event { case began, openedCommandBar, submittedAddress, closedCommandBar, addedFavorite, createdSpace, next, back }
    private(set) var step: Step = .intro

    mutating func handle(_ event: Event) {
        switch (step, event) {
        case (.intro, .began): step = .newTab
        case (.newTab, .openedCommandBar): step = .address
        case (.address, .submittedAddress): step = .favorite
        case (.address, .closedCommandBar): step = .newTab
        case (.favorite, .addedFavorite): step = .spaces
        case (.spaces, .createdSpace): step = .finished
        case (_, .next): step = Step(rawValue: min(Step.finished.rawValue, step.rawValue + 1)) ?? .finished
        case (_, .back): step = Step(rawValue: max(Step.newTab.rawValue, step.rawValue - 1)) ?? .newTab
        default: break
        }
    }
}
