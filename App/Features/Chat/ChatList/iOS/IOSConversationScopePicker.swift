#if os(iOS)
    import SwiftUI

    struct IOSConversationScopePicker: View {
        @Binding var selection: ConversationListScope
        var badges: ConversationTabBadges

        var body: some View {
            Picker("Conversation scope", selection: $selection) {
                ForEach(ConversationListScope.allCases) { scope in
                    Text(scope.localizedTitle)
                        .tag(scope)
                        .accessibilityValue(
                            badges[scope] > 0
                                ? Text("\(badges[scope]) unread conversations") : Text("")
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
    }

    #if DEBUG
        #Preview("Chat tabs with badges") {
            IOSConversationScopePickerPreview()
        }

        private struct IOSConversationScopePickerPreview: View {
            @State private var selection: ConversationListScope = .messages

            private var badges: ConversationTabBadges {
                var counts = ConversationTabBadges()
                counts.groups = 12
                counts.dms = 3
                counts.threads = 1000
                return counts
            }

            var body: some View {
                ConversationScopePicker(selection: $selection, badges: badges)
                    .padding()
            }
        }
    #endif
#endif
