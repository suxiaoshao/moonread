// @generated
// This file was automatically generated and should not be edited.

@_spi(Internal) @_spi(Unsafe) import ApolloAPI

extension MoonreadQueries {
  nonisolated struct InformationTarget: InputObject {
    private(set) var __data: InputDict

    init(_ data: InputDict) {
      __data = data
    }

    init(
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

    var fileID: GraphQLNullable<ID> {
      get { __data["fileID"] }
      set { __data["fileID"] = newValue }
    }

    var bookID: GraphQLNullable<ID> {
      get { __data["bookID"] }
      set { __data["bookID"] = newValue }
    }

    var readingKey: GraphQLNullable<ID> {
      get { __data["readingKey"] }
      set { __data["readingKey"] = newValue }
    }
  }

}