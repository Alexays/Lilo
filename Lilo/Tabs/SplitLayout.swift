import Foundation

/// How a split folder's tabs tile the content area: a binary tree of cuts with one tab per leaf.
indirect enum SplitLayout: Codable, Equatable, Sendable {
    case pane(tabId: UUID)
    /// `first` is the left part, or the top one when `vertical`; it holds `ratio` of the length
    /// left once the divider is taken out.
    case split(vertical: Bool, ratio: Double, first: SplitLayout, second: SplitLayout)

    static let maxPanes = 4

    /// Tabs in reading order: top to bottom, then left to right.
    var paneIds: [UUID] {
        switch self {
        case let .pane(tabId): [tabId]
        case let .split(_, _, first, second): first.paneIds + second.paneIds
        }
    }

    /// Cuts the `target` pane in two; `tabId` takes the left or top half when `before`.
    func inserting(_ tabId: UUID, at target: UUID, vertical: Bool, before: Bool) -> SplitLayout {
        switch self {
        case let .pane(id) where id == target:
            let added = SplitLayout.pane(tabId: tabId)
            return .split(vertical: vertical, ratio: 0.5, first: before ? added : self, second: before ? self : added)
        case .pane:
            return self
        case let .split(isVertical, ratio, first, second):
            return .split(
                vertical: isVertical, ratio: ratio,
                first: first.inserting(tabId, at: target, vertical: vertical, before: before),
                second: second.inserting(tabId, at: target, vertical: vertical, before: before)
            )
        }
    }

    /// Drops a pane: the other side of its cut takes the whole cut. Nil when nothing is left.
    func removing(_ tabId: UUID) -> SplitLayout? {
        switch self {
        case let .pane(id):
            return id == tabId ? nil : self
        case let .split(vertical, ratio, first, second):
            guard let keptFirst = first.removing(tabId) else { return second }
            guard let keptSecond = second.removing(tabId) else { return keptFirst }
            return .split(vertical: vertical, ratio: ratio, first: keptFirst, second: keptSecond)
        }
    }

    func mappingPanes(_ transform: (UUID) -> UUID) -> SplitLayout {
        switch self {
        case let .pane(id):
            return .pane(tabId: transform(id))
        case let .split(vertical, ratio, first, second):
            return .split(vertical: vertical, ratio: ratio, first: first.mappingPanes(transform), second: second.mappingPanes(transform))
        }
    }

    /// The part of the tree at `path`, false stepping into `first` and true into `second`.
    func subtree(at path: [Bool]) -> SplitLayout? {
        guard let step = path.first else { return self }
        guard case let .split(_, _, first, second) = self else { return nil }
        return (step ? second : first).subtree(at: Array(path.dropFirst()))
    }

    /// Rewrites the cut at `path`, false stepping into `first` and true into `second`.
    func updatingCut(at path: [Bool], _ update: (_ vertical: inout Bool, _ ratio: inout Double) -> Void) -> SplitLayout {
        guard case var .split(vertical, ratio, first, second) = self else { return self }
        if let step = path.first {
            let rest = Array(path.dropFirst())
            if step { second = second.updatingCut(at: rest, update) } else { first = first.updatingCut(at: rest, update) }
        } else {
            update(&vertical, &ratio)
        }
        return .split(vertical: vertical, ratio: ratio, first: first, second: second)
    }

    /// For the sidebar, which draws the shape but not the ratios.
    var bridgeData: [String: Any] {
        switch self {
        case let .pane(tabId):
            ["tabId": tabId.uuidString]
        case let .split(vertical, _, first, second):
            ["vertical": vertical, "first": first.bridgeData, "second": second.bridgeData]
        }
    }
}
