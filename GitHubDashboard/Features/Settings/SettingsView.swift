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

            Section {
                ForEach($viewModel.editableViews) { $view in
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Title", text: $view.title)
                            .textFieldStyle(.roundedBorder)
                        TextField("Query (e.g. is:pr is:open author:@me)", text: $view.query)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { offsets in
                    viewModel.deleteView(at: offsets)
                }

                Button("Add View") {
                    viewModel.addView()
                }
            } header: {
                Text("Dashboard Views")
            } footer: {
                Text("Each view runs its own GitHub search query. Uses the same syntax as github.com search.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450)
        .onChange(of: viewModel.editableViews) {
            viewModel.saveViews()
        }
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
