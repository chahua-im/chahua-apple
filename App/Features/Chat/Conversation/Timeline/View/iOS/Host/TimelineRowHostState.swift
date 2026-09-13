#if os(iOS)
import Combine
import SwiftUI

@MainActor
final class TimelineRowHostState: ObservableObject {
    @Published private(set) var binding: TimelineRowBinding?

    func bind(_ binding: TimelineRowBinding) {
        guard self.binding?.hasSameRendering(as: binding) != true else { return }
        self.binding = binding
    }

    func clear() {
        binding = nil
    }
}

struct TimelineRowHostView: View {
    @ObservedObject var state: TimelineRowHostState

    var body: some View {
        if let binding = state.binding {
            bubble(binding)
            .frame(width: binding.layout.size.width, height: binding.layout.size.height, alignment: .topLeading)
            .id(binding.presentation.row.id)
        } else {
            Color.clear
        }
    }

    private func bubble(_ binding: TimelineRowBinding) -> some View {
        TimelineBubbleView(
            presentation: binding.presentation,
            layout: binding.layout,
            context: binding.context,
            actions: binding.actions,
            mediaContext: binding.mediaContext
        )
    }
}



#endif
