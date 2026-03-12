import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                SecureField("Personal Access Token", text: $viewModel.token)
                    .textFieldStyle(.roundedBorder)

                Text("Create a token at github.com/settings/tokens with the `repo` scope.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Save & Validate") {
                        Task { await viewModel.save() }
                    }
                    .disabled(!viewModel.hasToken || viewModel.validationState == .validating)

                    if viewModel.hasToken {
                        Button("Clear", role: .destructive) {
                            viewModel.clearToken()
                        }
                    }

                    Spacer()

                    validationStatus
                }
            } header: {
                Text("GitHub Authentication")
            }

            if let login = viewModel.viewerLogin {
                Section {
                    LabeledContent("Authenticated as", value: login)
                } header: {
                    Text("Account")
                }
            }

            if let error = viewModel.saveError {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                } header: {
                    Text("Error")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450)
    }

    @ViewBuilder
    private var validationStatus: some View {
        switch viewModel.validationState {
        case .idle:
            EmptyView()
        case .validating:
            ProgressView()
                .controlSize(.small)
        case .valid:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .invalid(let message):
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .help(message)
        }
    }
}
