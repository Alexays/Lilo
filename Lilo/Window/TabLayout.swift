import Foundation

enum TabPosition: String, CaseIterable {
    case left, right, top, bottom

    var isVertical: Bool { self == .left || self == .right }
}

enum AddressPlacement: String {
    case tabs, page, hidden

    /// Right and bottom keep a toolbar over the page for the traffic lights, so the address goes there.
    static func `default`(for position: TabPosition) -> AddressPlacement {
        position == .right || position == .bottom ? .page : .tabs
    }
}

/// Which edge holds the tabs, app-wide, and where the address goes.
struct TabLayout: Equatable {
    var position: TabPosition
    var address: AddressPlacement

    static let `default` = TabLayout(position: .left, address: .tabs)

    private static let positionCacheKey = "cachedTabPosition"
    private static let addressCacheKey = "cachedAddressPlacement"

    init(position: TabPosition, address: AddressPlacement) {
        self.position = position
        self.address = address
    }

    /// On the left and the top, the toolbar holds only the address: it hides apart from the tabs.
    var canHideToolbar: Bool { address == .page && (position == .left || position == .top) }

    /// The layout as drawn: a hidden toolbar takes its address along.
    func shown(toolbarVisible: Bool) -> TabLayout {
        canHideToolbar && !toolbarVisible ? TabLayout(position: position, address: .hidden) : self
    }

    /// An address nobody chose follows the position.
    init(position: TabPosition, storedAddress: String?) {
        self.init(position: position, address: storedAddress.flatMap(AddressPlacement.init(rawValue:)) ?? .default(for: position))
    }

    init(storedPosition: String?, storedAddress: String?) {
        self.init(position: storedPosition.flatMap(TabPosition.init(rawValue:)) ?? .left, storedAddress: storedAddress)
    }

    /// The launch-time copy, read before the database so the first paint has the right layout.
    static var cached: TabLayout {
        unsafe TabLayout(storedPosition: UserDefaults.lilo.string(forKey: positionCacheKey), storedAddress: UserDefaults.lilo.string(forKey: addressCacheKey))
    }

    func cache() {
        unsafe UserDefaults.lilo.set(position.rawValue, forKey: Self.positionCacheKey)
        unsafe UserDefaults.lilo.set(address.rawValue, forKey: Self.addressCacheKey)
    }
}
