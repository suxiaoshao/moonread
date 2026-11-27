// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

nonisolated public struct ChapterAtQuery: GraphQLQuery {
  public static let operationName: String = "ChapterAt"
  public static let operationDocument: ApolloAPI.OperationDocument = .init(
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

  nonisolated public struct Data: MoonreadQueries.SelectionSet {
    @_spi(Unsafe) public let __data: DataDict
    @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

    @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.Query }
    @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
      .field("chapterAt", ChapterAt?.self, arguments: [
        "bookID": .variable("bookID"),
        "offset": .variable("offset")
      ]),
    ] }
    @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      ChapterAtQuery.Data.self
    ] }

    public var chapterAt: ChapterAt? { __data["chapterAt"] }

    public init(
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
    nonisolated public struct ChapterAt: MoonreadQueries.SelectionSet {
      @_spi(Unsafe) public let __data: DataDict
      @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

      @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.ChapterHeading }
      @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
        .field("__typename", String.self),
        .fragment(HeadingFields.self),
      ] }
      @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        ChapterAtQuery.Data.ChapterAt.self,
        HeadingFields.self
      ] }

      public var start: MoonreadQueries.UInt64 { __data["start"] }
      public var title: String { __data["title"] }
      public var level: Int { __data["level"] }

      public struct Fragments: FragmentContainer {
        @_spi(Unsafe) public let __data: DataDict
        @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

        public var headingFields: HeadingFields { _toFragment() }
      }

      public init(
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
