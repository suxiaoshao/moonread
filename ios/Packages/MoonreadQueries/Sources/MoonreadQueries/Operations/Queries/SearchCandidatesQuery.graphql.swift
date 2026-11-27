// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

nonisolated public struct SearchCandidatesQuery: GraphQLQuery {
  public static let operationName: String = "SearchCandidates"
  public static let operationDocument: ApolloAPI.OperationDocument = .init(
    definition: .init(
      #"query SearchCandidates($shelfID: ID, $path: String) { searchCandidates(shelfID: $shelfID, path: $path) { __typename file { __typename id shelfID shelfName relativePath parentPath name size modified needsDownload } directory readingKey bodyID lastRead hasPosition author synopsis tags status stored } }"#
    ))

  public var shelfID: GraphQLNullable<ID>
  public var path: GraphQLNullable<String>

  public init(
    shelfID: GraphQLNullable<ID>,
    path: GraphQLNullable<String>
  ) {
    self.shelfID = shelfID
    self.path = path
  }

  @_spi(Unsafe) public var __variables: Variables? { [
    "shelfID": shelfID,
    "path": path
  ] }

  nonisolated public struct Data: MoonreadQueries.SelectionSet {
    @_spi(Unsafe) public let __data: DataDict
    @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

    @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.Query }
    @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
      .field("searchCandidates", [SearchCandidate].self, arguments: [
        "shelfID": .variable("shelfID"),
        "path": .variable("path")
      ]),
    ] }
    @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      SearchCandidatesQuery.Data.self
    ] }

    public var searchCandidates: [SearchCandidate] { __data["searchCandidates"] }

    public init(
      searchCandidates: [SearchCandidate]
    ) {
      self.init(unsafelyWithData: [
        "__typename": MoonreadQueries.Objects.Query.typename,
        "searchCandidates": searchCandidates._fieldData,
      ])
    }

    /// SearchCandidate
    ///
    /// Parent Type: `SearchFile`
    nonisolated public struct SearchCandidate: MoonreadQueries.SelectionSet {
      @_spi(Unsafe) public let __data: DataDict
      @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

      @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.SearchFile }
      @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
        .field("__typename", String.self),
        .field("file", File.self),
        .field("directory", Bool.self),
        .field("readingKey", MoonreadQueries.ID?.self),
        .field("bodyID", MoonreadQueries.ID?.self),
        .field("lastRead", MoonreadQueries.Int64.self),
        .field("hasPosition", Bool.self),
        .field("author", String?.self),
        .field("synopsis", String?.self),
        .field("tags", [String].self),
        .field("status", String?.self),
        .field("stored", Bool.self),
      ] }
      @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        SearchCandidatesQuery.Data.SearchCandidate.self
      ] }

      public var file: File { __data["file"] }
      public var directory: Bool { __data["directory"] }
      public var readingKey: MoonreadQueries.ID? { __data["readingKey"] }
      public var bodyID: MoonreadQueries.ID? { __data["bodyID"] }
      public var lastRead: MoonreadQueries.Int64 { __data["lastRead"] }
      public var hasPosition: Bool { __data["hasPosition"] }
      public var author: String? { __data["author"] }
      public var synopsis: String? { __data["synopsis"] }
      public var tags: [String] { __data["tags"] }
      public var status: String? { __data["status"] }
      public var stored: Bool { __data["stored"] }

      public init(
        file: File,
        directory: Bool,
        readingKey: MoonreadQueries.ID? = nil,
        bodyID: MoonreadQueries.ID? = nil,
        lastRead: MoonreadQueries.Int64,
        hasPosition: Bool,
        author: String? = nil,
        synopsis: String? = nil,
        tags: [String],
        status: String? = nil,
        stored: Bool
      ) {
        self.init(unsafelyWithData: [
          "__typename": MoonreadQueries.Objects.SearchFile.typename,
          "file": file._fieldData,
          "directory": directory,
          "readingKey": readingKey,
          "bodyID": bodyID,
          "lastRead": lastRead,
          "hasPosition": hasPosition,
          "author": author,
          "synopsis": synopsis,
          "tags": tags,
          "status": status,
          "stored": stored,
        ])
      }

      /// SearchCandidate.File
      ///
      /// Parent Type: `RecentReadingFile`
      nonisolated public struct File: MoonreadQueries.SelectionSet {
        @_spi(Unsafe) public let __data: DataDict
        @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

        @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.RecentReadingFile }
        @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("id", MoonreadQueries.ID.self),
          .field("shelfID", MoonreadQueries.ID.self),
          .field("shelfName", String.self),
          .field("relativePath", String.self),
          .field("parentPath", String.self),
          .field("name", String.self),
          .field("size", MoonreadQueries.UInt64.self),
          .field("modified", MoonreadQueries.Int64.self),
          .field("needsDownload", Bool.self),
        ] }
        @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          SearchCandidatesQuery.Data.SearchCandidate.File.self
        ] }

        public var id: MoonreadQueries.ID { __data["id"] }
        public var shelfID: MoonreadQueries.ID { __data["shelfID"] }
        public var shelfName: String { __data["shelfName"] }
        public var relativePath: String { __data["relativePath"] }
        public var parentPath: String { __data["parentPath"] }
        public var name: String { __data["name"] }
        public var size: MoonreadQueries.UInt64 { __data["size"] }
        public var modified: MoonreadQueries.Int64 { __data["modified"] }
        public var needsDownload: Bool { __data["needsDownload"] }

        public init(
          id: MoonreadQueries.ID,
          shelfID: MoonreadQueries.ID,
          shelfName: String,
          relativePath: String,
          parentPath: String,
          name: String,
          size: MoonreadQueries.UInt64,
          modified: MoonreadQueries.Int64,
          needsDownload: Bool
        ) {
          self.init(unsafelyWithData: [
            "__typename": MoonreadQueries.Objects.RecentReadingFile.typename,
            "id": id,
            "shelfID": shelfID,
            "shelfName": shelfName,
            "relativePath": relativePath,
            "parentPath": parentPath,
            "name": name,
            "size": size,
            "modified": modified,
            "needsDownload": needsDownload,
          ])
        }
      }
    }
  }
}
