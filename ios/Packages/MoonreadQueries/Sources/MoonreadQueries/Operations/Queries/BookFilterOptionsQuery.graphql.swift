// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

nonisolated public struct BookFilterOptionsQuery: GraphQLQuery {
  public static let operationName: String = "BookFilterOptions"
  public static let operationDocument: ApolloAPI.OperationDocument = .init(
    definition: .init(
      #"query BookFilterOptions($shelfID: ID) { bookFilterOptions(shelfID: $shelfID) { __typename authors tags { __typename name bookCount } } }"#
    ))

  public var shelfID: GraphQLNullable<ID>

  public init(shelfID: GraphQLNullable<ID>) {
    self.shelfID = shelfID
  }

  @_spi(Unsafe) public var __variables: Variables? { ["shelfID": shelfID] }

  nonisolated public struct Data: MoonreadQueries.SelectionSet {
    @_spi(Unsafe) public let __data: DataDict
    @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

    @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.Query }
    @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
      .field("bookFilterOptions", BookFilterOptions.self, arguments: ["shelfID": .variable("shelfID")]),
    ] }
    @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      BookFilterOptionsQuery.Data.self
    ] }

    public var bookFilterOptions: BookFilterOptions { __data["bookFilterOptions"] }

    public init(
      bookFilterOptions: BookFilterOptions
    ) {
      self.init(unsafelyWithData: [
        "__typename": MoonreadQueries.Objects.Query.typename,
        "bookFilterOptions": bookFilterOptions._fieldData,
      ])
    }

    /// BookFilterOptions
    ///
    /// Parent Type: `SearchOptions`
    nonisolated public struct BookFilterOptions: MoonreadQueries.SelectionSet {
      @_spi(Unsafe) public let __data: DataDict
      @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

      @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.SearchOptions }
      @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
        .field("__typename", String.self),
        .field("authors", [String].self),
        .field("tags", [Tag].self),
      ] }
      @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        BookFilterOptionsQuery.Data.BookFilterOptions.self
      ] }

      public var authors: [String] { __data["authors"] }
      public var tags: [Tag] { __data["tags"] }

      public init(
        authors: [String],
        tags: [Tag]
      ) {
        self.init(unsafelyWithData: [
          "__typename": MoonreadQueries.Objects.SearchOptions.typename,
          "authors": authors,
          "tags": tags._fieldData,
        ])
      }

      /// BookFilterOptions.Tag
      ///
      /// Parent Type: `SearchTagOption`
      nonisolated public struct Tag: MoonreadQueries.SelectionSet {
        @_spi(Unsafe) public let __data: DataDict
        @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

        @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.SearchTagOption }
        @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("name", String.self),
          .field("bookCount", Int.self),
        ] }
        @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          BookFilterOptionsQuery.Data.BookFilterOptions.Tag.self
        ] }

        public var name: String { __data["name"] }
        public var bookCount: Int { __data["bookCount"] }

        public init(
          name: String,
          bookCount: Int
        ) {
          self.init(unsafelyWithData: [
            "__typename": MoonreadQueries.Objects.SearchTagOption.typename,
            "name": name,
            "bookCount": bookCount,
          ])
        }
      }
    }
  }
}
