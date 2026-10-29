import SwiftUI

/// Edits a finished log, such as a timer left running too long or started under the wrong category.
struct LogEditorSheet: View {
    let categories: [APICategory]
    let onSave: (LogEdit) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var categoryID: UUID?
    @State private var startedAt: Date
    @State private var endedAt: Date
    @State private var visibility: ActivityVisibility
    @State private var notes: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    private let originalTitle: String

    init(log: LogEdit, categories: [APICategory], onSave: @escaping (LogEdit) async throws -> Void) {
        self.categories = categories
        self.onSave = onSave
        originalTitle = log.title
        // A deleted category drops out, leaving the log uncategorized until one is chosen.
        _categoryID = State(initialValue: log.categoryIDs.first { id in categories.contains { $0.id == id } })
        _startedAt = State(initialValue: log.startedAt)
        _endedAt = State(initialValue: log.endedAt)
        _visibility = State(initialValue: log.visibility)
        _notes = State(initialValue: log.notes ?? "")
    }

    private var duration: Int {
        max(0, Int(endedAt.timeIntervalSince(startedAt)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Category", selection: $categoryID) {
                        Text("No category").tag(UUID?.none)
                        ForEach(categories) { category in
                            Text(category.name).tag(Optional(category.id))
                        }
                    }
                }

                Section {
                    DatePicker("Started", selection: $startedAt, in: ...Date.now)
                    DatePicker("Ended", selection: $endedAt, in: startedAt...max(startedAt, Date.now))
                    LabeledContent("Duration") {
                        DurationText(duration)
                    }
                } header: {
                    Text("When")
                } footer: {
                    Text("Shorten the end time for a timer left running too long.")
                }

                Section("Visibility") {
                    Picker("Visibility", selection: $visibility) {
                        ForEach([ActivityVisibility.public, .friendsOnly, .private], id: \.self) { option in
                            Text(option.shortLabel).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section("Notes") {
                    TextField("Optional", text: $notes, axis: .vertical)
                        .lineLimit(1...6)
                }

                if let errorMessage {
                    Section {
                        StatusBanner(kind: .error, message: errorMessage)
                    }
                }
            }
            .navigationTitle("Edit log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving" : "Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving || endedAt < startedAt)
                }
            }
            // Moving the start past the end would leave an impossible range; pull the end along.
            .onChange(of: startedAt) { _, start in
                if endedAt < start { endedAt = start }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func save() async {
        let category = categories.first { $0.id == categoryID }
        let edit = LogEdit(
            title: category?.name ?? originalTitle,
            notes: LogNotes.cleaned(notes),
            startedAt: startedAt,
            endedAt: endedAt,
            categoryIDs: category.map { [$0.id] } ?? [],
            visibility: visibility
        )
        isSaving = true
        defer { isSaving = false }
        do {
            try await onSave(edit)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
