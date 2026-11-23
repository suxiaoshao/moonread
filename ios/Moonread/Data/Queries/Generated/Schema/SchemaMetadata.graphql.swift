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
      "BookInformation": MoonreadQueries.Objects.BookInformation,
      "ChapterHeading": MoonreadQueries.Objects.ChapterHeading,
      "ChapterStructure": MoonreadQueries.Objects.ChapterStructure,
      "ChapterStructureEntry": MoonreadQueries.Objects.ChapterStructureEntry,
      "FolderBookCard": MoonreadQueries.Objects.FolderBookCard,
      "FolderCover": MoonreadQueries.Objects.FolderCover,
      "FolderDestination": MoonreadQueries.Objects.FolderDestination,
      "FolderEntry": MoonreadQueries.Objects.FolderEntry,
      "FolderGroup": MoonreadQueries.Objects.FolderGroup,
      "InformationBody": MoonreadQueries.Objects.InformationBody,
      "InformationMetadata": MoonreadQueries.Objects.InformationMetadata,
      "InformationSource": MoonreadQueries.Objects.InformationSource,
      "Query": MoonreadQueries.Objects.Query,
      "ReaderOpening": MoonreadQueries.Objects.ReaderOpening,
      "ReadingStatisticsActivity": MoonreadQueries.Objects.ReadingStatisticsActivity,
      "ReadingStatisticsBook": MoonreadQueries.Objects.ReadingStatisticsBook,
      "ReadingStatisticsDay": MoonreadQueries.Objects.ReadingStatisticsDay,
      "ReadingStatisticsOverview": MoonreadQueries.Objects.ReadingStatisticsOverview,
      "ReadingStatisticsWidget": MoonreadQueries.Objects.ReadingStatisticsWidget,
      "RecentReadingCard": MoonreadQueries.Objects.RecentReadingCard,
      "RecentReadingCover": MoonreadQueries.Objects.RecentReadingCover,
      "RecentReadingFile": MoonreadQueries.Objects.RecentReadingFile,
      "RecentReadingMetadata": MoonreadQueries.Objects.RecentReadingMetadata,
      "SearchFile": MoonreadQueries.Objects.SearchFile,
      "SearchOptions": MoonreadQueries.Objects.SearchOptions,
      "SearchTagOption": MoonreadQueries.Objects.SearchTagOption,
      "ShelfBookCard": MoonreadQueries.Objects.ShelfBookCard,
      "ShelfTagGroup": MoonreadQueries.Objects.ShelfTagGroup,
      "SystemCatalogueBook": MoonreadQueries.Objects.SystemCatalogueBook
    ]

    static func objectType(forTypename typename: String) -> ApolloAPI.Object? {
      objectTypeMap[typename]
    }
  }

  nonisolated enum Objects {}
  nonisolated enum Interfaces {}
  nonisolated enum Unions {}

}