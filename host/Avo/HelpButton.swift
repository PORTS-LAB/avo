import SwiftUI

// What a setting does is explained behind a (?) right after the title it
// explains (a form row's label or a section header), so the Control Panel
// shows the controls and Android's live state instead of grey captions under
// every row. Errors, warnings that need attention now, live status and
// validation stay inline; a warning that matters before an action stays in
// that action's confirmation dialog.

/// A form row's label (Picker, switch Toggle, LabeledContent) or a section
/// header, with its (?) right after the title. A checkbox puts its HelpButton
/// beside it instead: it would hide one in its label from VoiceOver.
struct HelpTitle<Help: View>: View {
    private let title: LocalizedStringKey
    private let help: Help

    /// `help`: one view per paragraph (`Text`, `HelpTerm`).
    init(_ title: LocalizedStringKey, @ViewBuilder help: () -> Help) {
        self.title = title
        self.help = help()
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            HelpButton(title) { help }
        }
    }
}

extension HelpTitle where Help == Text {
    init(_ title: LocalizedStringKey, help: LocalizedStringKey) {
        self.init(title) { Text(help) }
    }
}

/// A small (?) that shows an explanation in a popover.
struct HelpButton<Content: View>: View {
    private let title: LocalizedStringKey
    private let content: Content
    @State private var shown = false

    /// `title`: what is explained, the popover's first line. `content`: one
    /// view per paragraph (`Text`, `HelpTerm`).
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            // Regular weight in a bold section header too.
            Image(systemName: "questionmark.circle").fontWeight(.regular)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel(Text("Help: \(Text(title))"))
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            HelpPopover(title: title) { content }
        }
    }
}

extension HelpButton where Content == Text {
    init(_ title: LocalizedStringKey, _ text: LocalizedStringKey) {
        self.init(title) { Text(text) }
    }
}

/// The popover: the title in bold, then the paragraphs, selectable.
struct HelpPopover<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
        // Not the header's or title's font and color the (?) sits in.
        .font(.body)
        .foregroundStyle(.primary)
        // Wraps at the width below and grows as tall as the text.
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 320, alignment: .leading)
        .padding(16)
        .textSelection(.enabled)
    }
}

/// A choice in bold and what it does, for help that explains a control's options.
struct HelpTerm: View {
    private let term: Text
    private let text: Text

    init(_ term: LocalizedStringKey, _ text: LocalizedStringKey) {
        self.term = Text(term)
        self.text = Text(text)
    }

    /// For a term that is not translated (aspect ratios such as 16:9).
    init(verbatim term: String, _ text: LocalizedStringKey) {
        self.term = Text(verbatim: term)
        self.text = Text(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            term.fontWeight(.semibold)
            text
        }
    }
}
