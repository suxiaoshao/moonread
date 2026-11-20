// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension MoonreadQueries {
  nonisolated struct RecentReadingQuery: GraphQLQuery {
    static let operationName: String = "RecentReading"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query RecentReading($limit: Int!) { recentReading(limit: $limit) { __typename readingKey bodyID file { __typename id shelfID shelfName relativePath parentPath name size modified needsDownload } position byteCount lastRead preferred chapterTitle metadata { __typename author cover { __typename id sha256 fileExtension width height } } } }"#
      ))

    public var limit: Int32

    public init(limit: Int32) {
      self.limit = limit
    }

    @_spi(Unsafe) public var __variables: Variables? { ["limit": limit] }

    nonisolated struct Data: MoonreadQueries.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.Query }
      static var __selections: [ApolloAPI.Selection] { [
        .field("recentReading", [RecentReading].self, arguments: ["limit": .variable("limit")]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        RecentReadingQuery.Data.self
      ] }

      var recentReading: [RecentReading] { __data["recentReading"] }

      init(
        recentReading: [RecentReading]
      ) {
        self.init(unsafelyWithData: [
          "__typename": MoonreadQueries.Objects.Query.typename,
          "recentReading": recentReading._fieldData,
        ])
      }

      /// RecentReading
      ///
      /// Parent Type: `RecentReadingCard`
      nonisolated struct RecentReading: MoonreadQueries.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.RecentReadingCard }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("readingKey", MoonreadQueries.ID.self),
          .field("bodyID", MoonreadQueries.ID?.self),
          .field("file", File.self),
          .field("position", MoonreadQueries.UInt64.self),
          .field("byteCount", MoonreadQueries.UInt64.self),
          .field("lastRead", MoonreadQueries.Int64.self),
          .field("preferred", Bool.self),
          .field("chapterTitle", String?.self),
          .field("metadata", Metadata?.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          RecentReadingQuery.Data.RecentReading.self
        ] }

        var readingKey: MoonreadQueries.ID { __data["readingKey"] }
        var bodyID: MoonreadQueries.ID? { __data["bodyID"] }
        var file: File { __data["file"] }
        var position: MoonreadQueries.UInt64 { __data["position"] }
        var byteCount: MoonreadQueries.UInt64 { __data["byteCount"] }
        var lastRead: MoonreadQueries.Int64 { __data["lastRead"] }
        var preferred: Bool { __data["preferred"] }
        var chapterTitle: String? { __data["chapterTitle"] }
        var metadata: Metadata? { __data["metadata"] }

        init(
          readingKey: MoonreadQueries.ID,
          bodyID: MoonreadQueries.ID? = nil,
          file: File,
          position: MoonreadQueries.UInt64,
          byteCount: MoonreadQueries.UInt64,
          lastRead: MoonreadQueries.Int64,
          preferred: Bool,
          chapterTitle: String? = nil,
          metadata: Metadata? = nil
        ) {
          self.init(unsafelyWithData: [
            "__typename": MoonreadQueries.Objects.RecentReadingCard.typename,
            "readingKey": readingKey,
            "bodyID": bodyID,
            "file": file._fieldData,
            "position": position,
            "byteCount": byteCount,
            "lastRead": lastRead,
            "preferred": preferred,
            "chapterTitle": chapterTitle,
            "metadata": metadata._fieldData,
          ])
        }

        /// RecentReading.File
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
            RecentReadingQuery.Data.RecentReading.File.self
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

        /// RecentReading.Metadata
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
            RecentReadingQuery.Data.RecentReading.Metadata.self
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

          /// RecentReading.Metadata.Cover
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
              RecentReadingQuery.Data.RecentReading.Metadata.Cover.self
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