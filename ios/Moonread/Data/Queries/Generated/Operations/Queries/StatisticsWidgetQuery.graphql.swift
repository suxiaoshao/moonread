// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension MoonreadQueries {
  nonisolated struct StatisticsWidgetQuery: GraphQLQuery {
    static let operationName: String = "StatisticsWidget"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
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

    nonisolated struct Data: MoonreadQueries.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.Query }
      static var __selections: [ApolloAPI.Selection] { [
        .field("statisticsWidget", StatisticsWidget.self, arguments: [
          "today": .variable("today"),
          "weekStart": .variable("weekStart")
        ]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        StatisticsWidgetQuery.Data.self
      ] }

      var statisticsWidget: StatisticsWidget { __data["statisticsWidget"] }

      init(
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
      nonisolated struct StatisticsWidget: MoonreadQueries.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.ReadingStatisticsWidget }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("hasReadingHistory", Bool.self),
          .field("todayDurationMs", MoonreadQueries.UInt64.self),
          .field("weekDurationMs", MoonreadQueries.UInt64.self),
          .field("streakDays", MoonreadQueries.UInt64.self),
          .field("days", [Day].self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          StatisticsWidgetQuery.Data.StatisticsWidget.self
        ] }

        var hasReadingHistory: Bool { __data["hasReadingHistory"] }
        var todayDurationMs: MoonreadQueries.UInt64 { __data["todayDurationMs"] }
        var weekDurationMs: MoonreadQueries.UInt64 { __data["weekDurationMs"] }
        var streakDays: MoonreadQueries.UInt64 { __data["streakDays"] }
        var days: [Day] { __data["days"] }

        init(
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
        nonisolated struct Day: MoonreadQueries.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.ReadingStatisticsDay }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("day", MoonreadQueries.Int64.self),
            .field("durationMs", MoonreadQueries.UInt64.self),
            .field("bookCount", MoonreadQueries.UInt64.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            StatisticsWidgetQuery.Data.StatisticsWidget.Day.self
          ] }

          var day: MoonreadQueries.Int64 { __data["day"] }
          var durationMs: MoonreadQueries.UInt64 { __data["durationMs"] }
          var bookCount: MoonreadQueries.UInt64 { __data["bookCount"] }

          init(
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

}