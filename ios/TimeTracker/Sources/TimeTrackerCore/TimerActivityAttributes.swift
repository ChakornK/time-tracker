import ActivityKit
import Foundation

public struct TimerActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var startedAt: Date
        public var activityTitle: String
        /// The category's stored `#RRGGBB` color. Optional so activities started by an older build
        /// still decode.
        public var categoryColorHex: String?

        public init(startedAt: Date, activityTitle: String, categoryColorHex: String? = nil) {
            self.startedAt = startedAt
            self.activityTitle = activityTitle
            self.categoryColorHex = categoryColorHex
        }
    }

    public var timerID: UUID

    public init(timerID: UUID) {
        self.timerID = timerID
    }
}
