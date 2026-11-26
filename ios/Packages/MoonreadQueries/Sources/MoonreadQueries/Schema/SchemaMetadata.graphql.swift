// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI

nonisolated public protocol SelectionSet: ApolloAPI.SelectionSet & ApolloAPI.RootSelectionSet
where Schema == MoonreadQueries.SchemaMetadata {}

nonisolated public protocol InlineFragment: ApolloAPI.SelectionSet & ApolloAPI.InlineFragment
where Schema == MoonreadQueries.SchemaMetadata {}

nonisolated public protocol MutableSelectionSet: ApolloAPI.MutableRootSelectionSet
where Schema == MoonreadQueries.SchemaMetadata {}

nonisolated public protocol MutableInlineFragment: ApolloAPI.MutableSelectionSet & ApolloAPI.InlineFragment
where Schema == MoonreadQueries.SchemaMetadata {}

nonisolated public enum SchemaMetadata: ApolloAPI.SchemaMetadata {
  public static let configuration: any ApolloAPI.SchemaConfiguration.Type = SchemaConfiguration.self

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

  @_spi(Execution) public static func objectType(forTypename typename: String) -> ApolloAPI.Object? {
    objectTypeMap[typename]
  }
}

nonisolated public enum Objects {}
nonisolated public enum Interfaces {}
nonisolated public enum Unions {}
