import SwiftUI

@MainActor
@Observable
final class ProfileAndCategoriesModel {
    enum Operation {
        case load
        case createCategory
        case renameCategory(APICategory, String)
        case deleteCategory(APICategory)
        case deleteGoal(APIGoal)

        var retryTitle: String {
            switch self {
            case .load: "Retry loading"
            case .createCategory: "Retry adding category"
            case .renameCategory: "Retry renaming category"
            case .deleteCategory: "Retry deleting category"
            case .deleteGoal: "Retry deleting goal"
            }
        }
    }

    let categories: CategoryStore
    let goals: GoalStore
    private let isCategoryAwaitingSync: (UUID) -> Bool
    private let onCategoryDeleted: (UUID) -> Void
    private(set) var failedOperation: Operation?
    private(set) var errorMessage: String?
    private(set) var successMessage: String?
    var categoryName = ""

    init(
        categories: CategoryStore,
        goals: GoalStore,
        isCategoryAwaitingSync: @escaping (UUID) -> Bool,
        onCategoryDeleted: @escaping (UUID) -> Void
    ) {
        self.categories = categories
        self.goals = goals
        self.isCategoryAwaitingSync = isCategoryAwaitingSync
        self.onCategoryDeleted = onCategoryDeleted
    }

    /// Checked before confirming and again before deleting, since a timer can start in between.
    func canDelete(_ category: APICategory) -> Bool {
        guard !isCategoryAwaitingSync(category.id) else {
            beginOperation()
            errorMessage = "\(category.name) is used by a running timer or a log that hasn't synced yet. Stop the timer and let logs sync, then try again."
            return false
        }
        return true
    }

    var isBusy: Bool {
        categories.isLoading || categories.isCreating || goals.isLoading || goals.isSaving
    }

    var canAddCategory: Bool {
        !categories.isCreating && !trimmedCategoryName.isEmpty
    }

    private var trimmedCategoryName: String {
        categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func load() async {
        beginOperation()
        do {
            try await categories.reload()
            try await goals.reload()
        } catch {
            fail(.load, "Goals and categories could not be loaded. Check your connection and try again.")
        }
    }

    func addCategory() async {
        let name = trimmedCategoryName
        guard !name.isEmpty else {
            errorMessage = "Enter a category name."
            return
        }
        beginOperation()
        do {
            _ = try await categories.create(named: name)
            categoryName = ""
            successMessage = "Category added."
        } catch ProfileClientError.duplicateCategory {
            fail(.createCategory, "A category with that name already exists.")
        } catch {
            fail(.createCategory, "Category could not be added. Check your connection and try again.")
        }
    }

    func rename(_ category: APICategory, to newName: String) async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != category.name else { return }
        beginOperation()
        do {
            try await categories.rename(category, to: name)
            successMessage = "Category renamed."
        } catch ProfileClientError.duplicateCategory {
            fail(.renameCategory(category, name), "A category with that name already exists.")
        } catch {
            fail(.renameCategory(category, name), "Category could not be renamed. Check your connection and try again.")
        }
    }

    func delete(_ category: APICategory) async {
        guard canDelete(category) else { return }
        beginOperation()
        do {
            try await categories.delete(category)
            onCategoryDeleted(category.id)
            successMessage = "Category deleted."
        } catch {
            fail(.deleteCategory(category), "Category could not be deleted. Check your connection and try again.")
        }
    }

    func delete(_ goal: APIGoal) async {
        beginOperation()
        do {
            try await goals.delete(goal)
        } catch {
            fail(.deleteGoal(goal), "Goal could not be deleted. Check your connection and try again.")
        }
    }

    func retryFailedOperation() async {
        switch failedOperation {
        case .load: await load()
        case .createCategory: await addCategory()
        case .renameCategory(let category, let name): await rename(category, to: name)
        case .deleteCategory(let category): await delete(category)
        case .deleteGoal(let goal): await delete(goal)
        case nil: break
        }
    }

    private func beginOperation() {
        errorMessage = nil
        successMessage = nil
        failedOperation = nil
    }

    private func fail(_ operation: Operation, _ message: String) {
        failedOperation = operation
        errorMessage = message
    }
}

struct ProfileAndCategoriesView: View {
    private enum GoalSheet: Identifiable {
        case create
        case edit(APIGoal)

        var id: String {
            switch self {
            case .create: "create"
            case .edit(let goal): goal.id.uuidString
            }
        }
    }

    let user: APIUser
    let logs: [LocalActivityLog]
    @State private var model: ProfileAndCategoriesModel
    @State private var goalSheet: GoalSheet?
    @State private var renamingCategory: APICategory?
    @State private var renameText = ""
    @State private var deletingCategory: APICategory?

    init(
        user: APIUser,
        logs: [LocalActivityLog],
        categories: CategoryStore,
        goals: GoalStore,
        isCategoryAwaitingSync: @escaping (UUID) -> Bool,
        onCategoryDeleted: @escaping (UUID) -> Void
    ) {
        self.user = user
        self.logs = logs
        _model = State(initialValue: ProfileAndCategoriesModel(
            categories: categories,
            goals: goals,
            isCategoryAwaitingSync: isCategoryAwaitingSync,
            onCategoryDeleted: onCategoryDeleted
        ))
    }

    var body: some View {
        let colors = CategoryColorResolver(categories: model.categories.categories)
        let summaryLogs = logs.map(\.productivitySummaryLog)

        Form {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.displayName)
                        .font(.title3.weight(.semibold))
                    Text("@\(user.username)")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Goals") {
                if model.goals.isLoading && model.goals.goals.isEmpty {
                    ProgressView("Loading goals")
                } else if model.goals.goals.isEmpty {
                    Text("Set a goal for how much time you want to spend on a category each day, week, or month.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.goals.goals) { goal in
                        Button {
                            goalSheet = .edit(goal)
                        } label: {
                            // Inside the row so each goal stays its own Form row; re-evaluates each
                            // minute so goals reset when their day, week, or month ends.
                            TimelineView(.everyMinute) { context in
                                GoalProgressRow(
                                    progress: GoalProgress(goal: goal, logs: summaryLogs, now: context.date),
                                    series: colors.series(for: goal.categoryId)
                                )
                            }
                        }
                        .tint(.primary)
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { await model.delete(goal) }
                            }
                            Button("Edit", systemImage: "pencil") {
                                goalSheet = .edit(goal)
                            }
                            .tint(.orange)
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") {
                                goalSheet = .edit(goal)
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { await model.delete(goal) }
                            }
                        }
                    }
                }
                Button("Add goal", systemImage: "plus") {
                    goalSheet = .create
                }
                .frame(minHeight: 44)
                .disabled(model.categories.categories.isEmpty)
            }

            Section("Categories") {
                if model.categories.isLoading && model.categories.categories.isEmpty {
                    ProgressView("Loading categories")
                } else if model.categories.categories.isEmpty {
                    ContentUnavailableView(
                        "No categories yet",
                        systemImage: "tag",
                        description: Text("Add a category to organize your activity.")
                    )
                } else {
                    ForEach(model.categories.categories) { category in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color(hex: category.colorHex))
                                .frame(width: 12, height: 12)
                                .accessibilityHidden(true)
                            Text(category.name)
                        }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                requestDeletion(of: category)
                            }
                            Button("Rename", systemImage: "pencil") {
                                beginRenaming(category)
                            }
                            .tint(.orange)
                        }
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") {
                                beginRenaming(category)
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                requestDeletion(of: category)
                            }
                        }
                    }
                }
                HStack(spacing: 12) {
                    TextField("Category name", text: $model.categoryName)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit { Task { await model.addCategory() } }
                    Button(model.categories.isCreating ? "Adding" : "Add") {
                        Task { await model.addCategory() }
                    }
                    .frame(minWidth: 52, minHeight: 44)
                    .disabled(!model.canAddCategory)
                }
            }

            if let successMessage = model.successMessage {
                Section {
                    Label(successMessage, systemImage: "checkmark.circle")
                }
            }
            if let errorMessage = model.errorMessage {
                Section("Could not complete action") {
                    Text(errorMessage)
                    if let operation = model.failedOperation {
                        Button(operation.retryTitle) {
                            Task { await model.retryFailedOperation() }
                        }
                        .frame(minHeight: 44)
                        .disabled(model.isBusy)
                    }
                }
            }
        }
        .navigationTitle("Profile")
        .task { await model.load() }
        .alert("Rename category", isPresented: isRenaming, presenting: renamingCategory) { category in
            TextField("Category name", text: $renameText)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                Task { await model.rename(category, to: renameText) }
            }
        }
        .confirmationDialog(
            deletingCategory.map { "Delete \($0.name)?" } ?? "",
            isPresented: isConfirmingDeletion,
            titleVisibility: .visible,
            presenting: deletingCategory
        ) { category in
            Button("Delete category", role: .destructive) {
                Task { await model.delete(category) }
            }
        } message: { _ in
            Text("Its goals are deleted too. Logged time is kept but no longer belongs to a category.")
        }
        .sheet(item: $goalSheet) { sheet in
            switch sheet {
            case .create:
                GoalEditorSheet(goals: model.goals, categories: model.categories.categories)
            case .edit(let goal):
                GoalEditorSheet(goals: model.goals, categories: model.categories.categories, editing: goal)
            }
        }
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renamingCategory != nil }, set: { if !$0 { renamingCategory = nil } })
    }

    private var isConfirmingDeletion: Binding<Bool> {
        Binding(get: { deletingCategory != nil }, set: { if !$0 { deletingCategory = nil } })
    }

    private func beginRenaming(_ category: APICategory) {
        renameText = category.name
        renamingCategory = category
    }

    private func requestDeletion(of category: APICategory) {
        if model.canDelete(category) {
            deletingCategory = category
        }
    }
}

private extension Color {
    /// Parses `#RRGGBB`; malformed values render black.
    init(hex: String) {
        let value = UInt64(hex.dropFirst(), radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
