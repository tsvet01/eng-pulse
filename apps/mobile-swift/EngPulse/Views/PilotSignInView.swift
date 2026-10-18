import AuthenticationServices
import CryptoKit
import Security
import SwiftUI

struct PilotEntryView: View {
    @ObservedObject private var services = AppServices.shared
    @Environment(\.scenePhase) private var scenePhase
    var model: PilotAccountModel? { services.pilotAccountModel }

    var body: some View {
        Group {
            if let context = services.pilotReader {
                ContentView()
                    .environmentObject(context.appState)
                    .environmentObject(context.ttsService)
                    .environmentObject(context.personalState)
                    .id(context.id)
                    .task { await context.personalState.flush() }
            } else if let model {
                PilotSignInView(model: model)
            } else {
                ContentUnavailableView("Sign-in unavailable", systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("This build needs its pilot sign-in settings before you can continue."))
            }
        }
        .task { await model?.restore() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, let model, model.phase.session != nil, !model.isBusy {
                Task {
                    await model.restore()
                    await services.pilotReader?.appState.refreshSummaries()
                    await services.pilotReader?.personalState.flush()
                }
            }
        }
    }
}

private struct PilotSignInView: View {
    @ObservedObject var model: PilotAccountModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var email = ""
    @State private var code = ""
    @State private var invite = ""
    @State private var appleNonce: String?
    @State private var appleAttempt: UUID?
    @State private var showsRestoreProgress = false

    var body: some View {
        Group {
            switch model.phase {
            case .restoring, .admitted:
                ZStack {
                    Color.surface.ignoresSafeArea()
                    if model.phase == .restoring, let message = model.errorMessage, !model.isBusy {
                        ErrorView(message: message) { Task { await model.restore() } }
                    } else if showsRestoreProgress {
                        ProgressView().accessibilityLabel("Opening Eng Pulse")
                    }
                }
                .accessibilityIdentifier("pilot.restoring")
                .task {
                    do { try await Task.sleep(for: .milliseconds(300)) }
                    catch { return }
                    showsRestoreProgress = true
                }
                .onDisappear { showsRestoreProgress = false }
            default: accountForm
            }
        }
    }

    private var accountForm: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Eng Pulse pilot").font(.title2.bold())
                    Text("Your daily engineering brief, with your own account.").foregroundStyle(.secondary)
                }
                switch model.phase {
                case .restoring, .admitted: EmptyView()
                case .signedOut: signIn
                case .needsInvite(let session):
                    Section("Join the pilot") {
                        accountLabel(session)
                        TextField("Invitation code", text: $invite)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("pilot.invite")
                        Button("Join engineering") { Task { await model.acceptInvite(invite) } }
                            .disabled(invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                    }
                case .waiting(let session):
                    Section("Finish connecting") {
                        accountLabel(session)
                        Text("You’re signed in. We still need to confirm your pilot access.")
                        Button("Try again") { Task { await model.restore() } }.disabled(model.isBusy)
                    }
                case .blocked(let session):
                    Section("Access unavailable") {
                        accountLabel(session)
                        Text("Contact the pilot administrator to restore access, or sign in with another account.")
                    }
                }
                if let message = model.errorMessage {
                    Section { Text(message).foregroundStyle(.red).accessibilityIdentifier("pilot.error") }
                }
                if model.isBusy { Section { ProgressView("Connecting…") } }
                if model.phase != .signedOut {
                    Section {
                        Button("Sign out", role: .destructive) {
                            code = ""; invite = ""; email = ""; appleNonce = nil
                            Task { await model.signOut() }
                        }.accessibilityIdentifier("pilot.signOut")
                    }
                }
            }
            .navigationTitle("Eng Pulse")
        }
        .onChange(of: model.phase) { _, phase in
            if phase != .signedOut { code = ""; invite = ""; appleNonce = nil }
        }
    }

    @ViewBuilder private var signIn: some View {
        Section("Sign in") {
            SignInWithAppleButton(.signIn, onRequest: prepareApple, onCompletion: finishApple)
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 48)
                .disabled(model.isBusy)
            if let sentTo = model.codeSentTo {
                Text("Enter the code sent to \(sentTo).")
                TextField("Email code", text: $code)
                    .textContentType(.oneTimeCode).keyboardType(.numberPad)
                    .accessibilityIdentifier("pilot.emailCode")
                Button("Continue") { Task { await model.verifyCode(email: sentTo, code: code) } }
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                Button("Send a new code") { Task { await model.sendCode(email: sentTo) } }
                    .disabled(model.isBusy)
                Button("Use another email") { code = ""; model.changeEmail() }.disabled(model.isBusy)
            } else {
                TextField("Email address", text: $email)
                    .textContentType(.emailAddress).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("pilot.email")
                Button("Email me a code") { Task { await model.sendCode(email: email) } }
                    .disabled(!email.contains("@") || model.isBusy)
            }
            Text("An invitation is required to join. Use the same sign-in method each time.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func accountLabel(_ session: PilotSession) -> some View {
        Text(session.identity.email ?? "Signed in with Apple").foregroundStyle(.secondary)
    }

    private func prepareApple(_ request: ASAuthorizationAppleIDRequest) {
        appleNonce = nil
        appleAttempt = model.beginAppleSignIn()
        guard appleAttempt != nil else { return }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            model.reportAppleError()
            return
        }
        let nonce = bytes.map { String(format: "%02x", $0) }.joined()
        appleNonce = nonce
        request.requestedScopes = [.email, .fullName]
        request.nonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func finishApple(_ result: Result<ASAuthorization, Error>) {
        let nonce = appleNonce
        let attempt = appleAttempt
        appleNonce = nil
        appleAttempt = nil
        guard let attempt else { return }
        switch result {
        case .success(let authorization):
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential
            let token = credential?.identityToken.flatMap { String(data: $0, encoding: .utf8) }
            Task { await model.completeAppleSignIn(idToken: token, nonce: nonce, attempt: attempt) }
        case .failure(let error):
            let cancelled = (error as? ASAuthorizationError)?.code == .canceled
            Task { await model.completeAppleSignIn(idToken: nil, nonce: nil, attempt: attempt, cancelled: cancelled) }
        }
    }
}
