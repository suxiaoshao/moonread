// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI

nonisolated protocol MoonreadQueries_SelectionSet: ApolloAPI.SelectionSet & ApolloAPI.RootSelectionSet
where Schema == MoonreadQueries.SchemaMetadata {}

nonisolated protocol MoonreadQueries_InlineFragment: ApolloAPI.SelectionSet & ApolloAPI.InlineFragment
where Schema == MoonreadQueries.SchemaMetadata {}

nonisolated protocol MoonreadQueries_MutableSelectionSet: ApolloAPI.MutableRootSelectionSet
where Schema == MoonreadQueries.SchemaMetadata {}

nonisolated protocol MoonreadQueries_MutableInlineFragment: ApolloAPI.MutableSelectionSet & ApolloAPI.InlineFragment
where Schema == MoonreadQueries.SchemaMetadata {}

extension MoonreadQueries {
  typealias SelectionSet = MoonreadQueries_SelectionSet

  typealias InlineFragment = MoonreadQueries_InlineFragment

  typealias MutableSelectionSet = MoonreadQueries_MutableSelectionSet

  typealias MutableInlineFragment = MoonreadQueries_MutableInlineFragment

  nonisolated enum SchemaMetadata: ApolloAPI.SchemaMetadata {
    static let configuration: any ApolloAPI.SchemaConfiguration.Type = SchemaConfiguration.self

    private static let objectTypeMap: [String: ApolloAPI.Object] = [
      "Query": MoonreadQueries.Objects.Query,
      "RecentReadingCard": MoonreadQueries.Objects.RecentReadingCard,
      "RecentReadingCover": MoonreadQueries.Objects.RecentReadingCover,
      "RecentReadingFile": MoonreadQueries.Objects.RecentReadingFile,
      "RecentReadingMetadata": MoonreadQueries.Objects.RecentReadingMetadata
    ]

    static func objectType(forTypename typename: String) -> ApolloAPI.Object? {
      objectTypeMap[typename]
    }
  }

  nonisolated enum Objects {}
  nonisolated enum Interfaces {}
  nonisolated enum Unions {}

}