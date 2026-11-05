import Combine
import SwiftUI

/// Shell-owned memory outlives a pushed archive list, without sharing accounts/windows.
@MainActor
final class ConversationListPresentation: ObservableObject {
    enum Request {
        case reset
        case revealSearch
        case dismissSearchKeyboard
    }

    let requests = PassthroughSubject<Request, Never>()
    private(set) var resetGeneration = 0
    fileprivate var offsets: [String: CGFloat] = [:]

    func reset() {
        offsets.removeAll()
        resetGeneration += 1
        requests.send(.reset)
    }

    /// Programmatic reveal follows pull-to-reveal: it never takes keyboard focus.
    func revealSearch() { requests.send(.revealSearch) }

    func dismissSearchKeyboard() { requests.send(.dismissSearchKeyboard) }
}

/// List has no scroll-offset or pull-distance API on iOS 17 / macOS 14. The native
/// marker observes only its enclosing List, without replacing either scroll delegate.
@MainActor
final class ConversationListScrollScope: ObservableObject {
    static let revealDistance: CGFloat = 36
    static let refreshDistance: CGFloat = 120
    static let drawerHeight: CGFloat = 64
    static let prototypeDrawerHeight: CGFloat = 56
    static let prototypeRefreshDistance: CGFloat = 120
    static let prototypeRefreshHold: CGFloat = 100
    var prototypeSearchHeight: CGFloat {
        Self.prototypeDrawerHeight + max(0, prototypeSearchAdditionalHeight)
    }
    private var prototypeRefreshOpening: CGFloat {
        Self.prototypeRefreshHold + max(0, prototypeSearchAdditionalHeight)
    }
    var prototypeSearchAdditionalHeight: CGFloat = 0 {
        didSet {
            guard prototypePullEnabled, oldValue != prototypeSearchAdditionalHeight,
                isSearchRevealed
            else { return }
            settlePrototype(
                to: isRefreshing ? prototypeRefreshOpening : prototypeSearchHeight, duration: 0.2)
        }
    }

    @Published private(set) var isSearchRevealed = false
    @Published private(set) var drawerOffset: CGFloat = 0
    @Published private(set) var pullDistance: CGFloat = 0
    var onRefresh: (() -> Void)?
    var prototypePullEnabled = false {
        didSet {
            guard prototypePullEnabled != oldValue else { return }
            isGestureActive = false
            settlePrototype(
                to: prototypePullEnabled && isSearchRevealed ? prototypeSearchHeight : 0)
        }
    }
    var isSearchPinned = false {
        didSet {
            if prototypePullEnabled, isSearchPinned, pullDistance < prototypeSearchHeight {
                settlePrototype(to: prototypeSearchHeight)
            }
        }
    }
    @Published var isRefreshing = false {
        didSet {
            guard prototypePullEnabled, oldValue != isRefreshing, isSearchRevealed else { return }
            settlePrototype(
                to: isRefreshing ? prototypeRefreshOpening : prototypeSearchHeight,
                duration: isRefreshing ? 0.22 : 0.4)
        }
    }
    var presentation: ConversationListPresentation?
    private var positions: [String: CGFloat] = [:]
    private var context: String?
    private var presentationGeneration = 0
    private var preSearchOffset: CGFloat?
    private var gestureStartOffset: CGFloat = 0
    private var resumeOffset: CGFloat?
    private var isActive = true
    private var maximumPull: CGFloat = 0
    private var gestureStartOpening: CGFloat = 0
    private var isGestureActive = false
    private var pendingOffset: CGFloat?
    private var nativeLifetimeGeneration = 0
    private(set) var driver: (any ConversationListScrollDriver)?

    func select(
        scope: ConversationListScope, archived: Bool, currentUserID: Int32,
        preservingSearch: Bool = false
    ) {
        if let presentation, presentationGeneration != presentation.resetGeneration {
            reset()
        }
        let next = "\(currentUserID):\(scope.rawValue):\(archived)"
        guard context != next else { return }
        savePosition()
        context = next
        let offset = presentation?.offsets[next] ?? positions[next] ?? 0
        let keepSearch = preservingSearch && isSearchRevealed
        isSearchRevealed = keepSearch
        preSearchOffset = keepSearch ? offset : nil
        isSearchPinned = keepSearch
        resumeOffset = nil
        isGestureActive = false
        maximumPull = 0
        pullDistance = prototypePullEnabled && keepSearch ? prototypeSearchHeight : 0
        restore(offset)
    }

    func attach(_ driver: any ConversationListScrollDriver, preservingOffset: Bool = false) {
        guard self.driver !== driver else {
            // A replacement viewport host can adopt the same native scroll view.
            // Its ownership invalidates an earlier host's deferred release.
            nativeLifetimeGeneration += 1
            return
        }
        guard isActive else {
            driver.detach()
            return
        }
        if preservingOffset {
            detachDriver()
        } else {
            self.driver?.detach()
        }
        nativeLifetimeGeneration += 1
        self.driver = driver
        if let resumeOffset {
            self.resumeOffset = nil
            driver.restore(offset: resumeOffset)
        } else if let pendingOffset {
            self.pendingOffset = nil
            driver.restore(offset: pendingOffset)
        } else if let context, let offset = positions[context] {
            driver.restore(offset: offset)
        }
        if prototypePullEnabled {
            driver.setPrototypeOpening(pullDistance, duration: 0)
        }
    }

    func activate() {
        nativeLifetimeGeneration += 1
        isActive = true
    }

    /// Native marker teardown runs inside SwiftUI's update transaction. Keep its
    /// publication on the next main turn, unless a new marker has taken ownership.
    func detachAfterViewUpdate() {
        let generation = nativeLifetimeGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, nativeLifetimeGeneration == generation else { return }
            detach()
        }
    }

    /// A macOS viewport can remount while the SwiftUI screen stays active. An old
    /// bridge must not detach its replacement or deactivate the still-visible scope.
    func releaseNativeDriverAfterViewUpdate(_ expectedDriver: any ConversationListScrollDriver) {
        let generation = nativeLifetimeGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, nativeLifetimeGeneration == generation, driver === expectedDriver
            else { return }
            detachDriver()
        }
    }

    func reset() {
        positions.removeAll()
        context = nil
        preSearchOffset = nil
        resumeOffset = nil
        pendingOffset = nil
        isSearchRevealed = false
        isSearchPinned = false
        isGestureActive = false
        maximumPull = 0
        pullDistance = 0
        presentationGeneration = presentation?.resetGeneration ?? 0
        restore(0)
    }

    func detach() {
        isActive = false
        detachDriver()
    }

    private func detachDriver() {
        nativeLifetimeGeneration += 1
        guard let driver else { return }
        savePosition()
        resumeOffset = driver.restorationOffset
        driver.detach()
        self.driver = nil
        isGestureActive = false
        maximumPull = 0
        pullDistance =
            prototypePullEnabled && isSearchRevealed
            ? (isRefreshing ? prototypeRefreshOpening : prototypeSearchHeight) : 0
    }

    func beginGesture(offset: CGFloat? = nil) {
        guard !isGestureActive, !prototypePullEnabled || !isRefreshing else { return }
        isGestureActive = true
        gestureStartOpening =
            prototypePullEnabled ? (isSearchRevealed ? prototypeSearchHeight : 0) : pullDistance
        gestureStartOffset = max(0, offset ?? driver?.offset ?? 0)
        maximumPull = 0
    }

    func didScroll(offset: CGFloat) {
        if isGestureActive {
            if prototypePullEnabled {
                let raw = max(0, -offset)
                let opening =
                    raw <= prototypeSearchHeight
                    ? raw : prototypeSearchHeight + (raw - prototypeSearchHeight) * 0.55
                settlePrototype(to: max(isSearchPinned ? prototypeSearchHeight : 0, opening))
                return
            }
            maximumPull = max(maximumPull, -offset)
            let pull = isSearchRevealed ? 0 : min(Self.drawerHeight, max(0, -offset))
            if pullDistance != pull { pullDistance = pull }
        }
        let visibleOffset = min(Self.drawerHeight, max(0, offset))
        if drawerOffset != visibleOffset { drawerOffset = visibleOffset }
    }

    func endGesture(cancelled: Bool = false) {
        guard isGestureActive else { return }
        isGestureActive = false
        if prototypePullEnabled {
            if cancelled {
                settlePrototype(
                    to: isSearchPinned ? prototypeSearchHeight : gestureStartOpening,
                    duration: 0.28)
            } else if pullDistance >= Self.prototypeRefreshDistance
                + max(0, prototypeSearchAdditionalHeight),
                !isRefreshing,
                let onRefresh
            {
                revealPrototypeSearch()
                isRefreshing = true
                onRefresh()
            } else if pullDistance >= prototypeSearchHeight / 2 || isSearchPinned {
                revealPrototypeSearch()
                settlePrototype(to: prototypeSearchHeight, duration: 0.32)
            } else {
                isSearchRevealed = false
                preSearchOffset = nil
                settlePrototype(to: 0, duration: 0.28)
            }
            return
        }
        pullDistance = 0
        guard !cancelled else {
            maximumPull = 0
            return
        }
        if maximumPull >= Self.revealDistance, !isSearchRevealed {
            revealSearch(restoring: gestureStartOffset)
        }
        if maximumPull >= Self.refreshDistance, !isRefreshing {
            onRefresh?()
        }
        maximumPull = 0
    }

    func revealSearch() {
        revealSearch(restoring: max(0, driver?.offset ?? 0))
    }

    private func revealSearch(restoring offset: CGFloat) {
        if prototypePullEnabled {
            if !isSearchRevealed {
                preSearchOffset = offset
                isSearchRevealed = true
            }
            restore(0)
            settlePrototype(to: prototypeSearchHeight, duration: 0.32)
            return
        }
        if !isSearchRevealed {
            preSearchOffset = offset
            isSearchRevealed = true
        }
        restore(0)
    }

    func cancelSearch() {
        let offset =
            preSearchOffset
            ?? max(0, (driver?.offset ?? 0) - (prototypePullEnabled ? 0 : Self.drawerHeight))
        isSearchRevealed = false
        isSearchPinned = false
        preSearchOffset = nil
        if prototypePullEnabled { settlePrototype(to: 0) }
        restore(offset)
    }

    private func savePosition() {
        guard let context, let driver else { return }
        let drawer =
            !prototypePullEnabled && isSearchRevealed && !isSearchPinned ? Self.drawerHeight : 0
        positions[context] = max(0, driver.restorationOffset - drawer)
        presentation?.offsets[context] = positions[context]
    }

    private func restore(_ offset: CGFloat) {
        if prototypePullEnabled {
            driver?.setPrototypeOpening(pullDistance, duration: 0)
        }
        drawerOffset = min(Self.drawerHeight, max(0, offset))
        if let driver {
            driver.restore(offset: offset)
        } else {
            pendingOffset = offset
        }
    }

    /// The native display link publishes the actual opening, so the field and
    /// spinner track the same cubic tween as the List's inset, not its target.
    func didUpdatePrototypeOpening(_ opening: CGFloat) {
        if pullDistance != opening { pullDistance = opening }
    }

    private func settlePrototype(to opening: CGFloat, duration: TimeInterval = 0) {
        if let driver {
            driver.setPrototypeOpening(opening, duration: duration)
        } else {
            didUpdatePrototypeOpening(opening)
        }
    }

    private func revealPrototypeSearch() {
        if !isSearchRevealed {
            preSearchOffset = gestureStartOffset
            isSearchRevealed = true
        }
    }
}

@MainActor
protocol ConversationListScrollDriver: AnyObject {
    var offset: CGFloat { get }
    /// The logical target to preserve when replacing a native viewport. A queued
    /// restore can belong to a newly selected scope while `offset` is still stale.
    var restorationOffset: CGFloat { get }
    func restore(offset: CGFloat)
    func setPrototypeOpening(_ opening: CGFloat, duration: TimeInterval)
    func detach()
}

extension ConversationListScrollDriver {
    var restorationOffset: CGFloat { offset }
    func setPrototypeOpening(_ opening: CGFloat, duration: TimeInterval) {}
}
