// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension MoonreadQueries {
  nonisolated struct BookInformationQuery: GraphQLQuery {
    static let operationName: String = "BookInformation"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query BookInformation($target: InformationTarget!, $sourceFileID: ID, $includeRecordSource: Boolean!) { bookInformation( target: $target sourceFileID: $sourceFileID includeRecordSource: $includeRecordSource ) { __typename kind fileID readingKey aliases body { __typename id title encoding byteCount chunkCount position wordCount chapterCount currentChapter } metadata { __typename author synopsis status hasPosition tags cover { __typename id sha256 fileExtension width height } } sources { __typename file { __typename id shelfID shelfName relativePath parentPath name size modified needsDownload } readingKey bodyID position lastRead byteCount preferred } } }"#
      ))

    public var target: InformationTarget
    public var sourceFileID: GraphQLNullable<ID>
    public var includeRecordSource: Bool

    public init(
      target: InformationTarget,
      sourceFileID: GraphQLNullable<ID>,
      includeRecordSource: Bool
    ) {
      self.target = target
      self.sourceFileID = sourceFileID
      self.includeRecordSource = includeRecordSource
    }

    @_spi(Unsafe) public var __variables: Variables? { [
      "target": target,
      "sourceFileID": sourceFileID,
      "includeRecordSource": includeRecordSource
    ] }

    nonisolated struct Data: MoonreadQueries.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.Query }
      static var __selections: [ApolloAPI.Selection] { [
        .field("bookInformation", BookInformation.self, arguments: [
          "target": .variable("target"),
          "sourceFileID": .variable("sourceFileID"),
          "includeRecordSource": .variable("includeRecordSource")
        ]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        BookInformationQuery.Data.self
      ] }

      var bookInformation: BookInformation { __data["bookInformation"] }

      init(
        bookInformation: BookInformation
      ) {
        self.init(unsafelyWithData: [
          "__typename": MoonreadQueries.Objects.Query.typename,
          "bookInformation": bookInformation._fieldData,
        ])
      }

      /// BookInformation
      ///
      /// Parent Type: `BookInformation`
      nonisolated struct BookInformation: MoonreadQueries.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.BookInformation }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("kind", GraphQLEnum<MoonreadQueries.BookInformationKind>.self),
          .field("fileID", MoonreadQueries.ID?.self),
          .field("readingKey", MoonreadQueries.ID?.self),
          .field("aliases", [MoonreadQueries.ID].self),
          .field("body", Body?.self),
          .field("metadata", Metadata?.self),
          .field("sources", [Source].self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          BookInformationQuery.Data.BookInformation.self
        ] }

        var kind: GraphQLEnum<MoonreadQueries.BookInformationKind> { __data["kind"] }
        var fileID: MoonreadQueries.ID? { __data["fileID"] }
        var readingKey: MoonreadQueries.ID? { __data["readingKey"] }
        var aliases: [MoonreadQueries.ID] { __data["aliases"] }
        var body: Body? { __data["body"] }
        var metadata: Metadata? { __data["metadata"] }
        var sources: [Source] { __data["sources"] }

        init(
          kind: GraphQLEnum<MoonreadQueries.BookInformationKind>,
          fileID: MoonreadQueries.ID? = nil,
          readingKey: MoonreadQueries.ID? = nil,
          aliases: [MoonreadQueries.ID],
          body: Body? = nil,
          metadata: Metadata? = nil,
          sources: [Source]
        ) {
          self.init(unsafelyWithData: [
            "__typename": MoonreadQueries.Objects.BookInformation.typename,
            "kind": kind,
            "fileID": fileID,
            "readingKey": readingKey,
            "aliases": aliases,
            "body": body._fieldData,
            "metadata": metadata._fieldData,
            "sources": sources._fieldData,
          ])
        }

        /// BookInformation.Body
        ///
        /// Parent Type: `InformationBody`
        nonisolated struct Body: MoonreadQueries.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.InformationBody }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("id", MoonreadQueries.ID.self),
            .field("title", String.self),
            .field("encoding", String.self),
            .field("byteCount", MoonreadQueries.UInt64.self),
            .field("chunkCount", Int.self),
            .field("position", MoonreadQueries.UInt64.self),
            .field("wordCount", MoonreadQueries.UInt64.self),
            .field("chapterCount", MoonreadQueries.UInt64.self),
            .field("currentChapter", String?.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            BookInformationQuery.Data.BookInformation.Body.self
          ] }

          var id: MoonreadQueries.ID { __data["id"] }
          var title: String { __data["title"] }
          var encoding: String { __data["encoding"] }
          var byteCount: MoonreadQueries.UInt64 { __data["byteCount"] }
          var chunkCount: Int { __data["chunkCount"] }
          var position: MoonreadQueries.UInt64 { __data["position"] }
          var wordCount: MoonreadQueries.UInt64 { __data["wordCount"] }
          var chapterCount: MoonreadQueries.UInt64 { __data["chapterCount"] }
          var currentChapter: String? { __data["currentChapter"] }

          init(
            id: MoonreadQueries.ID,
            title: String,
            encoding: String,
            byteCount: MoonreadQueries.UInt64,
            chunkCount: Int,
            position: MoonreadQueries.UInt64,
            wordCount: MoonreadQueries.UInt64,
            chapterCount: MoonreadQueries.UInt64,
            currentChapter: String? = nil
          ) {
            self.init(unsafelyWithData: [
              "__typename": MoonreadQueries.Objects.InformationBody.typename,
              "id": id,
              "title": title,
              "encoding": encoding,
              "byteCount": byteCount,
              "chunkCount": chunkCount,
              "position": position,
              "wordCount": wordCount,
              "chapterCount": chapterCount,
              "currentChapter": currentChapter,
            ])
          }
        }

        /// BookInformation.Metadata
        ///
        /// Parent Type: `InformationMetadata`
        nonisolated struct Metadata: MoonreadQueries.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.InformationMetadata }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("author", String.self),
            .field("synopsis", String.self),
            .field("status", String?.self),
            .field("hasPosition", Bool.self),
            .field("tags", [String].self),
            .field("cover", Cover?.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            BookInformationQuery.Data.BookInformation.Metadata.self
          ] }

          var author: String { __data["author"] }
          var synopsis: String { __data["synopsis"] }
          var status: String? { __data["status"] }
          var hasPosition: Bool { __data["hasPosition"] }
          var tags: [String] { __data["tags"] }
          var cover: Cover? { __data["cover"] }

          init(
            author: String,
            synopsis: String,
            status: String? = nil,
            hasPosition: Bool,
            tags: [String],
            cover: Cover? = nil
          ) {
            self.init(unsafelyWithData: [
              "__typename": MoonreadQueries.Objects.InformationMetadata.typename,
              "author": author,
              "synopsis": synopsis,
              "status": status,
              "hasPosition": hasPosition,
              "tags": tags,
              "cover": cover._fieldData,
            ])
          }

          /// BookInformation.Metadata.Cover
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
              BookInformationQuery.Data.BookInformation.Metadata.Cover.self
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

        /// BookInformation.Source
        ///
        /// Parent Type: `InformationSource`
        nonisolated struct Source: MoonreadQueries.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.InformationSource }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("file", File.self),
            .field("readingKey", MoonreadQueries.ID?.self),
            .field("bodyID", MoonreadQueries.ID?.self),
            .field("position", MoonreadQueries.UInt64.self),
            .field("lastRead", MoonreadQueries.Int64.self),
            .field("byteCount", MoonreadQueries.UInt64.self),
            .field("preferred", Bool.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            BookInformationQuery.Data.BookInformation.Source.self
          ] }

          var file: File { __data["file"] }
          var readingKey: MoonreadQueries.ID? { __data["readingKey"] }
          var bodyID: MoonreadQueries.ID? { __data["bodyID"] }
          var position: MoonreadQueries.UInt64 { __data["position"] }
          var lastRead: MoonreadQueries.Int64 { __data["lastRead"] }
          var byteCount: MoonreadQueries.UInt64 { __data["byteCount"] }
          var preferred: Bool { __data["preferred"] }

          init(
            file: File,
            readingKey: MoonreadQueries.ID? = nil,
            bodyID: MoonreadQueries.ID? = nil,
            position: MoonreadQueries.UInt64,
            lastRead: MoonreadQueries.Int64,
            byteCount: MoonreadQueries.UInt64,
            preferred: Bool
          ) {
            self.init(unsafelyWithData: [
              "__typename": MoonreadQueries.Objects.InformationSource.typename,
              "file": file._fieldData,
              "readingKey": readingKey,
              "bodyID": bodyID,
              "position": position,
              "lastRead": lastRead,
              "byteCount": byteCount,
              "preferred": preferred,
            ])
          }

          /// BookInformation.Source.File
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
              BookInformationQuery.Data.BookInformation.Source.File.self
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
        }
      }
    }
  }

}