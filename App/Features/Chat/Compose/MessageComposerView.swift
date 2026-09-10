import SwiftUI

#if os(macOS)
import AppKit
#endif

struct MessageComposerView: View {
    @Binding var text: String
    let maxHeight: CGFloat
    let isEnabled: Bool
    let canSend: Bool
    let onSubmit: () -> Void
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 15
    @FocusState private var isInputFocused: Bool

    private var canSubmit: Bool { isEnabled && canSend }
    private var hasText: Bool { !text.isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {} label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .disabled(true)
            .accessibilityLabel("Attachments (unavailable)")
            .modifier(ChatGlassSurface(cornerRadius: 22))

            HStack(alignment: .bottom, spacing: 0) {
                TextField("Message", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize))
                    .lineLimit(1...6)
                    .frame(maxHeight: max(20, maxHeight - 24))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 12)
                    .padding(.vertical, 12)
                    .disabled(!isEnabled)
                    .focused($isInputFocused)
                    .onSubmit(submit)
                    #if os(macOS)
                    .background(ComposerShiftReturn(isFocused: isInputFocused, isEnabled: isEnabled))
                    #endif
                    .accessibilityLabel("Message")

                Button {} label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .disabled(true)
                .accessibilityLabel("Emoji (unavailable)")
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .modifier(ChatGlassSurface(cornerRadius: 22))

            Button(action: submit) {
                Image(systemName: hasText ? "paperplane.fill" : "mic")
                    .font(.system(size: 20))
                    .foregroundStyle(hasText && canSubmit ? ChahuaTheme.accent : .secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .disabled(!hasText || !canSubmit)
            .modifier(ChatGlassSurface(cornerRadius: 22, isInteractive: hasText && canSubmit))
            .accessibilityLabel(hasText ? Text("Send message") : Text("Voice message (unavailable)"))
            #if os(macOS)
            .focusable(false)
            #endif
        }
        .buttonStyle(.plain)
        .padding(12)
    }

    private func submit() {
        guard canSubmit else { return }
        onSubmit()
    }
}

#if os(macOS)
// SwiftUI's multiline TextField submits on Shift-Return on macOS. Its onSubmit
// callback is too late to intercept the key, and macOS 13 lacks onKeyPress.
// This command-only bridge leaves text, selection, undo, and IME ownership with
// SwiftUI's field editor; it never synchronizes or replaces the draft itself.
private struct ComposerShiftReturn: NSViewRepresentable {
    let isFocused: Bool
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak view, weak coordinator = context.coordinator] event in
            guard let view, let coordinator,
                  coordinator.isFocused, coordinator.isEnabled,
                  let window = view.window, event.window === window,
                  event.keyCode == 36 || event.keyCode == 76,
                  event.modifierFlags.intersection([.shift, .control, .option, .command]) == .shift,
                  let editor = window.firstResponder as? NSTextView,
                  !editor.hasMarkedText() else { return event }
            editor.insertNewlineIgnoringFieldEditor(nil)
            return nil
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.isFocused = isFocused
        context.coordinator.isEnabled = isEnabled
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
            coordinator.monitor = nil
        }
    }

    final class Coordinator {
        var isFocused = false
        var isEnabled = false
        var monitor: Any?
    }
}
#endif

private struct ChatComposerInsetKey: EnvironmentKey {
    nonisolated static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var chatComposerInset: CGFloat {
        get { self[ChatComposerInsetKey.self] }
        set { self[ChatComposerInsetKey.self] = newValue }
    }
}

/// Keep the scroll viewport behind the composer, with clearance for its current height.
struct ChatComposerOverlay<Composer: View>: ViewModifier {
    @ViewBuilder let composer: () -> Composer
    @State private var composerHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.chatComposerInset, composerHeight)
            .overlay(alignment: .bottom) {
                composer()
                    .background {
                        GeometryReader { geometry in
                            Color.clear
                                .onAppear { composerHeight = geometry.size.height }
                                .onChange(of: geometry.size.height) { composerHeight = $0 }
                        }
                    }
            }
    }
}
