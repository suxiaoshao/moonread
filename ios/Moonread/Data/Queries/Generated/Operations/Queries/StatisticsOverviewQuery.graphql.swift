// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension MoonreadQueries {
  nonisolated struct StatisticsOverviewQuery: GraphQLQuery {
    static let operationName: String = "StatisticsOverview"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query StatisticsOverview($firstDay: Int64!, $lastDay: Int64!, $target: InformationTarget) { statisticsOverview(firstDay: $firstDay, lastDay: $lastDay, target: $target) { __typename totalDurationMs books { __typename readingKey bodyID title author durationMs firstReadMs lastReadMs lastFormalMs readingDays cover { __typename id sha256 fileExtension width height } } days { __typename day durationMs bookCount } } }"#
      ))

    public var firstDay: Int64
    public var lastDay: Int64
    public var target: GraphQLNullable<InformationTarget>

    public init(
      firstDay: Int64,
      lastDay: Int64,
      target: GraphQLNullable<InformationTarget>
    ) {
      self.firstDay = firstDay
      self.lastDay = lastDay
      self.target = target
    }

    @_spi(Unsafe) public var __variables: Variables? { [
      "firstDay": firstDay,
      "lastDay": lastDay,
      "target": target
    ] }

    nonisolated struct Data: MoonreadQueries.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.Query }
      static var __selections: [ApolloAPI.Selection] { [
        .field("statisticsOverview", StatisticsOverview.self, arguments: [
          "firstDay": .variable("firstDay"),
          "lastDay": .variable("lastDay"),
          "target": .variable("target")
        ]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        StatisticsOverviewQuery.Data.self
      ] }

      var statisticsOverview: StatisticsOverview { __data["statisticsOverview"] }

      init(
        statisticsOverview: StatisticsOverview
      ) {
        self.init(unsafelyWithData: [
          "__typename": MoonreadQueries.Objects.Query.typename,
          "statisticsOverview": statisticsOverview._fieldData,
        ])
      }

      /// StatisticsOverview
      ///
      /// Parent Type: `ReadingStatisticsOverview`
      nonisolated struct StatisticsOverview: MoonreadQueries.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.ReadingStatisticsOverview }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("totalDurationMs", MoonreadQueries.UInt64.self),
          .field("books", [Book].self),
          .field("days", [Day].self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          StatisticsOverviewQuery.Data.StatisticsOverview.self
        ] }

        var totalDurationMs: MoonreadQueries.UInt64 { __data["totalDurationMs"] }
        var books: [Book] { __data["books"] }
        var days: [Day] { __data["days"] }

        init(
          totalDurationMs: MoonreadQueries.UInt64,
          books: [Book],
          days: [Day]
        ) {
          self.init(unsafelyWithData: [
            "__typename": MoonreadQueries.Objects.ReadingStatisticsOverview.typename,
            "totalDurationMs": totalDurationMs,
            "books": books._fieldData,
            "days": days._fieldData,
          ])
        }

        /// StatisticsOverview.Book
        ///
        /// Parent Type: `ReadingStatisticsBook`
        nonisolated struct Book: MoonreadQueries.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.ReadingStatisticsBook }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("readingKey", MoonreadQueries.ID.self),
            .field("bodyID", MoonreadQueries.ID?.self),
            .field("title", String.self),
            .field("author", String?.self),
            .field("durationMs", MoonreadQueries.UInt64.self),
            .field("firstReadMs", MoonreadQueries.Int64.self),
            .field("lastReadMs", MoonreadQueries.Int64.self),
            .field("lastFormalMs", MoonreadQueries.Int64.self),
            .field("readingDays", MoonreadQueries.UInt64.self),
            .field("cover", Cover?.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            StatisticsOverviewQuery.Data.StatisticsOverview.Book.self
          ] }

          var readingKey: MoonreadQueries.ID { __data["readingKey"] }
          var bodyID: MoonreadQueries.ID? { __data["bodyID"] }
          var title: String { __data["title"] }
          var author: String? { __data["author"] }
          var durationMs: MoonreadQueries.UInt64 { __data["durationMs"] }
          var firstReadMs: MoonreadQueries.Int64 { __data["firstReadMs"] }
          var lastReadMs: MoonreadQueries.Int64 { __data["lastReadMs"] }
          var lastFormalMs: MoonreadQueries.Int64 { __data["lastFormalMs"] }
          var readingDays: MoonreadQueries.UInt64 { __data["readingDays"] }
          var cover: Cover? { __data["cover"] }

          init(
            readingKey: MoonreadQueries.ID,
            bodyID: MoonreadQueries.ID? = nil,
            title: String,
            author: String? = nil,
            durationMs: MoonreadQueries.UInt64,
            firstReadMs: MoonreadQueries.Int64,
            lastReadMs: MoonreadQueries.Int64,
            lastFormalMs: MoonreadQueries.Int64,
            readingDays: MoonreadQueries.UInt64,
            cover: Cover? = nil
          ) {
            self.init(unsafelyWithData: [
              "__typename": MoonreadQueries.Objects.ReadingStatisticsBook.typename,
              "readingKey": readingKey,
              "bodyID": bodyID,
              "title": title,
              "author": author,
              "durationMs": durationMs,
              "firstReadMs": firstReadMs,
              "lastReadMs": lastReadMs,
              "lastFormalMs": lastFormalMs,
              "readingDays": readingDays,
              "cover": cover._fieldData,
            ])
          }

          /// StatisticsOverview.Book.Cover
          ///
          /// Parent Type: `RecentReadingCover`
          nonisolated struct Cover: MoonreadQueries.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.RecentReadingCover }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("id", MoonreadQueries.ID.self),
              .field("sha256", String.self),
              .field("fileExtension", String.self),
              .field("width", Int.self),
              .field("height", Int.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              StatisticsOverviewQuery.Data.StatisticsOverview.Book.Cover.self
            ] }

            var id: MoonreadQueries.ID { __data["id"] }
            var sha256: String { __data["sha256"] }
            var fileExtension: String { __data["fileExtension"] }
            var width: Int { __data["width"] }
            var height: Int { __data["height"] }

            init(
              id: MoonreadQueries.ID,
              sha256: String,
              fileExtension: String,
              width: Int,
              height: Int
            ) {
              self.init(unsafelyWithData: [
                "__typename": MoonreadQueries.Objects.RecentReadingCover.typename,
                "id": id,
                "sha256": sha256,
                "fileExtension": fileExtension,
                "width": width,
                "height": height,
              ])
            }
          }
        }

        /// StatisticsOverview.Day
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
            StatisticsOverviewQuery.Data.StatisticsOverview.Day.self
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