import ActivityKit
import Foundation

public struct TimerActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var startedAt: Date
        public var activityTitle: String
        /// The category's stored `#RRGGBB` color. Optional so activities started by an older build
        /// still decode.
        public var categoryColorHex: String?
        /// When the current pause began. Optional, with `pausedSeconds`, so older activities still decode.
        public var pausedAt: Date?
        public var pausedSeconds: Double?

        public init(
            startedAt: Date,
            activityTitle: String,
            categoryColorHex: String? = nil,
            pausedAt: Date? = nil,
            pausedSeconds: Double? = nil
        ) {
            self.startedAt = startedAt
            self.activityTitle = activityTitle
            self.categoryColorHex = categoryColorHex
            self.pausedAt = pausedAt
            self.pausedSeconds = pausedSeconds
        }

        public var isPaused: Bool { pausedAt != nil }
    }

    public var timerID: UUID

    public init(timerID: UUID) {
        self.timerID = timerID
    }
}
