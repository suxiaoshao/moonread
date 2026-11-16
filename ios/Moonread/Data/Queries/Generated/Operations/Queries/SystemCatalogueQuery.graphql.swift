// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension MoonreadQueries {
  nonisolated struct SystemCatalogueQuery: GraphQLQuery {
    static let operationName: String = "SystemCatalogue"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query SystemCatalogue { systemBookCatalogue { __typename readingKey title author tags sourceShelfIDs sourceCount reconnectRequired needsDownload percentage chapterTitle recentRank naturalOrdinal cover { __typename id sha256 fileExtension width height } } }"#
      ))

    public init() {}

    nonisolated struct Data: MoonreadQueries.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.Query }
      static var __selections: [ApolloAPI.Selection] { [
        .field("systemBookCatalogue", [SystemBookCatalogue].self),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        SystemCatalogueQuery.Data.self
      ] }

      var systemBookCatalogue: [SystemBookCatalogue] { __data["systemBookCatalogue"] }

      init(
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
      nonisolated struct SystemBookCatalogue: MoonreadQueries.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.SystemCatalogueBook }
        static var __selections: [ApolloAPI.Selection] { [
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
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          SystemCatalogueQuery.Data.SystemBookCatalogue.self
        ] }

        var readingKey: MoonreadQueries.ID { __data["readingKey"] }
        var title: String { __data["title"] }
        var author: String? { __data["author"] }
        var tags: [String] { __data["tags"] }
        var sourceShelfIDs: [MoonreadQueries.ID] { __data["sourceShelfIDs"] }
        var sourceCount: MoonreadQueries.UInt64 { __data["sourceCount"] }
        var reconnectRequired: Bool { __data["reconnectRequired"] }
        var needsDownload: Bool { __data["needsDownload"] }
        var percentage: Double? { __data["percentage"] }
        var chapterTitle: String? { __data["chapterTitle"] }
        var recentRank: Int? { __data["recentRank"] }
        var naturalOrdinal: MoonreadQueries.UInt64 { __data["naturalOrdinal"] }
        var cover: Cover? { __data["cover"] }

        init(
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
            SystemCatalogueQuery.Data.SystemBookCatalogue.Cover.self
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