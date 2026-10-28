import SwiftUI

/// Creates a goal, or changes the target of an existing one.
struct GoalEditorSheet: View {
    let goals: GoalStore
    let categories: [APICategory]
    private let editing: APIGoal?
    @Environment(\.dismiss) private var dismiss
    @State private var period: GoalPeriod
    @State private var categoryID: UUID?
    @State private var hours: Int
    @State private var minutes: Int
    @State private var errorMessage: String?

    init(goals: GoalStore, categories: [APICategory], editing: APIGoal? = nil) {
        self.goals = goals
        self.categories = categories
        self.editing = editing
        let period = editing?.period ?? .week
        _period = State(initialValue: period)
        _categoryID = State(initialValue: editing?.categoryId
            ?? categories.first { goals.goal(for: $0.id, period: period) == nil }?.id)
        let target = editing?.targetSeconds ?? 5 * 3_600
        _hours = State(initialValue: target / 3_600)
        _minutes = State(initialValue: (target % 3_600) / 60)
    }

    private var maximumHours: Int {
        period.maximumSeconds / 3_600
    }

    /// Five-minute steps, plus an existing goal's own minute value so editing never changes it silently.
    private var minuteValues: [Int] {
        Set(stride(from: 0, to: 60, by: 5)).union([minutes]).sorted()
    }

    private var targetSeconds: Int {
        hours * 3_600 + minutes * 60
    }

    /// Categories that don't already have a goal for the chosen period.
    private var availableCategories: [APICategory] {
        guard editing == nil else { return categories }
        return categories.filter { goals.goal(for: $0.id, period: period) == nil }
    }

    private var targetProblem: String? {
        if targetSeconds == 0 { return "Set a target above zero." }
        if targetSeconds > period.maximumSeconds {
            return "A \(period.adjective.lowercased()) goal can be at most \(maximumHours) hours."
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Time horizon") {
                    Picker("Time horizon", selection: $period) {
                        ForEach(GoalPeriod.allCases) { period in
                            Text(period.adjective).tag(period)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(editing != nil)
                }

                Section {
                    if availableCategories.isEmpty {
                        Text("Every category already has a \(period.adjective.lowercased()) goal.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Category", selection: $categoryID) {
                            Text("Choose a category").tag(UUID?.none)
                            ForEach(availableCategories) { category in
                                Text(category.name).tag(Optional(category.id))
                            }
                        }
                        .disabled(editing != nil)
                    }
                }

                Section {
                    HStack(spacing: 0) {
                        durationWheel("Hours", selection: $hours, values: Array(0...maximumHours), unit: "hr")
                        durationWheel("Minutes", selection: $minutes, values: minuteValues, unit: "min")
                    }
                    .frame(height: 130)
                } header: {
                    Text("Time commitment")
                } footer: {
                    Text("Counts time logged \(period.windowDescription).")
                }

                if let message = errorMessage ?? targetProblem {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(editing == nil ? "New goal" : "Edit goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(goals.isSaving ? "Saving" : "Save") {
                        Task { await save() }
                    }
                    .disabled(categoryID == nil || targetProblem != nil || goals.isSaving)
                }
            }
            .onChange(of: period) {
                errorMessage = nil
                hours = min(hours, maximumHours)
                if !availableCategories.contains(where: { $0.id == categoryID }) {
                    categoryID = availableCategories.first?.id
                }
            }
        }
    }

    private func durationWheel(_ title: String, selection: Binding<Int>, values: [Int], unit: String) -> some View {
        Picker(title, selection: selection) {
            ForEach(values, id: \.self) { value in
                Text("\(value) \(unit)").tag(value)
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        // Side-by-side wheels otherwise overlap each other's touch areas.
        .clipped()
        .contentShape(Rectangle())
    }

    private func save() async {
        errorMessage = nil
        do {
            if let editing {
                try await goals.update(editing, targetSeconds: targetSeconds)
            } else if let categoryID {
                try await goals.create(categoryID: categoryID, period: period, targetSeconds: targetSeconds)
            }
            dismiss()
        } catch GoalClientError.duplicateGoal {
            errorMessage = "This category already has a \(period.adjective.lowercased()) goal."
        } catch {
            errorMessage = "The goal could not be saved. Check your connection and try again."
        }
    }
}
