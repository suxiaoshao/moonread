// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

nonisolated public struct StatisticsActivitiesQuery: GraphQLQuery {
  public static let operationName: String = "StatisticsActivities"
  public static let operationDocument: ApolloAPI.OperationDocument = .init(
    definition: .init(
      #"query StatisticsActivities($firstDay: Int64!, $lastDay: Int64!, $target: InformationTarget) { statisticsActivities(firstDay: $firstDay, lastDay: $lastDay, target: $target) { __typename kind recordID readingKey bodyID sessionID title localDay utcOffsetSeconds preview startedMs endedMs durationMs firstExposureStart } }"#
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
      .field("statisticsActivities", [StatisticsActivity].self, arguments: [
        "firstDay": .variable("firstDay"),
        "lastDay": .variable("lastDay"),
        "target": .variable("target")
      ]),
    ] }
    @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      StatisticsActivitiesQuery.Data.self
    ] }

    public var statisticsActivities: [StatisticsActivity] { __data["statisticsActivities"] }

    public init(
      statisticsActivities: [StatisticsActivity]
    ) {
      self.init(unsafelyWithData: [
        "__typename": MoonreadQueries.Objects.Query.typename,
        "statisticsActivities": statisticsActivities._fieldData,
      ])
    }

    /// StatisticsActivity
    ///
    /// Parent Type: `ReadingStatisticsActivity`
    nonisolated public struct StatisticsActivity: MoonreadQueries.SelectionSet {
      @_spi(Unsafe) public let __data: DataDict
      @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

      @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.ReadingStatisticsActivity }
      @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
        .field("__typename", String.self),
        .field("kind", String.self),
        .field("recordID", MoonreadQueries.ID.self),
        .field("readingKey", MoonreadQueries.ID.self),
        .field("bodyID", MoonreadQueries.ID?.self),
        .field("sessionID", MoonreadQueries.ID.self),
        .field("title", String.self),
        .field("localDay", MoonreadQueries.Int64.self),
        .field("utcOffsetSeconds", Int.self),
        .field("preview", Bool.self),
        .field("startedMs", MoonreadQueries.Int64.self),
        .field("endedMs", MoonreadQueries.Int64.self),
        .field("durationMs", MoonreadQueries.UInt64.self),
        .field("firstExposureStart", MoonreadQueries.UInt64.self),
      ] }
      @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        StatisticsActivitiesQuery.Data.StatisticsActivity.self
      ] }

      public var kind: String { __data["kind"] }
      public var recordID: MoonreadQueries.ID { __data["recordID"] }
      public var readingKey: MoonreadQueries.ID { __data["readingKey"] }
      public var bodyID: MoonreadQueries.ID? { __data["bodyID"] }
      public var sessionID: MoonreadQueries.ID { __data["sessionID"] }
      public var title: String { __data["title"] }
      public var localDay: MoonreadQueries.Int64 { __data["localDay"] }
      public var utcOffsetSeconds: Int { __data["utcOffsetSeconds"] }
      public var preview: Bool { __data["preview"] }
      public var startedMs: MoonreadQueries.Int64 { __data["startedMs"] }
      public var endedMs: MoonreadQueries.Int64 { __data["endedMs"] }
      public var durationMs: MoonreadQueries.UInt64 { __data["durationMs"] }
      public var firstExposureStart: MoonreadQueries.UInt64 { __data["firstExposureStart"] }

      public init(
        kind: String,
        recordID: MoonreadQueries.ID,
        readingKey: MoonreadQueries.ID,
        bodyID: MoonreadQueries.ID? = nil,
        sessionID: MoonreadQueries.ID,
        title: String,
        localDay: MoonreadQueries.Int64,
        utcOffsetSeconds: Int,
        preview: Bool,
        startedMs: MoonreadQueries.Int64,
        endedMs: MoonreadQueries.Int64,
        durationMs: MoonreadQueries.UInt64,
        firstExposureStart: MoonreadQueries.UInt64
      ) {
        self.init(unsafelyWithData: [
          "__typename": MoonreadQueries.Objects.ReadingStatisticsActivity.typename,
          "kind": kind,
          "recordID": recordID,
          "readingKey": readingKey,
          "bodyID": bodyID,
          "sessionID": sessionID,
          "title": title,
          "localDay": localDay,
          "utcOffsetSeconds": utcOffsetSeconds,
          "preview": preview,
          "startedMs": startedMs,
          "endedMs": endedMs,
          "durationMs": durationMs,
          "firstExposureStart": firstExposureStart,
        ])
      }
    }
  }
}
