#if os(iOS)
    import SwiftUI

    enum AccountAvatarRole: Hashable { case source, hero }

    private struct AccountAvatarFrames: PreferenceKey {
        static let defaultValue: [AccountAvatarRole: CGRect] = [:]
        static func reduce(
            value: inout [AccountAvatarRole: CGRect], nextValue: () -> [AccountAvatarRole: CGRect]
        ) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }

    private struct AccountAvatarHiddenKey: EnvironmentKey {
        static let defaultValue = false
    }

    extension EnvironmentValues {
        fileprivate var accountAvatarHidden: Bool {
            get { self[AccountAvatarHiddenKey.self] }
            set { self[AccountAvatarHiddenKey.self] = newValue }
        }
    }

    /// Measure native-list/toolbar endpoints, but draw the flight outside their clips.
    struct AccountAvatarEndpoint: ViewModifier {
        let role: AccountAvatarRole
        @Environment(\.accountAvatarHidden) private var hidden

        func body(content: Content) -> some View {
            content
                .opacity(hidden ? 0 : 1)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: AccountAvatarFrames.self,
                            value: [role: geometry.frame(in: .global)])
                    }
                }
        }
    }

    /// A single overlay avatar avoids native List/NavigationStack coordinate and clipping
    /// discontinuities. iPad/macOS keep their native sheet presentation instead.
    struct AccountProfilePresentation<Profile: View>: ViewModifier {
        let isPresented: Bool
        let avatarURL: URL?
        let displayName: String
        @ViewBuilder let profile: () -> Profile
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorScheme) private var colorScheme
        @ScaledMetric(relativeTo: .body) private var avatarDiameter: CGFloat = 112
        @State private var mounted = false
        @State private var panelVisible = false
        @State private var inFlight = false
        @State private var atHero = false
        @State private var source = CGRect.zero
        @State private var hero = CGRect.zero
        @State private var flightSource = CGRect.zero
        @State private var flightHero = CGRect.zero
        @State private var transition: Task<Void, Never>?
        @State private var generation = 0

        private var motion: Animation { .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.48) }
        private var panelOffset: CGFloat { reduceMotion || panelVisible ? 0 : 28 }

        func body(content: Content) -> some View {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .disabled(mounted)
                        .allowsHitTesting(!mounted)
                        .accessibilityHidden(mounted)
                        .environment(\.accountAvatarHidden, inFlight)
                    if mounted {
                        profile()
                            .environment(\.accountAvatarHidden, inFlight)
                            .accessibilityAddTraits(.isModal)
                            .accessibilityHidden(!panelVisible)
                            .opacity(panelVisible ? 1 : 0)
                            .animation(
                                .easeOut(duration: reduceMotion ? 0.15 : 0.38), value: panelVisible
                            )
                            .offset(y: panelOffset)
                            .animation(
                                reduceMotion ? .easeOut(duration: 0.15) : motion,
                                value: panelVisible
                            )
                            .scrollDisabled(inFlight)
                    }
                    if inFlight {
                        let rect = atHero ? flightHero : flightSource
                        let origin = geometry.frame(in: .global).origin
                        AvatarView(url: avatarURL, displayName: displayName, diameter: 112)
                            .overlay { Circle().strokeBorder(.white, lineWidth: 4) }
                            .shadow(
                                color: .black.opacity(colorScheme == .dark ? 0.22 : 0.10),
                                radius: 16, y: 12
                            )
                            .frame(width: avatarDiameter, height: avatarDiameter)
                            .scaleEffect(rect.width / avatarDiameter)
                            .position(x: rect.midX - origin.x, y: rect.midY - origin.y)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .onPreferenceChange(AccountAvatarFrames.self) { frames in
                    source = frames[.source] ?? .zero
                    if let frame = frames[.hero], frame.width > 0 {
                        hero = frame.offsetBy(dx: 0, dy: -panelOffset)
                    }
                }
                .onChange(of: isPresented, initial: true) { _, presented in
                    changePresentation(presented, bounds: geometry.frame(in: .global))
                }
            }
            .onDisappear { transition?.cancel() }
        }

        private func changePresentation(_ presented: Bool, bounds: CGRect) {
            transition?.cancel()
            generation += 1
            let revision = generation
            if presented {
                mounted = true
                // Let the native list lay out its real endpoint before starting the flight.
                transition = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled, revision == generation else { return }
                    flightSource = source
                    flightHero = hero
                    inFlight =
                        !reduceMotion && source.width > 0 && hero.width > 0
                        && bounds.intersects(hero)
                    atHero = false
                    try? await Task.sleep(for: .milliseconds(16))
                    guard !Task.isCancelled, revision == generation else { return }
                    withAnimation(reduceMotion ? .easeOut(duration: 0.15) : motion) {
                        atHero = true
                        panelVisible = true
                    }
                    try? await Task.sleep(for: .milliseconds(reduceMotion ? 150 : 480))
                    guard !Task.isCancelled, revision == generation else { return }
                    inFlight = false
                }
            } else if mounted {
                if !inFlight {
                    flightSource = source
                    flightHero = hero
                    inFlight =
                        !reduceMotion && source.width > 0 && hero.width > 0
                        && bounds.intersects(hero)
                    atHero = true
                }
                transition = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(16))
                    guard !Task.isCancelled, revision == generation else { return }
                    if source.isEmpty { inFlight = false }
                    withAnimation(reduceMotion ? .easeOut(duration: 0.15) : motion) {
                        atHero = false
                        panelVisible = false
                    }
                    try? await Task.sleep(for: .milliseconds(reduceMotion ? 150 : 480))
                    guard !Task.isCancelled, revision == generation else { return }
                    inFlight = false
                    mounted = false
                }
            }
        }
    }
#endif
