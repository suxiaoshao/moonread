import MoonreadDesign
import SwiftUI

/// Grid uses the same section destinations as the collection's native list index,
/// with tap, scrub and VoiceOver buttons in a narrow rail clear of the tiles.
struct LibraryAlphabetIndex: View {
    let letters: [String]
    var current: String? = nil
    let jump: (String) -> Void
    @Environment(\.theme) private var theme
    @State private var active: String?
    var body: some View {
        VStack(spacing: 0) {
            ForEach(letters, id: \.self) { letter in
                Button { jump(letter) } label: {
                    Text(verbatim: letter).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(uiColor: current == letter ? theme.onAccent : theme.accent))
                        .frame(width: 18, height: 18)
                        .background { if current == letter { Circle().fill(Color(uiColor: theme.accent)) } }
                        .frame(width: 24, height: 18)
                }.accessibilityLabel(letter).accessibilityIdentifier("library-index-\(letter)")
                    .accessibilityAddTraits(current == letter ? .isSelected : [])
            }
        }.foregroundStyle(Color(uiColor: theme.accent))
            .contentShape(.rect)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    guard !letters.isEmpty else { return }
                    let index = min(letters.count - 1, max(0, Int(value.location.y / 18)))
                    if active != letters[index] { active = letters[index]; jump(letters[index]) }
                }.onEnded { _ in active = nil }
            )
            .padding(.trailing, 2)
    }
}
