// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

nonisolated public struct StatisticsWidgetQuery: GraphQLQuery {
  public static let operationName: String = "StatisticsWidget"
  public static let operationDocument: ApolloAPI.OperationDocument = .init(
    definition: .init(
      #"query StatisticsWidget($today: Int64!, $weekStart: Int64!) { statisticsWidget(today: $today, weekStart: $weekStart) { __typename hasReadingHistory todayDurationMs weekDurationMs streakDays days { __typename day durationMs bookCount } } }"#
    ))

  public var today: Int64
  public var weekStart: Int64

  public init(
    today: Int64,
    weekStart: Int64
  ) {
    self.today = today
    self.weekStart = weekStart
  }

  @_spi(Unsafe) public var __variables: Variables? { [
    "today": today,
    "weekStart": weekStart
  ] }

  nonisolated public struct Data: MoonreadQueries.SelectionSet {
    @_spi(Unsafe) public let __data: DataDict
    @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

    @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.Query }
    @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
      .field("statisticsWidget", StatisticsWidget.self, arguments: [
        "today": .variable("today"),
        "weekStart": .variable("weekStart")
      ]),
    ] }
    @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      StatisticsWidgetQuery.Data.self
    ] }

    public var statisticsWidget: StatisticsWidget { __data["statisticsWidget"] }

    public init(
      statisticsWidget: StatisticsWidget
    ) {
      self.init(unsafelyWithData: [
        "__typename": MoonreadQueries.Objects.Query.typename,
        "statisticsWidget": statisticsWidget._fieldData,
      ])
    }

    /// StatisticsWidget
    ///
    /// Parent Type: `ReadingStatisticsWidget`
    nonisolated public struct StatisticsWidget: MoonreadQueries.SelectionSet {
      @_spi(Unsafe) public let __data: DataDict
      @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

      @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.ReadingStatisticsWidget }
      @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
        .field("__typename", String.self),
        .field("hasReadingHistory", Bool.self),
        .field("todayDurationMs", MoonreadQueries.UInt64.self),
        .field("weekDurationMs", MoonreadQueries.UInt64.self),
        .field("streakDays", MoonreadQueries.UInt64.self),
        .field("days", [Day].self),
      ] }
      @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        StatisticsWidgetQuery.Data.StatisticsWidget.self
      ] }

      public var hasReadingHistory: Bool { __data["hasReadingHistory"] }
      public var todayDurationMs: MoonreadQueries.UInt64 { __data["todayDurationMs"] }
      public var weekDurationMs: MoonreadQueries.UInt64 { __data["weekDurationMs"] }
      public var streakDays: MoonreadQueries.UInt64 { __data["streakDays"] }
      public var days: [Day] { __data["days"] }

      public init(
        hasReadingHistory: Bool,
        todayDurationMs: MoonreadQueries.UInt64,
        weekDurationMs: MoonreadQueries.UInt64,
        streakDays: MoonreadQueries.UInt64,
        days: [Day]
      ) {
        self.init(unsafelyWithData: [
          "__typename": MoonreadQueries.Objects.ReadingStatisticsWidget.typename,
          "hasReadingHistory": hasReadingHistory,
          "todayDurationMs": todayDurationMs,
          "weekDurationMs": weekDurationMs,
          "streakDays": streakDays,
          "days": days._fieldData,
        ])
      }

      /// StatisticsWidget.Day
      ///
      /// Parent Type: `ReadingStatisticsDay`
      nonisolated public struct Day: MoonreadQueries.SelectionSet {
        @_spi(Unsafe) public let __data: DataDict
        @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

        @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.ReadingStatisticsDay }
        @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("day", MoonreadQueries.Int64.self),
          .field("durationMs", MoonreadQueries.UInt64.self),
          .field("bookCount", MoonreadQueries.UInt64.self),
        ] }
        @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          StatisticsWidgetQuery.Data.StatisticsWidget.Day.self
        ] }

        public var day: MoonreadQueries.Int64 { __data["day"] }
        public var durationMs: MoonreadQueries.UInt64 { __data["durationMs"] }
        public var bookCount: MoonreadQueries.UInt64 { __data["bookCount"] }

        public init(
          day: MoonreadQueries.Int64,
          durationMs: MoonreadQueries.UInt64,
          bookCount: MoonreadQueries.UInt64
        ) {
          self.init(unsafelyWithData: [
            "__typename": MoonreadQueries.Objects.ReadingStatisticsDay.typename,
            "day": day,
            "durationMs": durationMs,
            "bookCount": bookCount,
          ])
        }
      }
    }
  }
}
