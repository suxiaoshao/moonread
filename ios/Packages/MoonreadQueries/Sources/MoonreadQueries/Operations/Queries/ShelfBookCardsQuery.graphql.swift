// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

nonisolated public struct ShelfBookCardsQuery: GraphQLQuery {
  public static let operationName: String = "ShelfBookCards"
  public static let operationDocument: ApolloAPI.OperationDocument = .init(
    definition: .init(
      #"query ShelfBookCards($shelfID: ID!) { shelfBookCards(shelfID: $shelfID) { __typename file { __typename id shelfID shelfName relativePath parentPath name size modified needsDownload } lastRead book { __typename readingKey bodyID position byteCount preferred chapterTitle metadata { __typename author cover { __typename id sha256 fileExtension width height } } } } }"#
    ))

  public var shelfID: ID

  public init(shelfID: ID) {
    self.shelfID = shelfID
  }

  @_spi(Unsafe) public var __variables: Variables? { ["shelfID": shelfID] }

  nonisolated public struct Data: MoonreadQueries.SelectionSet {
    @_spi(Unsafe) public let __data: DataDict
    @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

    @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.Query }
    @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
      .field("shelfBookCards", [ShelfBookCard].self, arguments: ["shelfID": .variable("shelfID")]),
    ] }
    @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      ShelfBookCardsQuery.Data.self
    ] }

    public var shelfBookCards: [ShelfBookCard] { __data["shelfBookCards"] }

    public init(
      shelfBookCards: [ShelfBookCard]
    ) {
      self.init(unsafelyWithData: [
        "__typename": MoonreadQueries.Objects.Query.typename,
        "shelfBookCards": shelfBookCards._fieldData,
      ])
    }

    /// ShelfBookCard
    ///
    /// Parent Type: `ShelfBookCard`
    nonisolated public struct ShelfBookCard: MoonreadQueries.SelectionSet {
      @_spi(Unsafe) public let __data: DataDict
      @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

      @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.ShelfBookCard }
      @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
        .field("__typename", String.self),
        .field("file", File.self),
        .field("lastRead", MoonreadQueries.Int64.self),
        .field("book", Book.self),
      ] }
      @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        ShelfBookCardsQuery.Data.ShelfBookCard.self
      ] }

      public var file: File { __data["file"] }
      public var lastRead: MoonreadQueries.Int64 { __data["lastRead"] }
      public var book: Book { __data["book"] }

      public init(
        file: File,
        lastRead: MoonreadQueries.Int64,
        book: Book
      ) {
        self.init(unsafelyWithData: [
          "__typename": MoonreadQueries.Objects.ShelfBookCard.typename,
          "file": file._fieldData,
          "lastRead": lastRead,
          "book": book._fieldData,
        ])
      }

      /// ShelfBookCard.File
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
          ShelfBookCardsQuery.Data.ShelfBookCard.File.self
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

      /// ShelfBookCard.Book
      ///
      /// Parent Type: `FolderBookCard`
      nonisolated public struct Book: MoonreadQueries.SelectionSet {
        @_spi(Unsafe) public let __data: DataDict
        @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

        @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.FolderBookCard }
        @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("readingKey", MoonreadQueries.ID?.self),
          .field("bodyID", MoonreadQueries.ID?.self),
          .field("position", MoonreadQueries.UInt64.self),
          .field("byteCount", MoonreadQueries.UInt64.self),
          .field("preferred", Bool.self),
          .field("chapterTitle", String?.self),
          .field("metadata", Metadata?.self),
        ] }
        @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          ShelfBookCardsQuery.Data.ShelfBookCard.Book.self
        ] }

        public var readingKey: MoonreadQueries.ID? { __data["readingKey"] }
        public var bodyID: MoonreadQueries.ID? { __data["bodyID"] }
        public var position: MoonreadQueries.UInt64 { __data["position"] }
        public var byteCount: MoonreadQueries.UInt64 { __data["byteCount"] }
        public var preferred: Bool { __data["preferred"] }
        public var chapterTitle: String? { __data["chapterTitle"] }
        public var metadata: Metadata? { __data["metadata"] }

        public init(
          readingKey: MoonreadQueries.ID? = nil,
          bodyID: MoonreadQueries.ID? = nil,
          position: MoonreadQueries.UInt64,
          byteCount: MoonreadQueries.UInt64,
          preferred: Bool,
          chapterTitle: String? = nil,
          metadata: Metadata? = nil
        ) {
          self.init(unsafelyWithData: [
            "__typename": MoonreadQueries.Objects.FolderBookCard.typename,
            "readingKey": readingKey,
            "bodyID": bodyID,
            "position": position,
            "byteCount": byteCount,
            "preferred": preferred,
            "chapterTitle": chapterTitle,
            "metadata": metadata._fieldData,
          ])
        }

        /// ShelfBookCard.Book.Metadata
        ///
        /// Parent Type: `RecentReadingMetadata`
        nonisolated public struct Metadata: MoonreadQueries.SelectionSet {
          @_spi(Unsafe) public let __data: DataDict
          @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

          @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.RecentReadingMetadata }
          @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("author", String.self),
            .field("cover", Cover?.self),
          ] }
          @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            ShelfBookCardsQuery.Data.ShelfBookCard.Book.Metadata.self
          ] }

          public var author: String { __data["author"] }
          public var cover: Cover? { __data["cover"] }

          public init(
            author: String,
            cover: Cover? = nil
          ) {
            self.init(unsafelyWithData: [
              "__typename": MoonreadQueries.Objects.RecentReadingMetadata.typename,
              "author": author,
              "cover": cover._fieldData,
            ])
          }

          /// ShelfBookCard.Book.Metadata.Cover
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
              ShelfBookCardsQuery.Data.ShelfBookCard.Book.Metadata.Cover.self
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
  }
}
