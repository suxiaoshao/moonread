// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

nonisolated public struct ShelfTagGroupsQuery: GraphQLQuery {
  public static let operationName: String = "ShelfTagGroups"
  public static let operationDocument: ApolloAPI.OperationDocument = .init(
    definition: .init(
      #"query ShelfTagGroups($shelfID: ID!) { shelfTagGroups(shelfID: $shelfID) { __typename kind tag fileIDs } }"#
    ))

  public var shelfID: ID

  public init(shelfID: ID) {
    self.shelfID = shelfID
  }

  @_spi(Unsafe) public var __variables: Variables? { ["shelfID": shelfID] }

  nonisolated public struct Data: MoonreadQueries.SelectionSet {
    @_spi(Unsafe) public let __data: DataDict
    @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

    @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.Query }
    @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
      .field("shelfTagGroups", [ShelfTagGroup].self, arguments: ["shelfID": .variable("shelfID")]),
    ] }
    @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      ShelfTagGroupsQuery.Data.self
    ] }

    public var shelfTagGroups: [ShelfTagGroup] { __data["shelfTagGroups"] }

    public init(
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
    nonisolated public struct ShelfTagGroup: MoonreadQueries.SelectionSet {
      @_spi(Unsafe) public let __data: DataDict
      @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

      @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.ShelfTagGroup }
      @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
        .field("__typename", String.self),
        .field("kind", GraphQLEnum<MoonreadQueries.ShelfTagKind>.self),
        .field("tag", String.self),
        .field("fileIDs", [MoonreadQueries.ID].self),
      ] }
      @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        ShelfTagGroupsQuery.Data.ShelfTagGroup.self
      ] }

      public var kind: GraphQLEnum<MoonreadQueries.ShelfTagKind> { __data["kind"] }
      public var tag: String { __data["tag"] }
      public var fileIDs: [MoonreadQueries.ID] { __data["fileIDs"] }

      public init(
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
