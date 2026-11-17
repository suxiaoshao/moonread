// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension MoonreadQueries {
  nonisolated struct HeadingFields: MoonreadQueries.SelectionSet, Fragment {
    static var fragmentDefinition: StaticString {
      #"fragment HeadingFields on ChapterHeading { __typename start title level }"#
    }

    let __data: DataDict
    init(_dataDict: DataDict) { __data = _dataDict }

    static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.ChapterHeading }
    static var __selections: [ApolloAPI.Selection] { [
      .field("__typename", String.self),
      .field("start", MoonreadQueries.UInt64.self),
      .field("title", String.self),
      .field("level", Int.self),
    ] }
    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      HeadingFields.self
    ] }

    var start: MoonreadQueries.UInt64 { __data["start"] }
    var title: String { __data["title"] }
    var level: Int { __data["level"] }
  }

}