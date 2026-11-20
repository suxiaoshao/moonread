// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension MoonreadQueries {
  nonisolated struct ShelfTagGroupsQuery: GraphQLQuery {
    static let operationName: String = "ShelfTagGroups"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query ShelfTagGroups($shelfID: ID!) { shelfTagGroups(shelfID: $shelfID) { __typename kind tag fileIDs } }"#
      ))

    public var shelfID: ID

    public init(shelfID: ID) {
      self.shelfID = shelfID
    }

    @_spi(Unsafe) public var __variables: Variables? { ["shelfID": shelfID] }

    nonisolated struct Data: MoonreadQueries.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.Query }
      static var __selections: [ApolloAPI.Selection] { [
        .field("shelfTagGroups", [ShelfTagGroup].self, arguments: ["shelfID": .variable("shelfID")]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        ShelfTagGroupsQuery.Data.self
      ] }

      var shelfTagGroups: [ShelfTagGroup] { __data["shelfTagGroups"] }

      init(
        shelfTagGroups: [ShelfTagGroup]
      ) {
        self.init(unsafelyWithData: [
          "__typename": MoonreadQueries.Objects.Query.typename,
          "shelfTagGroups": shelfTagGroups._fieldData,
        ])
      }

      /// ShelfTagGroup
      ///
      /// Parent Type: `ShelfTagGroup`
      nonisolated struct ShelfTagGroup: MoonreadQueries.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.ShelfTagGroup }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("kind", GraphQLEnum<MoonreadQueries.ShelfTagKind>.self),
          .field("tag", String.self),
          .field("fileIDs", [MoonreadQueries.ID].self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          ShelfTagGroupsQuery.Data.ShelfTagGroup.self
        ] }

        var kind: GraphQLEnum<MoonreadQueries.ShelfTagKind> { __data["kind"] }
        var tag: String { __data["tag"] }
        var fileIDs: [MoonreadQueries.ID] { __data["fileIDs"] }

        init(
          kind: GraphQLEnum<MoonreadQueries.ShelfTagKind>,
          tag: String,
          fileIDs: [MoonreadQueries.ID]
        ) {
          self.init(unsafelyWithData: [
            "__typename": MoonreadQueries.Objects.ShelfTagGroup.typename,
            "kind": kind,
            "tag": tag,
            "fileIDs": fileIDs,
          ])
        }
      }
    }
  }

}