// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

nonisolated public struct FolderPageQuery: GraphQLQuery {
  public static let operationName: String = "FolderPage"
  public static let operationDocument: ApolloAPI.OperationDocument = .init(
    definition: .init(
      #"query FolderPage($shelfID: ID!, $path: String!) { folderPage(shelfID: $shelfID, path: $path) { __typename file { __typename id shelfID shelfName relativePath parentPath name size modified needsDownload } lastRead folder { __typename descendantCount previews { __typename fileID name readingKey author cover { __typename id sha256 fileExtension width height } } } book { __typename readingKey bodyID position byteCount preferred chapterTitle metadata { __typename author cover { __typename id sha256 fileExtension width height } } } } }"#
    ))

  public var shelfID: ID
  public var path: String

  public init(
    shelfID: ID,
    path: String
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
      .field("folderPage", [FolderPage].self, arguments: [
        "shelfID": .variable("shelfID"),
        "path": .variable("path")
      ]),
    ] }
    @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      FolderPageQuery.Data.self
    ] }

    public var folderPage: [FolderPage] { __data["folderPage"] }

    public init(
      folderPage: [FolderPage]
    ) {
      self.init(unsafelyWithData: [
        "__typename": MoonreadQueries.Objects.Query.typename,
        "folderPage": folderPage._fieldData,
      ])
    }

    /// FolderPage
    ///
    /// Parent Type: `FolderEntry`
    nonisolated public struct FolderPage: MoonreadQueries.SelectionSet {
      @_spi(Unsafe) public let __data: DataDict
      @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

      @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.FolderEntry }
      @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
        .field("__typename", String.self),
        .field("file", File.self),
        .field("lastRead", MoonreadQueries.Int64.self),
        .field("folder", Folder?.self),
        .field("book", Book?.self),
      ] }
      @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        FolderPageQuery.Data.FolderPage.self
      ] }

      public var file: File { __data["file"] }
      public var lastRead: MoonreadQueries.Int64 { __data["lastRead"] }
      public var folder: Folder? { __data["folder"] }
      public var book: Book? { __data["book"] }

      public init(
        file: File,
        lastRead: MoonreadQueries.Int64,
        folder: Folder? = nil,
        book: Book? = nil
      ) {
        self.init(unsafelyWithData: [
          "__typename": MoonreadQueries.Objects.FolderEntry.typename,
          "file": file._fieldData,
          "lastRead": lastRead,
          "folder": folder._fieldData,
          "book": book._fieldData,
        ])
      }

      /// FolderPage.File
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
          FolderPageQuery.Data.FolderPage.File.self
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

      /// FolderPage.Folder
      ///
      /// Parent Type: `FolderGroup`
      nonisolated public struct Folder: MoonreadQueries.SelectionSet {
        @_spi(Unsafe) public let __data: DataDict
        @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

        @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.FolderGroup }
        @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("descendantCount", MoonreadQueries.UInt64.self),
          .field("previews", [Preview].self),
        ] }
        @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          FolderPageQuery.Data.FolderPage.Folder.self
        ] }

        public var descendantCount: MoonreadQueries.UInt64 { __data["descendantCount"] }
        public var previews: [Preview] { __data["previews"] }

        public init(
          descendantCount: MoonreadQueries.UInt64,
          previews: [Preview]
        ) {
          self.init(unsafelyWithData: [
            "__typename": MoonreadQueries.Objects.FolderGroup.typename,
            "descendantCount": descendantCount,
            "previews": previews._fieldData,
          ])
        }

        /// FolderPage.Folder.Preview
        ///
        /// Parent Type: `FolderCover`
        nonisolated public struct Preview: MoonreadQueries.SelectionSet {
          @_spi(Unsafe) public let __data: DataDict
          @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

          @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.FolderCover }
          @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("fileID", MoonreadQueries.ID.self),
            .field("name", String.self),
            .field("readingKey", MoonreadQueries.ID?.self),
            .field("author", String?.self),
            .field("cover", Cover?.self),
          ] }
          @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            FolderPageQuery.Data.FolderPage.Folder.Preview.self
          ] }

          public var fileID: MoonreadQueries.ID { __data["fileID"] }
          public var name: String { __data["name"] }
          public var readingKey: MoonreadQueries.ID? { __data["readingKey"] }
          public var author: String? { __data["author"] }
          public var cover: Cover? { __data["cover"] }

          public init(
            fileID: MoonreadQueries.ID,
            name: String,
            readingKey: MoonreadQueries.ID? = nil,
            author: String? = nil,
            cover: Cover? = nil
          ) {
            self.init(unsafelyWithData: [
              "__typename": MoonreadQueries.Objects.FolderCover.typename,
              "fileID": fileID,
              "name": name,
              "readingKey": readingKey,
              "author": author,
              "cover": cover._fieldData,
            ])
          }

          /// FolderPage.Folder.Preview.Cover
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
              FolderPageQuery.Data.FolderPage.Folder.Preview.Cover.self
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

      /// FolderPage.Book
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
          FolderPageQuery.Data.FolderPage.Book.self
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

        /// FolderPage.Book.Metadata
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
            FolderPageQuery.Data.FolderPage.Book.Metadata.self
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

          /// FolderPage.Book.Metadata.Cover
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
              FolderPageQuery.Data.FolderPage.Book.Metadata.Cover.self
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
