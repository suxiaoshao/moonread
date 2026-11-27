// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

nonisolated public struct StatisticsOverviewQuery: GraphQLQuery {
  public static let operationName: String = "StatisticsOverview"
  public static let operationDocument: ApolloAPI.OperationDocument = .init(
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

  nonisolated public struct Data: MoonreadQueries.SelectionSet {
    @_spi(Unsafe) public let __data: DataDict
    @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

    @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.Query }
    @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
      .field("statisticsOverview", StatisticsOverview.self, arguments: [
        "firstDay": .variable("firstDay"),
        "lastDay": .variable("lastDay"),
        "target": .variable("target")
      ]),
    ] }
    @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      StatisticsOverviewQuery.Data.self
    ] }

    public var statisticsOverview: StatisticsOverview { __data["statisticsOverview"] }

    public init(
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
    nonisolated public struct StatisticsOverview: MoonreadQueries.SelectionSet {
      @_spi(Unsafe) public let __data: DataDict
      @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

      @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.ReadingStatisticsOverview }
      @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
        .field("__typename", String.self),
        .field("totalDurationMs", MoonreadQueries.UInt64.self),
        .field("books", [Book].self),
        .field("days", [Day].self),
      ] }
      @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        StatisticsOverviewQuery.Data.StatisticsOverview.self
      ] }

      public var totalDurationMs: MoonreadQueries.UInt64 { __data["totalDurationMs"] }
      public var books: [Book] { __data["books"] }
      public var days: [Day] { __data["days"] }

      public init(
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
      nonisolated public struct Book: MoonreadQueries.SelectionSet {
        @_spi(Unsafe) public let __data: DataDict
        @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

        @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.ReadingStatisticsBook }
        @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
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
        @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          StatisticsOverviewQuery.Data.StatisticsOverview.Book.self
        ] }

        public var readingKey: MoonreadQueries.ID { __data["readingKey"] }
        public var bodyID: MoonreadQueries.ID? { __data["bodyID"] }
        public var title: String { __data["title"] }
        public var author: String? { __data["author"] }
        public var durationMs: MoonreadQueries.UInt64 { __data["durationMs"] }
        public var firstReadMs: MoonreadQueries.Int64 { __data["firstReadMs"] }
        public var lastReadMs: MoonreadQueries.Int64 { __data["lastReadMs"] }
        public var lastFormalMs: MoonreadQueries.Int64 { __data["lastFormalMs"] }
        public var readingDays: MoonreadQueries.UInt64 { __data["readingDays"] }
        public var cover: Cover? { __data["cover"] }

        public init(
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
        nonisolated public struct Cover: MoonreadQueries.SelectionSet {
          @_spi(Unsafe) public let __data: DataDict
          @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

          @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.RecentReadingCover }
          @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("id", MoonreadQueries.ID.self),
            .field("sha256", String.self),
            .field("fileExtension", String.self),
            .field("width", Int.self),
            .field("height", Int.self),
          ] }
          @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            StatisticsOverviewQuery.Data.StatisticsOverview.Book.Cover.self
          ] }

          public var id: MoonreadQueries.ID { __data["id"] }
          public var sha256: String { __data["sha256"] }
          public var fileExtension: String { __data["fileExtension"] }
          public var width: Int { __data["width"] }
          public var height: Int { __data["height"] }

          public init(
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
          StatisticsOverviewQuery.Data.StatisticsOverview.Day.self
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
