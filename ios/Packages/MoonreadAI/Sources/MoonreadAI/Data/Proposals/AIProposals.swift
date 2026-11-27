import MoonreadCoreBindings
import Foundation

public enum AIMetadataFieldKind: String, Codable, CaseIterable, Sendable { case author, synopsis, tags, readingStatus }
public enum AITagsMode: String, Codable, CaseIterable, Sendable { case merge, replace }
public struct AIMetadataRenameInput: Codable, Sendable {
    public var fileRef: String; public var name: String
    public init(fileRef: String, name: String) { self.fileRef = fileRef; self.name = name }
}
public struct AIMetadataRenameProposal: Codable, Sendable {
    public var fileRef: String
    public var name: String
    public var originalName: String
    public var source: AIFileSnapshot
    public init(fileRef: String, name: String, originalName: String, source: AIFileSnapshot) { self.fileRef = fileRef; self.name = name; self.originalName = originalName; self.source = source }
    public func filename(stem: String) throws -> String {
        let stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try validateLibraryName(input: stem, profile: .aiRename) }
        catch LibraryInputError.Backslash { throw AIToolError("invalid_argument", field: "rename.name") }
        catch { throw ReaderError.InvalidSettings }
        let ext = (originalName as NSString).pathExtension
        return ext.isEmpty ? stem : stem + "." + ext
    }
}
public struct AIMetadataProposal: Codable, Sendable, Identifiable {
    public var proposalRef: String
    public var bookRef: String
    public var author: String?
    public var synopsis: String?
    public var tags: [String]?
    public var tagsMode: AITagsMode?
    public var readingStatus: AIReadingStatus?
    public var sourceRefs: [String]?
    public var rename: AIMetadataRenameProposal?
    public init(proposalRef: String, bookRef: String, author: String? = nil, synopsis: String? = nil, tags: [String]? = nil, tagsMode: AITagsMode? = nil, readingStatus: AIReadingStatus? = nil, sourceRefs: [String]? = nil, rename: AIMetadataRenameProposal? = nil) {
        self.proposalRef = proposalRef; self.bookRef = bookRef; self.author = author; self.synopsis = synopsis; self.tags = tags; self.tagsMode = tagsMode; self.readingStatus = readingStatus; self.sourceRefs = sourceRefs; self.rename = rename
    }
    public var id: String { proposalRef }
}
/// Stored locally with the committed tool result, outside the provider message.
public struct AINotePreview: Codable, Equatable, Sendable {
    public let chapter: String?
    public let excerpt: String

    public init(chapter: String?, excerpt: String) {
        self.chapter = chapter
        self.excerpt = excerpt
    }
}

public struct AINoteProposal: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case note, bookmark }
    public var proposalRef: String
    public var bookRef: String
    public var kind: Kind
    public var startUtf8: UInt64
    public var endUtf8: UInt64
    public var note: String
    public var markRef: String?
    public init(proposalRef: String, bookRef: String, kind: Kind, startUtf8: UInt64, endUtf8: UInt64, note: String, markRef: String? = nil) { self.proposalRef = proposalRef; self.bookRef = bookRef; self.kind = kind; self.startUtf8 = startUtf8; self.endUtf8 = endUtf8; self.note = note; self.markRef = markRef }
    public var id: String { proposalRef }
}
public enum AIProposalSnapshot: Codable, Sendable {
    case metadata(AIMetadataProposal), notes(AINoteProposal), cover(AICoverProposal), organization(AIOrganizationProposal)
    public var proposalRef: String {
        switch self { case .metadata(let p): p.proposalRef; case .notes(let p): p.proposalRef; case .cover(let p): p.proposalRef; case .organization(let p): p.proposalRef }
    }
}
