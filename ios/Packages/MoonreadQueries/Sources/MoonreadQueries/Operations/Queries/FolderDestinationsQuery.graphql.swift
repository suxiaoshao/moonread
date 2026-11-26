// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

nonisolated public struct FolderDestinationsQuery: GraphQLQuery {
  public static let operationName: String = "FolderDestinations"
  public static let operationDocument: ApolloAPI.OperationDocument = .init(
    definition: .init(
      #"query FolderDestinations($shelfID: ID!, $path: String!) { folderDestinations(shelfID: $shelfID, path: $path) { __typename id shelfID shelfName relativePath parentPath name size modified lastRead descendantCount } }"#
    ))

  public var shelfID: ID
  public var path: String

  public init(
    shelfID: ID,
    path: String
  ) {
    self.shelfID = shelfID
    self.path = path
  }

  @_spi(Unsafe) public var __variables: Variables? { [
    "shelfID": shelfID,
    "path": path
  ] }

  nonisolated public struct Data: MoonreadQueries.SelectionSet {
    @_spi(Unsafe) public let __data: DataDict
    @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

    @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.Query }
    @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
      .field("folderDestinations", [FolderDestination].self, arguments: [
        "shelfID": .variable("shelfID"),
        "path": .variable("path")
      ]),
    ] }
    @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      FolderDestinationsQuery.Data.self
    ] }

    public var folderDestinations: [FolderDestination] { __data["folderDestinations"] }

    public init(
      folderDestinations: [FolderDestination]
    ) {
      self.init(unsafelyWithData: [
        "__typename": MoonreadQueries.Objects.Query.typename,
        "folderDestinations": folderDestinations._fieldData,
      ])
    }

    /// FolderDestination
    ///
    /// Parent Type: `FolderDestination`
    nonisolated public struct FolderDestination: MoonreadQueries.SelectionSet {
      @_spi(Unsafe) public let __data: DataDict
      @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

      @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.FolderDestination }
      @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
        .field("__typename", String.self),
        .field("id", MoonreadQueries.ID.self),
        .field("shelfID", MoonreadQueries.ID.self),
        .field("shelfName", String.self),
        .field("relativePath", String.self),
        .field("parentPath", String.self),
        .field("name", String.self),
        .field("size", MoonreadQueries.UInt64.self),
        .field("modified", MoonreadQueries.Int64.self),
        .field("lastRead", MoonreadQueries.Int64.self),
        .field("descendantCount", MoonreadQueries.UInt64.self),
      ] }
      @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        FolderDestinationsQuery.Data.FolderDestination.self
      ] }

      public var id: MoonreadQueries.ID { __data["id"] }
      public var shelfID: MoonreadQueries.ID { __data["shelfID"] }
      public var shelfName: String { __data["shelfName"] }
      public var relativePath: String { __data["relativePath"] }
      public var parentPath: String { __data["parentPath"] }
      public var name: String { __data["name"] }
      public var size: MoonreadQueries.UInt64 { __data["size"] }
      public var modified: MoonreadQueries.Int64 { __data["modified"] }
      public var lastRead: MoonreadQueries.Int64 { __data["lastRead"] }
      public var descendantCount: MoonreadQueries.UInt64 { __data["descendantCount"] }

      public init(
        id: MoonreadQueries.ID,
        shelfID: MoonreadQueries.ID,
        shelfName: String,
        relativePath: String,
        parentPath: String,
        name: String,
        size: MoonreadQueries.UInt64,
        modified: MoonreadQueries.Int64,
        lastRead: MoonreadQueries.Int64,
        descendantCount: MoonreadQueries.UInt64
      ) {
        self.init(unsafelyWithData: [
          "__typename": MoonreadQueries.Objects.FolderDestination.typename,
          "id": id,
          "shelfID": shelfID,
          "shelfName": shelfName,
          "relativePath": relativePath,
          "parentPath": parentPath,
          "name": name,
          "size": size,
          "modified": modified,
          "lastRead": lastRead,
          "descendantCount": descendantCount,
        ])
      }
    }
  }
}
