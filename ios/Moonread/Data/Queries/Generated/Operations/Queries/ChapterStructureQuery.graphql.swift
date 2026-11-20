// @generated
// This file was automatically generated and should not be edited.

@_exported import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension MoonreadQueries {
  nonisolated struct ChapterStructureQuery: GraphQLQuery {
    static let operationName: String = "ChapterStructure"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query ChapterStructure($bookID: ID!) { chapterStructure(bookID: $bookID) { __typename complete entries { __typename heading { __typename ...HeadingFields } wordCount countComplete parentStart parentTitle } } }"#,
        fragments: [HeadingFields.self]
      ))

    public var bookID: ID

    public init(bookID: ID) {
      self.bookID = bookID
    }

    @_spi(Unsafe) public var __variables: Variables? { ["bookID": bookID] }

    nonisolated struct Data: MoonreadQueries.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.Query }
      static var __selections: [ApolloAPI.Selection] { [
        .field("chapterStructure", ChapterStructure.self, arguments: ["bookID": .variable("bookID")]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        ChapterStructureQuery.Data.self
      ] }

      var chapterStructure: ChapterStructure { __data["chapterStructure"] }

      init(
        chapterStructure: ChapterStructure
      ) {
        self.init(unsafelyWithData: [
          "__typename": MoonreadQueries.Objects.Query.typename,
          "chapterStructure": chapterStructure._fieldData,
        ])
      }

      /// ChapterStructure
      ///
      /// Parent Type: `ChapterStructure`
      nonisolated struct ChapterStructure: MoonreadQueries.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.ChapterStructure }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("complete", Bool.self),
          .field("entries", [Entry].self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          ChapterStructureQuery.Data.ChapterStructure.self
        ] }

        var complete: Bool { __data["complete"] }
        var entries: [Entry] { __data["entries"] }

        init(
          complete: Bool,
          entries: [Entry]
        ) {
          self.init(unsafelyWithData: [
            "__typename": MoonreadQueries.Objects.ChapterStructure.typename,
            "complete": complete,
            "entries": entries._fieldData,
          ])
        }

        /// ChapterStructure.Entry
        ///
        /// Parent Type: `ChapterStructureEntry`
        nonisolated struct Entry: MoonreadQueries.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.ChapterStructureEntry }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("heading", Heading.self),
            .field("wordCount", MoonreadQueries.UInt64.self),
            .field("countComplete", Bool.self),
            .field("parentStart", MoonreadQueries.UInt64?.self),
            .field("parentTitle", String?.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            ChapterStructureQuery.Data.ChapterStructure.Entry.self
          ] }

          var heading: Heading { __data["heading"] }
          var wordCount: MoonreadQueries.UInt64 { __data["wordCount"] }
          var countComplete: Bool { __data["countComplete"] }
          var parentStart: MoonreadQueries.UInt64? { __data["parentStart"] }
          var parentTitle: String? { __data["parentTitle"] }

          init(
            heading: Heading,
            wordCount: MoonreadQueries.UInt64,
            countComplete: Bool,
            parentStart: MoonreadQueries.UInt64? = nil,
            parentTitle: String? = nil
          ) {
            self.init(unsafelyWithData: [
              "__typename": MoonreadQueries.Objects.ChapterStructureEntry.typename,
              "heading": heading._fieldData,
              "wordCount": wordCount,
              "countComplete": countComplete,
              "parentStart": parentStart,
              "parentTitle": parentTitle,
            ])
          }

          /// ChapterStructure.Entry.Heading
          ///
          /// Parent Type: `ChapterHeading`
          nonisolated struct Heading: MoonreadQueries.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { MoonreadQueries.Objects.ChapterHeading }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .fragment(HeadingFields.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              ChapterStructureQuery.Data.ChapterStructure.Entry.Heading.self,
              HeadingFields.self
            ] }

            var start: MoonreadQueries.UInt64 { __data["start"] }
            var title: String { __data["title"] }
            var level: Int { __data["level"] }

            struct Fragments: FragmentContainer {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              var headingFields: HeadingFields { _toFragment() }
            }

            init(
              start: MoonreadQueries.UInt64,
              title: String,
              level: Int
            ) {
              self.init(unsafelyWithData: [
                "__typename": MoonreadQueries.Objects.ChapterHeading.typename,
                "start": start,
                "title": title,
                "level": level,
              ])
            }
          }
        }
      }
    }
  }

}