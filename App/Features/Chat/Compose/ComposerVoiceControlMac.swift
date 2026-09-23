#if os(macOS)
    import SwiftUI

    // Pointer users explicitly need click-to-record/click-to-stop, not the iOS
    // press-and-drag interaction. A standard SwiftUI button preserves mouse and
    // accessibility activation without imposing touch gesture semantics on macOS.
    struct ComposerVoiceControlMac: View {
        @ObservedObject var recorder: ComposerVoiceRecorder
        let isEnabled: Bool
        let canStart: Bool
        let onStart: (Bool) -> Bool
        let onSendVoice: ((URL) async -> Bool)?

        private var canActivate: Bool {
            switch recorder.phase {
            case .idle: canStart
            case .requestingPermission, .recording: isEnabled
            case .preview: isEnabled && onSendVoice != nil
            case .sending: false
            }
        }

        private var label: LocalizedStringKey {
            switch recorder.phase {
            case .idle: "Record voice message"
            case .requestingPermission, .recording: "Stop recording"
            case .preview: "Send voice message"
            case .sending: "Sending voice message…"
            }
        }

        var body: some View {
            Button(action: activate) {
                Group {
                    switch recorder.phase {
                    case .idle:
                        Image(systemName: "mic")
                    case .requestingPermission:
                        ProgressView().controlSize(.small)
                    case .recording:
                        Image(systemName: "stop.fill")
                    case .preview:
                        Image(systemName: "paperplane.fill")
                    case .sending:
                        ProgressView().controlSize(.small)
                    }
                }
                .font(.system(size: 20))
                .foregroundStyle(canActivate ? ChahuaTheme.accent : .secondary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canActivate)
            .modifier(ChatGlassSurface(cornerRadius: 22, isInteractive: canActivate))
            .accessibilityLabel(Text(label))
            .help(Text(label))
            .modifier(ComposerSendFocus())
        }

        private func activate() {
            guard canActivate else { return }
            switch recorder.phase {
            case .idle:
                _ = onStart(false)
            case .requestingPermission, .recording:
                recorder.stop()
            case .preview:
                if let onSendVoice { recorder.send(using: onSendVoice) }
            case .sending:
                break
            }
        }
    }
#endif
