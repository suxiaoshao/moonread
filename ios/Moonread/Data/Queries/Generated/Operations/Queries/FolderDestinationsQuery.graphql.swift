// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension MoonreadQueries {
  nonisolated struct FolderDestinationsQuery: GraphQLQuery {
    static let operationName: String = "FolderDestinations"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
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

    nonisolated struct Data: MoonreadQueries.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.Query }
      static var __selections: [ApolloAPI.Selection] { [
        .field("folderDestinations", [FolderDestination].self, arguments: [
          "shelfID": .variable("shelfID"),
          "path": .variable("path")
        ]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        FolderDestinationsQuery.Data.self
      ] }

      var folderDestinations: [FolderDestination] { __data["folderDestinations"] }

      init(
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
      nonisolated struct FolderDestination: MoonreadQueries.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.FolderDestination }
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
          .field("lastRead", MoonreadQueries.Int64.self),
          .field("descendantCount", MoonreadQueries.UInt64.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          FolderDestinationsQuery.Data.FolderDestination.self
        ] }

        var id: MoonreadQueries.ID { __data["id"] }
        var shelfID: MoonreadQueries.ID { __data["shelfID"] }
        var shelfName: String { __data["shelfName"] }
        var relativePath: String { __data["relativePath"] }
        var parentPath: String { __data["parentPath"] }
        var name: String { __data["name"] }
        var size: MoonreadQueries.UInt64 { __data["size"] }
        var modified: MoonreadQueries.Int64 { __data["modified"] }
        var lastRead: MoonreadQueries.Int64 { __data["lastRead"] }
        var descendantCount: MoonreadQueries.UInt64 { __data["descendantCount"] }

        init(
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

}