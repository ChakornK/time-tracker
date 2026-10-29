import SwiftUI

struct TimerView: View {
    @Bindable var model: TimerHomeModel
    @State private var isShowingManualLog = false
    @State private var isAddingCategory = false
    @State private var isEditingNotes = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let timer = model.runningTimer {
                    runningTimerCard(timer)
                } else {
                    startTimerCard
                }

                if let duration = model.lastSavedDurationSeconds {
                    StatusBanner(
                        kind: .success,
                        message: "Saved \(DurationFormat.compact(duration)).",
                        spokenMessage: "Saved \(DurationFormat.spoken(duration))."
                    )
                    .cardStyle()
                }

                if let errorMessage = model.errorMessage {
                    StatusBanner(kind: .error, message: errorMessage)
                        .cardStyle()
                }

                if model.pendingLogCount > 0 {
                    StatusBanner(
                        kind: .pending,
                        message: model.pendingLogCount == 1
                            ? "1 log is saved on this device and waiting to sync."
                            : "\(model.pendingLogCount) logs are saved on this device and waiting to sync.",
                        actionTitle: model.syncInProgress ? "Syncing" : "Sync now",
                        isActionDisabled: model.syncInProgress
                    ) {
                        Task { await model.synchronize() }
                    }
                    .cardStyle()
                }

                #if DEBUG
                if let state = model.activityState {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Live Activity preview")
                            .font(.headline)
                        LiveTimerLockScreenView(state: state)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                #endif
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Timer")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Log time manually", systemImage: "plus") {
                    isShowingManualLog = true
                }
                .disabled(model.categories.categories.isEmpty)
            }
        }
        .sheet(isPresented: $isShowingManualLog) {
            ManualLogSheet(model: model)
        }
        .sheet(isPresented: $isEditingNotes) {
            TimerNotesSheet(notes: model.runningTimer?.notes ?? "") { notes in
                model.updateNotes(notes)
            }
        }
        .alert("New category", isPresented: $isAddingCategory) {
            TextField("Category name", text: $model.newCategoryName)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {
                model.newCategoryName = ""
            }
            Button("Add") {
                Task { await model.addCategory() }
            }
            .disabled(model.newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(
            "Timer could not be saved",
            isPresented: Binding(
                get: { model.stopFailureMessage != nil },
                set: { if !$0 { model.stopFailureMessage = nil } }
            ),
            presenting: model.stopFailureMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private func runningTimerCard(_ timer: RunningTimer) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Timer running")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Group {
                if let category = model.categories.category(withID: timer.categoryIDs.first) {
                    CategoryLabel(category: category)
                } else {
                    Text(timer.title)
                }
            }
            .font(.title2.weight(.semibold))
            TimelineView(.periodic(from: timer.startedAt, by: 1)) { context in
                Text(Duration.seconds(timer.elapsedSeconds(at: context.date)), format: .time(pattern: .hourMinuteSecond))
                    .font(.system(size: 44, weight: .regular, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .accessibilityLabel("Elapsed time")
            }
            Label(timer.visibility.label, systemImage: timer.visibility.symbol)
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                if let notes = timer.notes {
                    Text(notes)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(timer.notes == nil ? "Add notes" : "Edit notes", systemImage: "note.text") {
                    isEditingNotes = true
                }
                .font(.subheadline)
                .frame(minHeight: 44)
            }

            Button {
                Task { await model.stop() }
            } label: {
                Label("Stop and save", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .primaryActionStyle()
        }
        .cardStyle()
    }

    private var startTimerCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose an activity")
                .font(.headline)

            if model.categories.categories.isEmpty {
                Text("Add a category to get started, such as a course, reading, exercise, or project.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Wraps onto new rows so every category stays in view, however many there are.
            FlowLayout(spacing: 8) {
                ForEach(model.categories.categories) { category in
                    categoryChip(category)
                }
                Button {
                    isAddingCategory = true
                } label: {
                    Label("New category", systemImage: "plus")
                        .font(.subheadline)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .overlay(Capsule().strokeBorder(Color(uiColor: .separator), style: StrokeStyle(lineWidth: 1, dash: [4])))
                }
                .buttonStyle(.plain)
                .disabled(model.categories.isCreating)
            }

            TextField("Notes (optional)", text: $model.timerNotes, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))

            Picker("Visibility", selection: $model.visibility) {
                ForEach([ActivityVisibility.public, .friendsOnly, .private], id: \.self) { visibility in
                    Text(visibility.shortLabel).tag(visibility)
                }
            }
            .pickerStyle(.segmented)

            Button {
                Task { await model.start() }
            } label: {
                Label("Start timer", systemImage: "record.circle")
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .primaryActionStyle()
            .disabled(!model.canStart)
        }
        .cardStyle()
    }

    private func categoryChip(_ category: APICategory) -> some View {
        let isSelected = model.selectedCategoryID == category.id
        return Button {
            model.selectedCategoryID = category.id
        } label: {
            // One weight for both states, so selecting a chip never widens it onto the next row.
            CategoryLabel(category: category)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(isSelected ? Color(uiColor: .tertiarySystemFill) : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? Color.primary : Color(uiColor: .separator), lineWidth: isSelected ? 2 : 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Edits the running timer's notes. Changes are kept only when saved.
private struct TimerNotesSheet: View {
    @State private var notes: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    init(notes: String, onSave: @escaping (String) -> Void) {
        _notes = State(initialValue: notes)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("What are you working on?", text: $notes, axis: .vertical)
                    .lineLimit(4...12)
            }
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(notes)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

extension ActivityVisibility {
    var label: String {
        switch self {
        case .public: "Public"
        case .private: "Private"
        case .friendsOnly: "Friends only"
        }
    }

    var shortLabel: String {
        self == .friendsOnly ? "Friends" : label
    }
}
