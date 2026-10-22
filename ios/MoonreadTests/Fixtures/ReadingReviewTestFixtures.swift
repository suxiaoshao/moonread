import UIKit
import XCTest

@testable import Moonread

@MainActor final class ReviewTestTime { var elapsed: TimeInterval = 0 }

class ReadingReviewFixture: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  var days: [StatisticsDay] {
    [10, 11, 13].map { StatisticsDay(day: $0, durationMs: 1, bookCount: 1) }
  }

}
