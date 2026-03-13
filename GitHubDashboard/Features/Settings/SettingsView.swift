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
                Text("GitHub Token")
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
                Toggle("Launch at Login", isOn: $viewModel.launchAtLogin)
            } header: {
                Text("General")
            }

            Section {
                ForEach(viewModel.gitDirectories, id: \.self) { directory in
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(directory.path)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Button {
                            viewModel.removeGitDirectory(directory)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button("Add Directory...") {
                    viewModel.addGitDirectory()
                }
            } header: {
                HStack {
                    Text("Git Directories")
                    Spacer()
                    if viewModel.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    } else if !viewModel.gitDirectories.isEmpty {
                        Button {
                            viewModel.rescan()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Rescan repositories")
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Directories containing cloned repositories. Used to locate PRs on disk and open them in your editor.")
                    scanStatus
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 450, minHeight: 250)
    }

    @ViewBuilder
    private var scanStatus: some View {
        if viewModel.isScanning {
            Text("Scanning...")
        } else if let lastScan = viewModel.lastScanDate {
            let count = viewModel.indexedRepoCount
            Text("\(count) repo\(count == 1 ? "" : "s") indexed — last scan \(lastScan, format: .relative(presentation: .named))")
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
