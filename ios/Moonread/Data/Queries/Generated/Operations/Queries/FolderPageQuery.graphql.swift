// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension MoonreadQueries {
  nonisolated struct FolderPageQuery: GraphQLQuery {
    static let operationName: String = "FolderPage"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
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

    nonisolated struct Data: MoonreadQueries.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.Query }
      static var __selections: [ApolloAPI.Selection] { [
        .field("folderPage", [FolderPage].self, arguments: [
          "shelfID": .variable("shelfID"),
          "path": .variable("path")
        ]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        FolderPageQuery.Data.self
      ] }

      var folderPage: [FolderPage] { __data["folderPage"] }

      init(
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
      nonisolated struct FolderPage: MoonreadQueries.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.FolderEntry }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("file", File.self),
          .field("lastRead", MoonreadQueries.Int64.self),
          .field("folder", Folder?.self),
          .field("book", Book?.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          FolderPageQuery.Data.FolderPage.self
        ] }

        var file: File { __data["file"] }
        var lastRead: MoonreadQueries.Int64 { __data["lastRead"] }
        var folder: Folder? { __data["folder"] }
        var book: Book? { __data["book"] }

        init(
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
        nonisolated struct File: MoonreadQueries.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.RecentReadingFile }
          static var __selections: [ApolloAPI.Selection] { [
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
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            FolderPageQuery.Data.FolderPage.File.self
          ] }

          var id: MoonreadQueries.ID { __data["id"] }
          var shelfID: MoonreadQueries.ID { __data["shelfID"] }
          var shelfName: String { __data["shelfName"] }
          var relativePath: String { __data["relativePath"] }
          var parentPath: String { __data["parentPath"] }
          var name: String { __data["name"] }
          var size: MoonreadQueries.UInt64 { __data["size"] }
          var modified: MoonreadQueries.Int64 { __data["modified"] }
          var needsDownload: Bool { __data["needsDownload"] }

          init(
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
        nonisolated struct Folder: MoonreadQueries.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.FolderGroup }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("descendantCount", MoonreadQueries.UInt64.self),
            .field("previews", [Preview].self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            FolderPageQuery.Data.FolderPage.Folder.self
          ] }

          var descendantCount: MoonreadQueries.UInt64 { __data["descendantCount"] }
          var previews: [Preview] { __data["previews"] }

          init(
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
          nonisolated struct Preview: MoonreadQueries.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.FolderCover }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("fileID", MoonreadQueries.ID.self),
              .field("name", String.self),
              .field("readingKey", MoonreadQueries.ID?.self),
              .field("author", String?.self),
              .field("cover", Cover?.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              FolderPageQuery.Data.FolderPage.Folder.Preview.self
            ] }

            var fileID: MoonreadQueries.ID { __data["fileID"] }
            var name: String { __data["name"] }
            var readingKey: MoonreadQueries.ID? { __data["readingKey"] }
            var author: String? { __data["author"] }
            var cover: Cover? { __data["cover"] }

            init(
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
                FolderPageQuery.Data.FolderPage.Folder.Preview.Cover.self
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
        }

        /// FolderPage.Book
        ///
        /// Parent Type: `FolderBookCard`
        nonisolated struct Book: MoonreadQueries.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.FolderBookCard }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("readingKey", MoonreadQueries.ID?.self),
            .field("bodyID", MoonreadQueries.ID?.self),
            .field("position", MoonreadQueries.UInt64.self),
            .field("byteCount", MoonreadQueries.UInt64.self),
            .field("preferred", Bool.self),
            .field("chapterTitle", String?.self),
            .field("metadata", Metadata?.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            FolderPageQuery.Data.FolderPage.Book.self
          ] }

          var readingKey: MoonreadQueries.ID? { __data["readingKey"] }
          var bodyID: MoonreadQueries.ID? { __data["bodyID"] }
          var position: MoonreadQueries.UInt64 { __data["position"] }
          var byteCount: MoonreadQueries.UInt64 { __data["byteCount"] }
          var preferred: Bool { __data["preferred"] }
          var chapterTitle: String? { __data["chapterTitle"] }
          var metadata: Metadata? { __data["metadata"] }

          init(
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
          nonisolated struct Metadata: MoonreadQueries.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.RecentReadingMetadata }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("author", String.self),
              .field("cover", Cover?.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              FolderPageQuery.Data.FolderPage.Book.Metadata.self
            ] }

            var author: String { __data["author"] }
            var cover: Cover? { __data["cover"] }

            init(
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
                FolderPageQuery.Data.FolderPage.Book.Metadata.Cover.self
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
        }
      }
    }
  }

}