// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

nonisolated public struct ChapterStructureQuery: GraphQLQuery {
  public static let operationName: String = "ChapterStructure"
  public static let operationDocument: ApolloAPI.OperationDocument = .init(
    definition: .init(
      #"query ChapterStructure($bookID: ID!) { chapterStructure(bookID: $bookID) { __typename complete entries { __typename heading { __typename ...HeadingFields } wordCount countComplete parentStart parentTitle } } }"#,
      fragments: [HeadingFields.self]
    ))

  public var bookID: ID

  public init(bookID: ID) {
    self.bookID = bookID
  }

  @_spi(Unsafe) public var __variables: Variables? { ["bookID": bookID] }

  nonisolated public struct Data: MoonreadQueries.SelectionSet {
    @_spi(Unsafe) public let __data: DataDict
    @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

    @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.Query }
    @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
      .field("chapterStructure", ChapterStructure.self, arguments: ["bookID": .variable("bookID")]),
    ] }
    @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      ChapterStructureQuery.Data.self
    ] }

    public var chapterStructure: ChapterStructure { __data["chapterStructure"] }

    public init(
      chapterStructure: ChapterStructure
    ) {
      self.init(unsafelyWithData: [
        "__typename": MoonreadQueries.Objects.Query.typename,
        "chapterStructure": chapterStructure._fieldData,
      ])
    }

    /// ChapterStructure
    ///
    /// Parent Type: `ChapterStructure`
    nonisolated public struct ChapterStructure: MoonreadQueries.SelectionSet {
      @_spi(Unsafe) public let __data: DataDict
      @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

      @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.ChapterStructure }
      @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
        .field("__typename", String.self),
        .field("complete", Bool.self),
        .field("entries", [Entry].self),
      ] }
      @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        ChapterStructureQuery.Data.ChapterStructure.self
      ] }

      public var complete: Bool { __data["complete"] }
      public var entries: [Entry] { __data["entries"] }

      public init(
        complete: Bool,
        entries: [Entry]
      ) {
        self.init(unsafelyWithData: [
          "__typename": MoonreadQueries.Objects.ChapterStructure.typename,
          "complete": complete,
          "entries": entries._fieldData,
        ])
      }

      /// ChapterStructure.Entry
      ///
      /// Parent Type: `ChapterStructureEntry`
      nonisolated public struct Entry: MoonreadQueries.SelectionSet {
        @_spi(Unsafe) public let __data: DataDict
        @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

        @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.ChapterStructureEntry }
        @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("heading", Heading.self),
          .field("wordCount", MoonreadQueries.UInt64.self),
          .field("countComplete", Bool.self),
          .field("parentStart", MoonreadQueries.UInt64?.self),
          .field("parentTitle", String?.self),
        ] }
        @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          ChapterStructureQuery.Data.ChapterStructure.Entry.self
        ] }

        public var heading: Heading { __data["heading"] }
        public var wordCount: MoonreadQueries.UInt64 { __data["wordCount"] }
        public var countComplete: Bool { __data["countComplete"] }
        public var parentStart: MoonreadQueries.UInt64? { __data["parentStart"] }
        public var parentTitle: String? { __data["parentTitle"] }

        public init(
          heading: Heading,
          wordCount: MoonreadQueries.UInt64,
          countComplete: Bool,
          parentStart: MoonreadQueries.UInt64? = nil,
          parentTitle: String? = nil
        ) {
          self.init(unsafelyWithData: [
            "__typename": MoonreadQueries.Objects.ChapterStructureEntry.typename,
            "heading": heading._fieldData,
            "wordCount": wordCount,
            "countComplete": countComplete,
            "parentStart": parentStart,
            "parentTitle": parentTitle,
          ])
        }

        /// ChapterStructure.Entry.Heading
        ///
        /// Parent Type: `ChapterHeading`
        nonisolated public struct Heading: MoonreadQueries.SelectionSet {
          @_spi(Unsafe) public let __data: DataDict
          @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

          @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.ChapterHeading }
          @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .fragment(HeadingFields.self),
          ] }
          @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            ChapterStructureQuery.Data.ChapterStructure.Entry.Heading.self,
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
  }
}
