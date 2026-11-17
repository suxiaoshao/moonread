// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension MoonreadQueries {
  nonisolated struct StatisticsActivitiesQuery: GraphQLQuery {
    static let operationName: String = "StatisticsActivities"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
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

    nonisolated struct Data: MoonreadQueries.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.Query }
      static var __selections: [ApolloAPI.Selection] { [
        .field("statisticsActivities", [StatisticsActivity].self, arguments: [
          "firstDay": .variable("firstDay"),
          "lastDay": .variable("lastDay"),
          "target": .variable("target")
        ]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        StatisticsActivitiesQuery.Data.self
      ] }

      var statisticsActivities: [StatisticsActivity] { __data["statisticsActivities"] }

      init(
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
      nonisolated struct StatisticsActivity: MoonreadQueries.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.ReadingStatisticsActivity }
        static var __selections: [ApolloAPI.Selection] { [
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
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          StatisticsActivitiesQuery.Data.StatisticsActivity.self
        ] }

        var kind: String { __data["kind"] }
        var recordID: MoonreadQueries.ID { __data["recordID"] }
        var readingKey: MoonreadQueries.ID { __data["readingKey"] }
        var bodyID: MoonreadQueries.ID? { __data["bodyID"] }
        var sessionID: MoonreadQueries.ID { __data["sessionID"] }
        var title: String { __data["title"] }
        var localDay: MoonreadQueries.Int64 { __data["localDay"] }
        var utcOffsetSeconds: Int { __data["utcOffsetSeconds"] }
        var preview: Bool { __data["preview"] }
        var startedMs: MoonreadQueries.Int64 { __data["startedMs"] }
        var endedMs: MoonreadQueries.Int64 { __data["endedMs"] }
        var durationMs: MoonreadQueries.UInt64 { __data["durationMs"] }
        var firstExposureStart: MoonreadQueries.UInt64 { __data["firstExposureStart"] }

        init(
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

}