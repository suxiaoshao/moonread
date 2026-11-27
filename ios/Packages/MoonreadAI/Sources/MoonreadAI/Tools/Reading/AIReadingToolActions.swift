/// The host implements book operations using its existing reading and authorization owners.
public protocol AIReadingToolActions: Actor {
  func confirmBook(_ input: AIGetBookInput) async throws -> String?
  func confirmText(_ refs: [String]) async throws -> String?
  func list(_ input: AILSInput) async throws -> AIToolResponse<AILibraryResult>
  func findBooks(_ input: AIFindBooksInput) async throws -> AIToolResponse<AIFilteredBooksResult>
  func getBook(_ input: AIGetBookInput) async throws -> AIToolResponse<AIBookResult>
  func chapters(_ input: AIChaptersInput) async throws -> AIToolResponse<AIChaptersResult>
  func readText(_ input: AIReadInput) async throws -> AIToolResponse<AIReadResult>
  func searchText(_ input: AIRGInput) async throws -> AIToolResponse<AISearchResult>
  func marks(_ input: AIMarksInput) async throws -> AIToolResponse<AIMarksResult>
  func statistics(_ input: AIStatisticsInput) async throws -> AIToolResponse<AIStatisticsResult>
  func environment(_ input: AIEnvironmentInput) -> AIToolResponse<AIEnvironmentResult>
  func listFilterOptions(_ input: AIFilterOptionsInput) async throws -> AIToolResponse<AIFilterOptionsResult>
  func showBookList(_ input: AIShowBookListInput) async throws -> (AIToolResponse<AIShownBooksResult>, [AIBookListPresentation])
  func proposeBookFilter(_ input: AIBookFilterArguments) async throws -> AIToolResponse<AIBookFilterSuggestion>
}

extension AIReadingToolActions {
  public nonisolated func definitions() -> [AIAgentTool] {
    [
      .init(
        name: "list_shelf",
        description: "List one level of a shelf: folders and books. Omit parentRef to list the shelves.",
        input: AILSInput.self, execute: { try await self.list($0) }),
      .init(
        name: "find_books",
        description: """
          Find books in the library. query matches title, author and synopsis; filter selects by reading status, tags, authors or shelves, in the same form as propose_book_filter. Use either or both. totalMatches counts matching files; unknownCount counts files whose details could not be checked. Use list_filter_values for exact tag, author or shelf names. Answer with the books in your reply; use show_books when the reader wants to open specific ones. This tool shows no card.
          """,
        input: AIFindBooksInput.self, execute: { try await self.findBooks($0) }),
      .init(
        name: "list_filter_values",
        description: "Look up exact tag, author or shelf names for a filter, without listing books. Omit query to browse.",
        input: AIFilterOptionsInput.self, execute: { try await self.listFilterOptions($0) }),
      .init(
        name: "propose_book_filter",
        description: """
          Show the reader an editable filter card, only when the reader asks for a filter to edit or save as a shelf; to answer a request for books use find_books. The card does not run a search or save a shelf. filter.match combines rules with all or any; a rule is one condition, or a sub-group {match, rules}. Each condition uses exactly one of status (unread, reading, finished, paused), tags (with tagMatch all, any or none), untagged, authors or shelves, and may set exclude. sorts lists recent, name or author in priority order. If part of the request cannot be expressed (for example "read in the last 30 days"), say so and ask before proposing something broader. The card shows the filter; do not repeat it in the reply.
          """,
        input: AIBookFilterArguments.self, execute: { try await self.proposeBookFilter($0) }),
      .init(
        name: "show_books",
        description: """
          Show a tappable list of 1–5 books in the given order, using fileRef (preferred) or bookRef from a book tool. Use it only when the reader wants to open specific books; answer counts and comparisons in text. Use propose_book_filter only when the reader asks for a filter to edit or save; do not show both cards for the same purpose.
          """,
        input: AIShowBookListInput.self, executeBookList: { try await self.showBookList($0) }),
      .init(
        name: "get_book_info",
        description: "Read a book's details: author, synopsis, tags, status, progress and size. Supply bookRef or fileRef.",
        input: AIGetBookInput.self, confirmation: { try await self.confirmBook($0) },
        execute: { try await self.getBook($0) }),
      .init(
        name: "list_chapters",
        description: "List a book's chapters. query finds titles such as 番外 or 第316章 without paging the whole outline.",
        input: AIChaptersInput.self, confirmation: { try await self.confirmText([$0.bookRef]) },
        execute: { try await self.chapters($0) }),
      .init(
        name: "read_text",
        description: """
          Read the original text: a chapter (chapterRef), the whole book, or the paragraphs around a positionRef (around). Each result has a positionRef for where its text starts. Continue with nextCursor.
          """,
        input: AIReadInput.self, confirmation: { try await self.confirmText([$0.bookRef]) },
        execute: { try await self.readText($0) }),
      .init(
        name: "search_text",
        description: """
          Search the original text of books. Start with a specific phrase in one book. mode literal matches the text as written; regex allows patterns such as 年龄|岁. Each hit has a positionRef; read_text around it to see the passage. Continue with nextCursor.
          """,
        input: AIRGInput.self, confirmation: { try await self.confirmText($0.bookRefs) },
        execute: { try await self.searchText($0) }),
      .init(
        name: "list_marks",
        description: """
          List a book's bookmarks and annotations with their notes. Long notes are shortened; pass markRef to get one mark's full note. Conflicting versions of an annotation are listed as variants and stay unresolved.
          """,
        input: AIMarksInput.self, execute: { try await self.marks($0) }),
      .init(
        name: "get_reading_statistics",
        description: "Read recorded reading statistics for an inclusive date range. Separate recorded facts from your interpretation.",
        input: AIStatisticsInput.self, execute: { try await self.statistics($0) }),
      .init(
        name: "get_current_time",
        description: "Read the current time, time zone and app language. Omit fields for both.",
        input: AIEnvironmentInput.self, execute: { await self.environment($0) }),
    ].sorted { $0.name < $1.name }
  }
}
