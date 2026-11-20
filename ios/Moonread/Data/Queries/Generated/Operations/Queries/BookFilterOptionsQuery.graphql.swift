// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension MoonreadQueries {
  nonisolated struct BookFilterOptionsQuery: GraphQLQuery {
    static let operationName: String = "BookFilterOptions"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query BookFilterOptions($shelfID: ID) { bookFilterOptions(shelfID: $shelfID) { __typename authors tags } }"#
      ))

    public var shelfID: GraphQLNullable<ID>

    public init(shelfID: GraphQLNullable<ID>) {
      self.shelfID = shelfID
    }

    @_spi(Unsafe) public var __variables: Variables? { ["shelfID": shelfID] }

    nonisolated struct Data: MoonreadQueries.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.Query }
      static var __selections: [ApolloAPI.Selection] { [
        .field("bookFilterOptions", BookFilterOptions.self, arguments: ["shelfID": .variable("shelfID")]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        BookFilterOptionsQuery.Data.self
      ] }

      var bookFilterOptions: BookFilterOptions { __data["bookFilterOptions"] }

      init(
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
      nonisolated struct BookFilterOptions: MoonreadQueries.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.SearchOptions }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("authors", [String].self),
          .field("tags", [String].self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          BookFilterOptionsQuery.Data.BookFilterOptions.self
        ] }

        var authors: [String] { __data["authors"] }
        var tags: [String] { __data["tags"] }

        init(
          authors: [String],
          tags: [String]
        ) {
          self.init(unsafelyWithData: [
            "__typename": MoonreadQueries.Objects.SearchOptions.typename,
            "authors": authors,
            "tags": tags,
          ])
        }
      }
    }
  }

}