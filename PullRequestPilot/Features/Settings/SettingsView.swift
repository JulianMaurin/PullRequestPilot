import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    var dashboardViewModel: DashboardViewModel
    var isInitialSetup: Bool = false
    var onDismiss: (() -> Void)?
    @State private var showPresetConflictAlert = false
    @State private var presetConflictNames: [String] = []

    var body: some View {
        Form {
            Section {
                if let login = viewModel.viewerLogin {
                    LabeledContent {
                        Button("Sign Out", role: .destructive) {
                            dashboardViewModel.clearAllData()
                            viewModel.clearToken()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            AsyncImage(url: viewModel.viewerAvatarURL) { image in
                                image
                                    .resizable()
                                    .scaledToFill()
                            } placeholder: {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.green)
                            }
                            .frame(width: 28, height: 28)
                            .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(login)
                                    .fontWeight(.medium)
                                Text("Connected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    SecureField("Personal Access Token", text: $viewModel.token)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("Save & Validate") {
                            Task {
                                await viewModel.save()
                                if viewModel.validationState == .valid {
                                    dashboardViewModel.startAutoRefresh()
                                    await dashboardViewModel.refreshAll()
                                }
                            }
                        }
                        .disabled(!viewModel.hasToken || viewModel.validationState == .validating)

                        Spacer()

                        validationStatus
                    }

                    if let error = viewModel.saveError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(error)
                                .foregroundStyle(.red)
                        }
                        .font(.caption)
                    }
                }
            } header: {
                Text("GitHub Token")
            } footer: {
                if viewModel.viewerLogin == nil {
                    Text("Create a token at github.com/settings/tokens with the `repo` scope.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .task {
                if viewModel.hasSavedToken, viewModel.viewerLogin == nil {
                    await viewModel.save()
                    if viewModel.validationState == .valid {
                        dashboardViewModel.startAutoRefresh()
                        await dashboardViewModel.refreshAll()
                    }
                }
            }

            Section {
                Toggle("Launch at Login", isOn: $viewModel.launchAtLogin)

                Picker("Pull request refresh", selection: $viewModel.prRefreshInterval) {
                    ForEach(SettingsViewModel.refreshIntervalOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }

                Picker("Repository scan", selection: $viewModel.repoScanInterval) {
                    ForEach(SettingsViewModel.refreshIntervalOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
            } header: {
                Text("General")
            }

            Section {
                Button("Create Preset Views") {
                    let conflicts = dashboardViewModel.presetConflicts()
                    if conflicts.isEmpty {
                        dashboardViewModel.createPresetViews(replacingConflicts: false)
                        Task { await dashboardViewModel.refreshAll() }
                    } else {
                        presetConflictNames = conflicts
                        showPresetConflictAlert = true
                    }
                }
            } header: {
                Text("Views")
            } footer: {
                let names = DashboardView.presetViews.map(\.title).joined(separator: ", ")
                Text("Creates \(names) views to get you started quickly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if !dashboardViewModel.systemNotificationsAuthorized {
                    LabeledContent {
                        Button("Open Settings") {
                            Task {
                                await dashboardViewModel.requestNotificationPermissionAndOpenSettings()
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Notifications are disabled in System Settings.")
                                .foregroundStyle(.primary)
                        }
                    }
                }
                if dashboardViewModel.views.isEmpty {
                    Text("No views configured yet.")
                        .foregroundStyle(.secondary)
                } else {
                    let disabled = !dashboardViewModel.systemNotificationsAuthorized
                    ForEach(dashboardViewModel.views) { view in
                        Toggle(view.title, isOn: Binding(
                            get: { dashboardViewModel.isNotificationEnabled(for: view.id) },
                            set: { _ in Task { await dashboardViewModel.toggleNotification(for: view.id) } }
                        ))
                        .foregroundStyle(disabled ? .tertiary : .primary)
                        .disabled(disabled)
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Get notified when new pull requests appear in a view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .task {
                await dashboardViewModel.refreshNotificationAuthorization()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await dashboardViewModel.refreshNotificationAuthorization() }
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
            Section {
                LabeledContent("Version") {
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
                    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
                    Text("\(version) (\(build))")
                        .foregroundStyle(.secondary)
                }
                Link("Privacy Policy", destination: Constants.URLs.privacyPolicy)
                Link("Support & Feedback", destination: Constants.URLs.support)
            } header: {
                Text("About")
            }

            if isInitialSetup && viewModel.validationState == .valid {
                Section {
                    Button {
                        onDismiss?()
                    } label: {
                        Text("Get Started")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 450, minHeight: 250)
        .alert("Replace Existing Views?", isPresented: $showPresetConflictAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Replace") {
                dashboardViewModel.createPresetViews(replacingConflicts: true)
                Task { await dashboardViewModel.refreshAll() }
            }
        } message: {
            let names = presetConflictNames.map { "\"\($0)\"" }.joined(separator: ", ")
            Text("The following views already exist and will be replaced: \(names).")
        }
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
