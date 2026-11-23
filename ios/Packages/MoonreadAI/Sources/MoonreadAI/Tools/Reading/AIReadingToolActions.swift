/// The host implements book operations using its existing reading and authorization owners.
public protocol AIReadingToolActions: Actor {
  func confirmBook(_ input: AIGetBookInput) async throws -> String?
  func confirmText(_ refs: [String]) async throws -> String?
  func list(_ input: AILSInput) async throws -> AIToolResponse<AILibraryResult>
  func searchBooks(_ input: AISearchBooksInput) async throws -> AIToolResponse<AIBooksResult>
  func getBook(_ input: AIGetBookInput) async throws -> AIToolResponse<AIBookResult>
  func chapters(_ input: AIChaptersInput) async throws -> AIToolResponse<AIChaptersResult>
  func readText(_ input: AIReadInput) async throws -> AIToolResponse<AIReadResult>
  func searchText(_ input: AIRGInput) async throws -> AIToolResponse<AISearchResult>
  func marks(_ input: AIMarksInput) async throws -> AIToolResponse<AIMarksResult>
  func mark(_ input: AIMarkInput) async throws -> AIToolResponse<AIMarkResult>
  func statistics(_ input: AIStatisticsInput) async throws -> AIToolResponse<AIStatisticsResult>
  func environment(_ input: AIEnvironmentInput) -> AIToolResponse<AIEnvironmentResult>
  func listFilterOptions(_ input: AIFilterOptionsInput) async throws -> AIToolResponse<AIFilterOptionsResult>
  func proposeBookFilter(_ input: AIBookFilterInput) async throws -> AIToolResponse<AIBookFilterSuggestion>
}

extension AIReadingToolActions {
  public nonisolated func definitions() -> [AIAgentTool] {
    [
      .init(
        name: "ls",
        description:
          "Browse one level of authorized shelves. Omit parentRef to list roots. Optional fields may be omitted or null; never use empty references.",
        input: AILSInput.self, execute: { try await self.list($0) }),
      .init(
        name: "search_books",
        description: "Find novels by indexed title, author, synopsis, tags and reading status.",
        input: AISearchBooksInput.self, execute: { try await self.searchBooks($0) }),
      .init(
        name: "list_filter_options",
        description: "For a book filter, look up exact tag, author, or shelf names here instead of enumerating books. An omitted query browses the names. Continue with page.nextCursor and the same field and query. Returns names only.",
        input: AIFilterOptionsInput.self, execute: { try await self.listFilterOptions($0) }),
      .init(
        name: "propose_book_filter",
        description: """
          Suggest a book search filter as a clickable card. This does not run a search or save a shelf. Use only supported constraints. If part of the user's request cannot be expressed (e.g. read during the last 30 days), explain and ask before proposing a broader filter.
          nodes is a flat tree in display order. Start with {kind:"group",relation:"all"} at index 0. Set each later node's parent to the zero-based index of an earlier group. Groups use all/any. Any node may set excluded:true. Status values are unread, reading, finished, paused. A tag rule uses relation all/any/none and exact names. Use the untagged kind without values for books with no tags. Author and shelf rules match any listed exact name.
          sorts is in priority order: field recent, name, or author, with descending true or false. Use nodes:[] for a sort-only suggestion and sorts:[] for default order. For tag/author/shelf names, use list_filter_options if uncertain. Use exact names, no IDs, text query or links. A successful suggestion needs no repeated card content in the reply.
          """,
        input: AIBookFilterInput.self, execute: { try await self.proposeBookFilter($0) }),
      .init(
        name: "get_book",
        description:
          "Read metadata. Supply exactly one bookRef or fileRef; omit or null the other. prepare requests confirmation for file preparation.",
        input: AIGetBookInput.self, confirmation: { try await self.confirmBook($0) },
        execute: { try await self.getBook($0) }),
      .init(
        name: "get_chapters",
        description:
          "Read corrected chapter outline. Use query to find a title such as 番外 or 第316章 without paging through the whole outline. Omit cursor on first call; use the returned nextCursor for later pages.",
        input: AIChaptersInput.self, confirmation: { try await self.confirmText([$0.bookRef]) },
        execute: { try await self.chapters($0) }),
      .init(
        name: "read",
        description:
          "Read by chapter/range, or set contextOffsetUtf8 to a hit startUtf8 with beforeParagraphs/afterParagraphs (default 3 each, non-empty paragraphs). Context cannot combine with explicit range. Omit cursor initially; keep query unchanged for pagination. Use tool-provided UTF-8 boundaries.",
        input: AIReadInput.self, confirmation: { try await self.confirmText([$0.bookRef]) },
        execute: { try await self.readText($0) }),
      .init(
        name: "rg",
        description:
          "Search novel text, not a shell command. Example: query=年龄, mode=literal (rg -F); query=年龄|岁, mode=regex. Start with a specific phrase and one book. Search books with literal text or single-line Rust regex. For one book, optionally restrict chapterRef and/or startUtf8/endUtf8 before scanning. Use get_chapters for range boundaries. To inspect a hit call read with its bookRef and contextOffsetUtf8=range.startUtf8, beforeParagraphs=3, afterParagraphs=3; do not calculate byte offsets. Use nextCursor with the same search; maxHits may change between pages. Continue partial searches with nextCursor.",
        input: AIRGInput.self, confirmation: { try await self.confirmText($0.bookRefs) },
        execute: { try await self.searchText($0) }),
      .init(
        name: "get_marks",
        description: "List bookmarks and annotations with short note/excerpt previews. Use get_mark for the full comment and read with the returned range for original text. Conflicts remain explicit.",
        input: AIMarksInput.self, execute: { try await self.marks($0) }),
      .init(
        name: "get_mark",
        description:
          "Read an annotation comment in pages; nextCursor continues the comment, excerpt is only a preview. Use read for full original text. Select variantRef for conflicts; this never resolves a conflict.",
        input: AIMarkInput.self, execute: { try await self.mark($0) }),
      .init(
        name: "get_reading_statistics",
        description:
          "Read recorded local-day statistics for an inclusive date range. Concurrent device durations are summed. Distinguish recorded facts from interpretation when analyzing reading.",
        input: AIStatisticsInput.self, execute: { try await self.statistics($0) }),
      .init(
        name: "get_environment",
        description:
          "Read current time, time zone and application locale. Omit fields for both time and locale.",
        input: AIEnvironmentInput.self, execute: { await self.environment($0) }),
    ].sorted { $0.name < $1.name }
  }
}
