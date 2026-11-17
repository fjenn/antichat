// M8.T03 step 7 (R-246 AC1): the sidebar footer's review pill. With pending `memory_suggestion` rows (the facts the
// background MemoryReviewService was unsure about; certain ones it saves itself) it shows `memory.review.pill` "{count} new things to review"; a click opens
// Settings › Personalization, where the Suggestions cards hold [Save] / [Dismiss]. Hidden at 0 and on hosts without the
// app database (blocked launch, previews). The count follows a ValueObservation, so Save / Dismiss / a new run update it.
import AntiChatDesign
import AntiChatKnowledge
import AntiChatStorage
import GRDB
import SwiftUI

@MainActor @Observable
final class MemoryReviewPillModel {
    private(set) var count = 0
    @ObservationIgnored private var cancellable: AnyDatabaseCancellable?

    init(database: AppDatabase?) {
        guard let database else { return }
        // Constant region (no key filter): refetched on a reader, never inside the writer (AT-NFR-S3).
        cancellable = ValueObservation.trackingConstantRegion(Self.pendingCount)
            .removeDuplicates()
            .start(in: database.reader, scheduling: .mainActor, onError: { _ in }, onChange: { [weak self] in self?.count = $0 })
    }

    nonisolated static func pendingCount(_ db: Database) throws -> Int {
        try MemorySuggestion.filter(Column("state") == "pending").fetchCount(db)
    }
}

struct MemoryReviewPill: View {
    private let fixed: Int?
    @State private var model: MemoryReviewPillModel

    /// `fixed` pins the count (snapshot tests); nil follows the app database's pending suggestions.
    init(fixed: Int? = nil, database: AppDatabase? = MemoryNotice.store?.database) {
        self.fixed = fixed
        _model = State(initialValue: MemoryReviewPillModel(database: fixed == nil ? database : nil))
    }

    static func title(_ count: Int) -> CopyText? {
        count > 0 ? CopyText(CopyKey("memory.review.pill"), ["count": "\(count)"]) : nil
    }

    var body: some View {
        if let title = Self.title(fixed ?? model.count) {
            Button {
                SettingsNavigator.shared.request(.personalization)
                SettingsPresenter.shared.show()
            } label: {
                Label { Text(title).typeStyle(.caption) } icon: { Image(systemName: "brain") }
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, Spacing.space2)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.surfaceHover))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.space2)
            .padding(.bottom, Spacing.space1)
            .accessibilityIdentifier("memoryReviewPill")
            .probeID("memoryReviewPill")
        }
    }
}
