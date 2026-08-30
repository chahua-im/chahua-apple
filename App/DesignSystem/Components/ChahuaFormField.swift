import SwiftUI

enum ChahuaTextAutocapitalization {
    case never
    case words
    case sentences
    case characters
}

struct ChahuaTextField<FieldStyle: TextFieldStyle>: View {
    let title: LocalizedStringKey
    let prompt: LocalizedStringKey
    @Binding var text: String
    let validationMessage: LocalizedStringKey?
    let autocorrectionDisabled: Bool
    let autocapitalization: ChahuaTextAutocapitalization?
    let textFieldStyle: FieldStyle

    init(
        title: LocalizedStringKey,
        prompt: LocalizedStringKey,
        text: Binding<String>,
        validationMessage: LocalizedStringKey? = nil,
        autocorrectionDisabled: Bool = false,
        autocapitalization: ChahuaTextAutocapitalization? = nil,
        textFieldStyle: FieldStyle
    ) {
        self.title = title
        self.prompt = prompt
        _text = text
        self.validationMessage = validationMessage
        self.autocorrectionDisabled = autocorrectionDisabled
        self.autocapitalization = autocapitalization
        self.textFieldStyle = textFieldStyle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ChahuaTheme.Spacing.xSmall) {
            Text(title).font(.headline)
            TextField(prompt, text: $text)
                .autocorrectionDisabled(autocorrectionDisabled)
                .chahuaAutocapitalization(autocapitalization)
                .textFieldStyle(textFieldStyle)
            if let validationMessage {
                Text(validationMessage).font(.footnote).foregroundStyle(
                    ChahuaTheme.destructive
                )
            }
        }
    }
}

extension ChahuaTextField where FieldStyle == RoundedBorderTextFieldStyle {
    init(
        title: LocalizedStringKey,
        prompt: LocalizedStringKey,
        text: Binding<String>,
        validationMessage: LocalizedStringKey? = nil,
        autocorrectionDisabled: Bool = false,
        autocapitalization: ChahuaTextAutocapitalization? = nil
    ) {
        self.init(
            title: title,
            prompt: prompt,
            text: text,
            validationMessage: validationMessage,
            autocorrectionDisabled: autocorrectionDisabled,
            autocapitalization: autocapitalization,
            textFieldStyle: .roundedBorder
        )
    }
}

extension View {
    @ViewBuilder
    fileprivate func chahuaAutocapitalization(
        _ behavior: ChahuaTextAutocapitalization?
    ) -> some View {
        #if os(iOS)
            switch behavior {
            case .never: textInputAutocapitalization(.never)
            case .words: textInputAutocapitalization(.words)
            case .sentences: textInputAutocapitalization(.sentences)
            case .characters: textInputAutocapitalization(.characters)
            case nil: self
            }
        #else
            self
        #endif
    }
}

struct ChahuaSecureField: View {
    let title: LocalizedStringKey
    let prompt: LocalizedStringKey
    @Binding var text: String
    let validationMessage: LocalizedStringKey?

    init(
        title: LocalizedStringKey,
        prompt: LocalizedStringKey,
        text: Binding<String>,
        validationMessage: LocalizedStringKey? = nil
    ) {
        self.title = title
        self.prompt = prompt
        _text = text
        self.validationMessage = validationMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ChahuaTheme.Spacing.xSmall) {
            Text(title).font(.headline)
            SecureField(prompt, text: $text)
                .textFieldStyle(.roundedBorder)
            if let validationMessage {
                Text(validationMessage).font(.footnote).foregroundStyle(
                    ChahuaTheme.destructive
                )
            }
        }
    }
}

struct ChahuaPrimaryButton: View {
    let title: LocalizedStringKey
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isWorking { ProgressView() } else { Text(title) }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isWorking)
        .accessibilityLabel(Text(title))
    }
}
