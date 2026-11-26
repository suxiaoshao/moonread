import MoonreadCoreBindings
import Observation
import Foundation

@MainActor @Observable public final class PaletteDraft: Identifiable {
    public let id = UUID()
    public var palette: ThemePalette
    public var error: String?
    public let creating: Bool
    private let baseline: ThemePalette
    public var saving = false
    public private(set) var saved = false
    public var hasUnsavedChanges: Bool { !saving && !saved && (creating || palette != baseline) }
    public func markSaved() { saved = true }
    public init(palette: ThemePalette, creating: Bool) { self.palette = palette; baseline = palette; self.creating = creating }
}
