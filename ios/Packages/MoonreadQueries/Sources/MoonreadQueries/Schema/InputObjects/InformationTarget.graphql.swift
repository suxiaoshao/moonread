// @generated
// This file was automatically generated and should not be edited.

@_spi(Internal) @_spi(Unsafe) import ApolloAPI

nonisolated public struct InformationTarget: InputObject {
  @_spi(Unsafe) public private(set) var __data: InputDict

  @_spi(Unsafe) public init(_ data: InputDict) {
    __data = data
  }

  public init(
    fileID: GraphQLNullable<ID> = nil,
    bookID: GraphQLNullable<ID> = nil,
    readingKey: GraphQLNullable<ID> = nil
  ) {
    __data = InputDict([
      "fileID": fileID,
      "bookID": bookID,
      "readingKey": readingKey
    ])
  }

  public var fileID: GraphQLNullable<ID> {
    get { __data["fileID"] }
    set { __data["fileID"] = newValue }
  }

  public var bookID: GraphQLNullable<ID> {
    get { __data["bookID"] }
    set { __data["bookID"] = newValue }
  }

  public var readingKey: GraphQLNullable<ID> {
    get { __data["readingKey"] }
    set { __data["readingKey"] = newValue }
  }
}
