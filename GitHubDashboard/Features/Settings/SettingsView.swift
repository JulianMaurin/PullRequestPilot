import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    private enum Tab: String, CaseIterable {
        case views = "Views"
        case authentication = "Authentication"
    }

    @State private var selectedTab: Tab = .views
    @State private var editingViewID: UUID?
    @State private var isAddingView = false
    @State private var newViewTitle = ""
    @State private var newViewQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            settingsTabs
            Divider()
            switch selectedTab {
            case .views:
                viewsTab
            case .authentication:
                authenticationTab
            }
        }
        .frame(minWidth: 500, minHeight: 300)
        .onChange(of: viewModel.editableViews) {
            viewModel.saveViews()
        }
    }

    // MARK: - Tabs

    private var settingsTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    let isSelected = tab == selectedTab
                    Button {
                        selectedTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Views Tab

    private var viewsTab: some View {
        VStack(spacing: 0) {
            List {
                ForEach($viewModel.editableViews) { $view in
                    viewRow(view: $view)
                }
                .onMove { source, destination in
                    viewModel.editableViews.move(fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    viewModel.deleteView(at: offsets)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            Divider()

            HStack {
                Button {
                    newViewTitle = ""
                    newViewQuery = ""
                    isAddingView = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Add View")
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .sheet(isPresented: $isAddingView) {
                    addViewSheet
                }

                Spacer()

                Text("Drag to reorder")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func viewRow(view: Binding<DashboardView>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text(view.wrappedValue.title)
                    .font(.headline)
                    .lineLimit(1)

                Text(view.wrappedValue.query)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                editingViewID = view.wrappedValue.id
            } label: {
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Button {
                viewModel.deleteView(id: view.wrappedValue.id)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: Binding(
                get: { editingViewID == view.wrappedValue.id },
                set: { if !$0 { editingViewID = nil } }
            )) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Edit View")
                        .font(.headline)

                    TextField("Title", text: view.title)
                        .textFieldStyle(.roundedBorder)

                    TextField("GitHub search query", text: view.query)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                }
                .padding()
                .frame(width: 320)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    // MARK: - Add View Sheet

    private var newViewIsValid: Bool {
        !newViewTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !newViewQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var addViewSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New View")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Title")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("e.g. Review Requests", text: $newViewTitle)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Query")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("e.g. is:pr is:open review-requested:@me", text: $newViewQuery)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    isAddingView = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    viewModel.addView(title: newViewTitle, query: newViewQuery)
                    isAddingView = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!newViewIsValid)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    // MARK: - Authentication Tab

    private var authenticationTab: some View {
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
        }
        .formStyle(.grouped)
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
