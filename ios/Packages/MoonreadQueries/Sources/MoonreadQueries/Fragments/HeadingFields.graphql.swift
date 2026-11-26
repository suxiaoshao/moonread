// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

nonisolated public struct HeadingFields: MoonreadQueries.SelectionSet, Fragment {
  public static var fragmentDefinition: StaticString {
    #"fragment HeadingFields on ChapterHeading { __typename start title level }"#
  }

  @_spi(Unsafe) public let __data: DataDict
  @_spi(Unsafe) public init(_dataDict: DataDict) { __data = _dataDict }

  @_spi(Execution) public static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.ChapterHeading }
  @_spi(Execution) public static var __selections: [ApolloAPI.Selection] { [
    .field("__typename", String.self),
    .field("start", MoonreadQueries.UInt64.self),
    .field("title", String.self),
    .field("level", Int.self),
  ] }
  @_spi(Execution) public static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
    HeadingFields.self
  ] }

  public var start: MoonreadQueries.UInt64 { __data["start"] }
  public var title: String { __data["title"] }
  public var level: Int { __data["level"] }
}
