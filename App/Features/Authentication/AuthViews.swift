import ChahuaAPI
import SwiftUI

struct AuthLoginView: View {
    @ObservedObject var model: AuthSessionModel
    @State private var username = ""
    @State private var password = ""
    #if DEBUG
    @State private var uid = ""
    @State private var manualJWT = ""
    @State private var showingGallery = false
    #endif

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                loginForm
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
                    .padding(.horizontal, ChahuaTheme.Spacing.xLarge)
                    .padding(.vertical, ChahuaTheme.Spacing.xxLarge)
            }
        }
    }

    private var loginForm: some View {
        VStack(alignment: .leading, spacing: ChahuaTheme.Spacing.large) {
            Text("Sign in").font(.largeTitle.bold())
            Text("Use your Chahua account to continue.").foregroundStyle(ChahuaTheme.secondaryText)
            ChahuaTextField(
                title: "Username",
                prompt: "Username",
                text: $username,
                autocorrectionDisabled: true,
                autocapitalization: .never
            )
            ChahuaSecureField(title: "Password", prompt: "Password", text: $password)
            if let validation = model.validationMessage { Text(validation).foregroundStyle(ChahuaTheme.destructive) }
            ChahuaPrimaryButton(title: "Sign in", isWorking: model.isSubmitting) {
                Task { await model.signIn(username: username, password: password); password = "" }
            }
            #if DEBUG
            DisclosureGroup("Developer authentication") {
                VStack(alignment: .leading, spacing: ChahuaTheme.Spacing.medium) {
                    TextField("Positive user ID", text: $uid).textFieldStyle(.roundedBorder)
                    Button("Create development session") {
                        let value = Int64(uid).flatMap(Int32.init(exactly:)) ?? 0
                        Task { await model.createDevSession(uid: value) }
                    }.disabled(model.isSubmitting)
                    SecureField("Manual JWT", text: $manualJWT).textFieldStyle(.roundedBorder)
                    Button("Sign in with manual JWT") { Task { await model.signIn(candidateJWT: manualJWT); manualJWT = "" } }
                        .disabled(model.isSubmitting)
                    Button("Component gallery") { showingGallery = true }
                }.padding(.top, ChahuaTheme.Spacing.small)
            }
            .sheet(isPresented: $showingGallery) { FixtureGalleryView() }
            #endif
        }
    }
}

struct AuthenticatedAccountView: View {
    @ObservedObject var model: AuthSessionModel
    let me: MeResponse

    var body: some View {
        VStack(spacing: ChahuaTheme.Spacing.xLarge) {
            AvatarView(url: URL(string: me.avatarUrl ?? ""), displayName: me.username, diameter: 72)
            Text(me.username).font(.title.bold())
            Text("Signed in").foregroundStyle(ChahuaTheme.secondaryText)
            Button("Sign out", role: .destructive) { Task { await model.logout() } }
                .buttonStyle(.bordered)
                .disabled(model.isSubmitting)
        }
        .padding()
    }
}
