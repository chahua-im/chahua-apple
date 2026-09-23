import SwiftUI

struct ConversationScopePicker: View {
    @Binding var selection: ConversationListScope
    var badges = ConversationTabBadges()

    var body: some View {
        Picker("Conversation scope", selection: $selection) {
            ForEach(ConversationListScope.allCases) { scope in
                Text(title(for: scope))
                    .tag(scope)
                    .accessibilityValue(
                        badges[scope] > 0 ? Text("\(badges[scope]) unread conversations") : Text("")
                    )
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .overlay(alignment: .top) {
            // The native picker retains its Liquid Glass selection and gestures.
            // Badges decorate the segment edges without intercepting any touches.
            HStack(spacing: 0) {
                ForEach(ConversationListScope.allCases) { scope in
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .topTrailing) {
                            if badges[scope] > 0 {
                                Text(badges[scope] > 999 ? "999+" : String(badges[scope]))
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor, in: Capsule())
                                    .fixedSize()
                                    .offset(x: -2, y: -4)
                            }
                        }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func title(for scope: ConversationListScope) -> LocalizedStringKey {
        switch scope {
        case .messages: "Messages"
        case .groups: "Groups"
        case .dms: "DMs"
        case .threads: "Threads"
        }
    }
}

#if DEBUG
    #Preview("Chat tabs with badges") {
        ConversationScopePickerPreview()
    }

    private struct ConversationScopePickerPreview: View {
        @State private var selection: ConversationListScope = .messages
        @State private var groups = 12
        @State private var dms = 3
        @State private var threads = 1000
        @State private var barWidth: Double = 380

        private var badges: ConversationTabBadges {
            var counts = ConversationTabBadges()
            counts.groups = groups
            counts.dms = dms
            counts.threads = threads
            return counts
        }

        var body: some View {
            VStack(spacing: 24) {
                ConversationListHeader(selection: $selection, badges: badges) {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .foregroundStyle(.blue)
                }
                .frame(width: barWidth)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Bar width: \(Int(barWidth)) pt")
                    Slider(value: $barWidth, in: 320...500, step: 1)
                    Stepper("Groups: \(groups)", value: $groups, in: 0...2000)
                    Stepper("DMs: \(dms)", value: $dms, in: 0...2000)
                    Stepper("Threads: \(threads)", value: $threads, in: 0...2000)
                    Button("Clear badges") {
                        groups = 0
                        dms = 0
                        threads = 0
                    }
                }
                .frame(width: 300)
            }
            .padding(.vertical, 24)
            .frame(width: 540)
        }
    }
#endif
