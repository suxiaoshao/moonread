// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

nonisolated public struct SystemCatalogueQuery: GraphQLQuery {
  public static let operationName: String = "SystemCatalogue"
  public static let operationDocument: ApolloAPI.OperationDocument = .init(
    definition: .init(
      #"query SystemCatalogue { systemBookCatalogue { __typename readingKey title author tags sourceShelfIDs sourceCount reconnectRequired needsDownload percentage chapterTitle recentRank naturalOrdinal cover { __typename id sha256 fileExtension width height } } }"#
    ))

  public init() {}

  nonisolated public struct Data: MoonreadQueries.SelectionSet {
    @_spi(Unsafe) public let __data: DataDict
    @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

    @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.Query }
    @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
      .field("systemBookCatalogue", [SystemBookCatalogue].self),
    ] }
    @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      SystemCatalogueQuery.Data.self
    ] }

    public var systemBookCatalogue: [SystemBookCatalogue] { __data["systemBookCatalogue"] }

    public init(
      systemBookCatalogue: [SystemBookCatalogue]
    ) {
      self.init(unsafelyWithData: [
        "__typename": MoonreadQueries.Objects.Query.typename,
        "systemBookCatalogue": systemBookCatalogue._fieldData,
      ])
    }

    /// SystemBookCatalogue
    ///
    /// Parent Type: `SystemCatalogueBook`
    nonisolated public struct SystemBookCatalogue: MoonreadQueries.SelectionSet {
      @_spi(Unsafe) public let __data: DataDict
      @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

      @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.SystemCatalogueBook }
      @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
        .field("__typename", String.self),
        .field("readingKey", MoonreadQueries.ID.self),
        .field("title", String.self),
        .field("author", String?.self),
        .field("tags", [String].self),
        .field("sourceShelfIDs", [MoonreadQueries.ID].self),
        .field("sourceCount", MoonreadQueries.UInt64.self),
        .field("reconnectRequired", Bool.self),
        .field("needsDownload", Bool.self),
        .field("percentage", Double?.self),
        .field("chapterTitle", String?.self),
        .field("recentRank", Int?.self),
        .field("naturalOrdinal", MoonreadQueries.UInt64.self),
        .field("cover", Cover?.self),
      ] }
      @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        SystemCatalogueQuery.Data.SystemBookCatalogue.self
      ] }

      public var readingKey: MoonreadQueries.ID { __data["readingKey"] }
      public var title: String { __data["title"] }
      public var author: String? { __data["author"] }
      public var tags: [String] { __data["tags"] }
      public var sourceShelfIDs: [MoonreadQueries.ID] { __data["sourceShelfIDs"] }
      public var sourceCount: MoonreadQueries.UInt64 { __data["sourceCount"] }
      public var reconnectRequired: Bool { __data["reconnectRequired"] }
      public var needsDownload: Bool { __data["needsDownload"] }
      public var percentage: Double? { __data["percentage"] }
      public var chapterTitle: String? { __data["chapterTitle"] }
      public var recentRank: Int? { __data["recentRank"] }
      public var naturalOrdinal: MoonreadQueries.UInt64 { __data["naturalOrdinal"] }
      public var cover: Cover? { __data["cover"] }

      public init(
        readingKey: MoonreadQueries.ID,
        title: String,
        author: String? = nil,
        tags: [String],
        sourceShelfIDs: [MoonreadQueries.ID],
        sourceCount: MoonreadQueries.UInt64,
        reconnectRequired: Bool,
        needsDownload: Bool,
        percentage: Double? = nil,
        chapterTitle: String? = nil,
        recentRank: Int? = nil,
        naturalOrdinal: MoonreadQueries.UInt64,
        cover: Cover? = nil
      ) {
        self.init(unsafelyWithData: [
          "__typename": MoonreadQueries.Objects.SystemCatalogueBook.typename,
          "readingKey": readingKey,
          "title": title,
          "author": author,
          "tags": tags,
          "sourceShelfIDs": sourceShelfIDs,
          "sourceCount": sourceCount,
          "reconnectRequired": reconnectRequired,
          "needsDownload": needsDownload,
          "percentage": percentage,
          "chapterTitle": chapterTitle,
          "recentRank": recentRank,
          "naturalOrdinal": naturalOrdinal,
          "cover": cover._fieldData,
        ])
      }

      /// SystemBookCatalogue.Cover
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
          SystemCatalogueQuery.Data.SystemBookCatalogue.Cover.self
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
  }
}
