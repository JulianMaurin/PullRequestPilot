import SwiftUI

struct SettingsView<Dashboard: DashboardActionsProtocol>: View {
    @Bindable var viewModel: SettingsViewModel
    var dashboard: Dashboard
    var isInitialSetup: Bool = false
    var onDismiss: (() -> Void)?
    @State private var showResetConfirmation = false
    @State private var presetToReset: DashboardView?
    @State private var showSignOutConfirmation = false
    @State private var directoryToRemove: URL?
    var body: some View {
        Form {
            Section {
                if let login = viewModel.viewerLogin, !viewModel.isChangingToken {
                    LabeledContent {
                        HStack {
                            Button("Change Token…") {
                                viewModel.beginChangingToken()
                            }
                            Button("Sign Out", role: .destructive) {
                                showSignOutConfirmation = true
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            CachedAvatarView(
                                url: viewModel.viewerAvatarURL,
                                size: 28,
                                placeholder: AnyView(
                                    Image(systemName: "person.crop.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.green)
                                )
                            )
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
                                    dashboard.startAutoRefresh()
                                    viewModel.restartRepoScan()
                                    await dashboard.refreshAll()
                                }
                            }
                        }
                        .disabled(!viewModel.hasToken || viewModel.validationState == .validating)

                        if viewModel.isChangingToken {
                            Button("Cancel") {
                                viewModel.cancelChangingToken()
                            }
                            .disabled(viewModel.validationState == .validating)
                        }

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

                    if case .invalid(let message) = viewModel.validationState {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(message)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.caption)
                    }
                }
            } header: {
                Text("GitHub Token")
            } footer: {
                if viewModel.viewerLogin == nil || viewModel.isChangingToken {
                    Text("Create a token at github.com/settings/tokens with the `repo` scope.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .task(id: "token-validation") {
                if viewModel.hasSavedToken, viewModel.viewerLogin == nil, viewModel.validationState == .idle {
                    await viewModel.save()
                    if viewModel.validationState == .valid {
                        dashboard.startAutoRefresh()
                        viewModel.restartRepoScan()
                        await dashboard.refreshAll()
                    }
                }
            }

            Section {
                Toggle("Launch at Login", isOn: $viewModel.launchAtLogin)

                if let error = viewModel.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

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
                ForEach(DashboardView.presetViews) { preset in
                    presetRow(preset)
                }
            } header: {
                Text("Preset Views")
            } footer: {
                Text("A recommended workflow for staying on top of pull requests. Add what fits your needs — each view's query can be customized from the dashboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .alert("Reset View?", isPresented: $showResetConfirmation) {
                Button("Cancel", role: .cancel) { presetToReset = nil }
                Button("Reset") {
                    if let preset = presetToReset,
                       let existing = dashboard.views.first(where: { $0.title == preset.title }) {
                        dashboard.updateView(DashboardView(
                            id: existing.id,
                            title: preset.title,
                            query: preset.query,
                            hideReviewed: preset.hideReviewed
                        ))
                        Task { await dashboard.refresh(viewID: existing.id) }
                    }
                    presetToReset = nil
                }
            } message: {
                Text("This will reset \"\(presetToReset?.title ?? "")\" to its default query.")
            }

            Section {
                if !dashboard.systemNotificationsAuthorized {
                    LabeledContent {
                        Button("Open Settings") {
                            Task {
                                await dashboard.requestNotificationPermissionAndOpenSettings()
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
                } else {
                    SwiftUI.Label("System notifications are enabled.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Use the icons on each view's query bar to toggle notifications and new-PR tracking in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .task {
                await dashboard.refreshNotificationAuthorization()
                viewModel.refreshLaunchAtLoginStatus()
                for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                    await dashboard.refreshNotificationAuthorization()
                    viewModel.refreshLaunchAtLoginStatus()
                }
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
                            directoryToRemove = directory
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Remove directory")
                        .accessibilityLabel("Remove directory \(directory.lastPathComponent)")
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
                        .accessibilityLabel("Rescan repositories")
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Directories containing cloned repositories. Used to locate PRs on disk and open them in your editor.")
                    if let warning = viewModel.staleDirectoryWarning {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(warning)
                        }
                        .foregroundStyle(.orange)
                    }
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
        .confirmationDialog(
            "Sign out of GitHub?",
            isPresented: $showSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                dashboard.clearAllData()
                Task { await viewModel.clearToken() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear your GitHub token and remove all saved views, notifications, and badge settings. This cannot be undone.")
        }
        .confirmationDialog(
            "Remove this directory?",
            isPresented: Binding(
                get: { directoryToRemove != nil },
                set: { if !$0 { directoryToRemove = nil } }
            ),
            titleVisibility: .visible,
            presenting: directoryToRemove
        ) { directory in
            Button("Remove", role: .destructive) {
                viewModel.removeGitDirectory(directory)
                directoryToRemove = nil
            }
            Button("Cancel", role: .cancel) { directoryToRemove = nil }
        } message: { directory in
            Text("Pull Request Pilot will stop matching pull requests to repositories under \(directory.path).")
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

    private func presetRow(_ preset: DashboardView) -> some View {
        let existing = dashboard.views.first(where: { $0.title == preset.title })
        let isAdded = existing != nil
        let isModified = isAdded && existing?.query != preset.query

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isAdded ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isAdded ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                .font(.body)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(preset.title)
                    .fontWeight(isAdded ? .medium : .regular)
                Text(preset.query)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            if isAdded {
                Button("Reset") {
                    presetToReset = preset
                    showResetConfirmation = true
                }
                .controlSize(.small)
                .disabled(!isModified)
                .help(isModified ? "Reset query to preset default" : "Query matches preset")
            } else {
                Button("Add") {
                    let newView = DashboardView(
                        id: UUID(),
                        title: preset.title,
                        query: preset.query,
                        hideReviewed: preset.hideReviewed
                    )
                    dashboard.addView(newView)
                    Task { await dashboard.refresh(viewID: newView.id) }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
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
