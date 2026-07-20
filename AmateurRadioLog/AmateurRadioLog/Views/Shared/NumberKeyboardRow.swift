import SwiftUI

/// iOS keyboards show either letters or numbers, never both, so a callsign
/// (letters *and* digits) means constantly flipping layers. This adds a
/// persistent row of number keys — plus "/" for portable calls — above the
/// alphabetic keyboard while the callsign field is focused, tapping a key
/// appends it. No-op on macOS, where the hardware keyboard already has both.
extension View {
    func numberKeyboardRow(text: Binding<String>, isActive: Bool) -> some View {
        #if os(iOS)
        modifier(NumberKeyboardRow(text: text, isActive: isActive))
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct NumberKeyboardRow: ViewModifier {
    @Binding var text: String
    var isActive: Bool

    private static let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "/"]

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                // Gated on focus so it never appears over the number-pad
                // fields (frequency, RST) in the same screen.
                if isActive {
                    HStack(spacing: 4) {
                        ForEach(Self.keys, id: \.self) { key in
                            Button {
                                text += key
                            } label: {
                                Text(key)
                                    .font(.system(.title3, design: .rounded))
                                    .frame(maxWidth: .infinity, minHeight: 34)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(key == "/" ? "Slash" : key))
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
#endif
