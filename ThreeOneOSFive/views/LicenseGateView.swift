import SwiftUI

/// Guarda localmente si la key ya fue validada, para no pedirla en cada apertura.
enum LicenseStore {
    private static let key = "argent.license.validated"

    static var isValidated: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

struct LicenseGateView: View {
    var onValidated: () -> Void

    @State private var licenseKey: String = ""
    @State private var isValidating = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            AppTheme.pageBackground.ignoresSafeArea()

            VStack(spacing: 20) {
                Image("ArgentLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 140, height: 140)
                    .padding(.bottom, 8)

                Text("Argent")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)

                Text("Ingresa tu license key para continuar")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))

                TextField("Key", text: $licenseKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding()
                    .background(AppTheme.consoleBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.top, 8)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Button {
                    validate()
                } label: {
                    if isValidating {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Entrar")
                            .bold()
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding()
                .background(AppTheme.accent)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 32)
                .padding(.top, 8)
                .disabled(isValidating || licenseKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func validate() {
        errorMessage = nil
        isValidating = true
        let trimmedKey = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                try await KeyAuthService.shared.validate(key: trimmedKey)
                await MainActor.run {
                    LicenseStore.isValidated = true
                    isValidating = false
                    onValidated()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isValidating = false
                }
            }
        }
    }
}