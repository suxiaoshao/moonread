// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension MoonreadQueries {
  nonisolated struct ChapterAtQuery: GraphQLQuery {
    static let operationName: String = "ChapterAt"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query ChapterAt($bookID: ID!, $offset: UInt64!) { chapterAt(bookID: $bookID, offset: $offset) { __typename ...HeadingFields } }"#,
        fragments: [HeadingFields.self]
      ))

    public var bookID: ID
    public var offset: UInt64

    public init(
      bookID: ID,
      offset: UInt64
    ) {
      self.bookID = bookID
      self.offset = offset
    }

    @_spi(Unsafe) public var __variables: Variables? { [
      "bookID": bookID,
      "offset": offset
    ] }

    nonisolated struct Data: MoonreadQueries.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.Query }
      static var __selections: [ApolloAPI.Selection] { [
        .field("chapterAt", ChapterAt?.self, arguments: [
          "bookID": .variable("bookID"),
          "offset": .variable("offset")
        ]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        ChapterAtQuery.Data.self
      ] }

      var chapterAt: ChapterAt? { __data["chapterAt"] }

      init(
        chapterAt: ChapterAt? = nil
      ) {
        self.init(unsafelyWithData: [
          "__typename": MoonreadQueries.Objects.Query.typename,
          "chapterAt": chapterAt._fieldData,
        ])
      }

      /// ChapterAt
      ///
      /// Parent Type: `ChapterHeading`
      nonisolated struct ChapterAt: MoonreadQueries.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.ChapterHeading }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .fragment(HeadingFields.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          ChapterAtQuery.Data.ChapterAt.self,
          HeadingFields.self
        ] }

        var start: MoonreadQueries.UInt64 { __data["start"] }
        var title: String { __data["title"] }
        var level: Int { __data["level"] }

        struct Fragments: FragmentContainer {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          var headingFields: HeadingFields { _toFragment() }
        }

        init(
          start: MoonreadQueries.UInt64,
          title: String,
          level: Int
        ) {
          self.init(unsafelyWithData: [
            "__typename": MoonreadQueries.Objects.ChapterHeading.typename,
            "start": start,
            "title": title,
            "level": level,
          ])
        }
      }
    }
  }

}