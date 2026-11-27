// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

nonisolated public struct ReaderOpeningQuery: GraphQLQuery {
  public static let operationName: String = "ReaderOpening"
  public static let operationDocument: ApolloAPI.OperationDocument = .init(
    definition: .init(
      #"query ReaderOpening($bookID: ID!) { readerOpening(bookID: $bookID) { __typename sessionID title readingKey encoding bytes chunks position started readable generation bytesRead sourceBytes } }"#
    ))

  public var bookID: ID

  public init(bookID: ID) {
    self.bookID = bookID
  }

  @_spi(Unsafe) public var __variables: Variables? { ["bookID": bookID] }

  nonisolated public struct Data: MoonreadQueries.SelectionSet {
    @_spi(Unsafe) public let __data: DataDict
    @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

    @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.Query }
    @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
      .field("readerOpening", ReaderOpening.self, arguments: ["bookID": .variable("bookID")]),
    ] }
    @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      ReaderOpeningQuery.Data.self
    ] }

    public var readerOpening: ReaderOpening { __data["readerOpening"] }

    public init(
      readerOpening: ReaderOpening
    ) {
      self.init(unsafelyWithData: [
        "__typename": MoonreadQueries.Objects.Query.typename,
        "readerOpening": readerOpening._fieldData,
      ])
    }

    /// ReaderOpening
    ///
    /// Parent Type: `ReaderOpening`
    nonisolated public struct ReaderOpening: MoonreadQueries.SelectionSet {
      @_spi(Unsafe) public let __data: DataDict
      @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

      @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.ReaderOpening }
      @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
        .field("__typename", String.self),
        .field("sessionID", MoonreadQueries.ID.self),
        .field("title", String.self),
        .field("readingKey", MoonreadQueries.ID.self),
        .field("encoding", String.self),
        .field("bytes", MoonreadQueries.UInt64.self),
        .field("chunks", Int.self),
        .field("position", MoonreadQueries.UInt64.self),
        .field("started", Bool.self),
        .field("readable", Bool.self),
        .field("generation", MoonreadQueries.UInt64.self),
        .field("bytesRead", MoonreadQueries.UInt64.self),
        .field("sourceBytes", MoonreadQueries.UInt64.self),
      ] }
      @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        ReaderOpeningQuery.Data.ReaderOpening.self
      ] }

      public var sessionID: MoonreadQueries.ID { __data["sessionID"] }
      public var title: String { __data["title"] }
      public var readingKey: MoonreadQueries.ID { __data["readingKey"] }
      public var encoding: String { __data["encoding"] }
      public var bytes: MoonreadQueries.UInt64 { __data["bytes"] }
      public var chunks: Int { __data["chunks"] }
      public var position: MoonreadQueries.UInt64 { __data["position"] }
      public var started: Bool { __data["started"] }
      public var readable: Bool { __data["readable"] }
      public var generation: MoonreadQueries.UInt64 { __data["generation"] }
      public var bytesRead: MoonreadQueries.UInt64 { __data["bytesRead"] }
      public var sourceBytes: MoonreadQueries.UInt64 { __data["sourceBytes"] }

      public init(
        sessionID: MoonreadQueries.ID,
        title: String,
        readingKey: MoonreadQueries.ID,
        encoding: String,
        bytes: MoonreadQueries.UInt64,
        chunks: Int,
        position: MoonreadQueries.UInt64,
        started: Bool,
        readable: Bool,
        generation: MoonreadQueries.UInt64,
        bytesRead: MoonreadQueries.UInt64,
        sourceBytes: MoonreadQueries.UInt64
      ) {
        self.init(unsafelyWithData: [
          "__typename": MoonreadQueries.Objects.ReaderOpening.typename,
          "sessionID": sessionID,
          "title": title,
          "readingKey": readingKey,
          "encoding": encoding,
          "bytes": bytes,
          "chunks": chunks,
          "position": position,
          "started": started,
          "readable": readable,
          "generation": generation,
          "bytesRead": bytesRead,
          "sourceBytes": sourceBytes,
        ])
      }
    }
  }
}
