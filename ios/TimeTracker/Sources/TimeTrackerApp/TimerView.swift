import SwiftUI

struct TimerView: View {
    @Bindable var model: TimerHomeModel
    @State private var isShowingManualLog = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Time Tracker")
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                if let timer = model.runningTimer {
                    runningTimerCard(timer)
                } else {
                    startTimerCard
                }

                manualLogCard

                if let duration = model.lastSavedDurationSeconds {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            "Saved \(DurationFormat.compact(duration)) on this device",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                        .accessibilityLabel("Saved \(DurationFormat.spoken(duration)) on this device")
                        if model.pendingLogCount > 0 {
                            Text("It will appear in your recorded totals after syncing.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            syncButton
                        }
                    }
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let state = model.activityState {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Live Activity preview")
                            .font(.headline)
                        LiveTimerLockScreenView(state: state)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    }
                }

                if model.pendingLogCount > 0 && model.lastSavedDurationSeconds == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(model.pendingLogCount) saved logs waiting to sync")
                            .font(.subheadline)
                        syncButton
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
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

    private var manualLogCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Forgot to start a timer?")
                .font(.headline)
            Text("Add time you've already spent on a category.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                isShowingManualLog = true
            } label: {
                Label("Log time manually", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(model.categories.categories.isEmpty)
        }
        .cardStyle()
        .sheet(isPresented: $isShowingManualLog) {
            ManualLogSheet(model: model)
        }
    }

    private var syncButton: some View {
        Button(model.syncInProgress ? "Syncing" : "Sync now") {
            Task { await model.synchronize() }
        }
        .disabled(model.syncInProgress)
        .frame(minHeight: 44)
    }

    private func runningTimerCard(_ timer: RunningTimer) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Timer running")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(model.categories.category(withID: timer.categoryIDs.first)?.name ?? timer.title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            TimelineView(.periodic(from: timer.startedAt, by: 1)) { context in
                Text(Duration.seconds(timer.elapsedSeconds(at: context.date)), format: .time(pattern: .hourMinuteSecond))
                    .font(.system(size: 44, weight: .regular, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .accessibilityLabel("Elapsed time")
            }
            HStack(spacing: 8) {
                Text(timer.visibility.label)
                let categoryNames = timer.categoryIDs.compactMap { model.categories.category(withID: $0)?.name }
                if !categoryNames.isEmpty {
                    Text("·")
                    Text(categoryNames.joined(separator: ", "))
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Button {
                Task { await model.stop() }
            } label: {
                Label("Stop and save", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
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
            } else {
                Picker("Category", selection: $model.selectedCategoryID) {
                    Text("Choose a category").tag(UUID?.none)
                    ForEach(model.categories.categories) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .accessibilityLabel("Activity category")
            }

            HStack(spacing: 10) {
                TextField("Add a category", text: $model.newCategoryName)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit { Task { await model.addCategory() } }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))

                Button(model.categories.isCreating ? "Adding" : "Add") {
                    Task { await model.addCategory() }
                }
                .frame(minWidth: 56, minHeight: 44)
                .disabled(!model.canAddCategory)
            }

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
            .buttonStyle(.borderedProminent)
            .disabled(!model.canStart)
        }
        .cardStyle()
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
