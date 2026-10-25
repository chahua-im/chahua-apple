#if os(iOS)
    import SwiftUI
    import UIKit

    /// SwiftUI presentation preferences can retain an explicit scheme when changed
    /// back to nil. A window override updates existing sheets/covers and native
    /// controls together; `.unspecified` genuinely resumes system appearance.
    struct NativeAppAppearance: UIViewRepresentable {
        let appearance: AppAppearance

        func makeUIView(context: Context) -> AppearanceView {
            let view = AppearanceView()
            view.appearance = appearance
            return view
        }

        func updateUIView(_ view: AppearanceView, context: Context) {
            view.appearance = appearance
        }

        final class AppearanceView: UIView {
            var appearance = AppAppearance.system {
                didSet { applyAppearance() }
            }

            override func didMoveToWindow() {
                super.didMoveToWindow()
                applyAppearance()
            }

            private func applyAppearance() {
                guard let window else { return }
                let style: UIUserInterfaceStyle =
                    switch appearance {
                    case .system: .unspecified
                    case .light: .light
                    case .dark: .dark
                    }
                if window.overrideUserInterfaceStyle != style {
                    window.overrideUserInterfaceStyle = style
                }
            }
        }
    }
#endif
