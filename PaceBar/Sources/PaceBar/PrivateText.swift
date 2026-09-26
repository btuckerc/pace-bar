import SwiftUI

/// Identity text (emails, URLs, model names) hidden until clicked, like private costs.
/// While hidden, neither the view nor the accessibility tree contains the text or its length.
struct PrivateText: View {
    let text: String
    /// Spoken name of the hidden value, such as "email address".
    let name: String
    @State private var visible = false

    var body: some View {
        Button { self.visible.toggle() } label: {
            Text(self.visible ? self.text : "••••••••••••")
                .blur(radius: self.visible ? 0 : 3)
                .lineLimit(1).truncationMode(.middle)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .help(self.visible ? "Click to hide" : "Click to reveal")
        .accessibilityLabel("\(self.visible ? "Hide" : "Show") \(self.name)")
        .accessibilityValue(self.visible ? self.text : "Hidden")
        .onDisappear { self.visible = false }
    }
}
