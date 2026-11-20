import Combine
import SwiftUI

/// Owned by one presented conversation, never by the shared audio session.
@MainActor
final class VoiceTimelineVisibility: ObservableObject {
    @Published private(set) var visible: VoicePlaybackSession.Identity?
    private var host: ObjectIdentifier?

    fileprivate func report(_ identity: VoicePlaybackSession.Identity?, from host: ObjectIdentifier)
    {
        guard identity != nil || self.host == host else { return }
        self.host = identity == nil ? nil : host
        if visible != identity { visible = identity }
    }

    static func isInlineVisible(of bubble: CGRect, in viewport: CGRect, wasVisible: Bool?) -> Bool {
        guard !bubble.isEmpty, !viewport.isEmpty else { return false }
        let overlap = viewport.intersection(bubble)
        // Start at half. Require a larger move to give control back to the bubble
        // than to keep it there, so small reversals do not retrigger the handoff.
        let threshold = wasVisible.map { $0 ? 0.40 : 0.60 } ?? 0.50
        return !overlap.isEmpty
            && overlap.width * overlap.height >= bubble.width * bubble.height * threshold
    }

    /// At a scroll limit, changing the native inset can clamp the physical
    /// origin. Project both slot states into the same scrollable range.
    static func referenceViewport(
        _ viewport: CGRect, scrollTop: CGFloat, bottomLimit: CGFloat, headerInset: CGFloat
    ) -> CGRect {
        let minOffset = -headerInset
        let referenceTop = min(max(scrollTop, minOffset), max(minOffset, bottomLimit))
        return CGRect(
            x: viewport.minX, y: referenceTop + headerInset, width: viewport.width,
            height: max(0, viewport.maxY - scrollTop - headerInset))
    }
}

struct VoiceTimelineTarget: Equatable {
    let identity: VoicePlaybackSession.Identity
    let controllerID: ObjectIdentifier
    let visibility: VoiceTimelineVisibility

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.controllerID == rhs.controllerID && lhs.visibility === rhs.visibility
    }
}

extension EnvironmentValues {
    @Entry var voiceTimelineTarget: VoiceTimelineTarget? = nil
    /// Title and eligible pins, as if the playback capsule were not present.
    @Entry var voiceReferenceHeaderInset: CGFloat? = nil
    /// Native scroll limit, held steady while playback is eligible for the slot.
    @Entry var chatScrollHeaderInset: CGFloat? = nil
}

/// Native layout can run during a SwiftUI update. Publish only the latest result on
/// the next main turn, and do not let an old host clear a new host's report.
@MainActor
final class VoiceTimelineReporter {
    var target: VoiceTimelineTarget? {
        didSet {
            guard oldValue != target else { return }
            if let oldValue {
                let host = ObjectIdentifier(self)
                DispatchQueue.main.async { oldValue.visibility.report(nil, from: host) }
            }
            previousResult = nil
            generation += 1
        }
    }

    private var previousResult: Bool?
    private var generation = 0
    private var indexedRevision = -1
    private var indexedIdentity: VoicePlaybackSession.Identity?
    private var index: Int?

    func rowIndex(in rows: [TimelineRow], chatID: String, revision: Int) -> Int? {
        guard let identity = target?.identity, identity.chatID == chatID else { return nil }
        if indexedIdentity != identity || indexedRevision != revision {
            indexedIdentity = identity
            indexedRevision = revision
            index = rows.firstIndex { $0.messageID == identity.messageID }
        }
        return index
    }

    func report(region: CGRect, in viewport: CGRect) {
        report(
            VoiceTimelineVisibility.isInlineVisible(
                of: region, in: viewport, wasVisible: previousResult))
    }

    func report(_ isVisible: Bool) {
        guard let target, previousResult != isVisible else { return }
        previousResult = isVisible
        generation += 1
        let current = generation
        DispatchQueue.main.async { [self] in
            guard current == generation else { return }
            target.visibility.report(
                isVisible ? target.identity : nil, from: ObjectIdentifier(self))
        }
    }
}
