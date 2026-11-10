import CoreText
import Foundation
import Observation
import UIKit

/// Core Text and file access are platform facts; stable resource IDs and the
/// versioned manifest are validated by Rust. Nothing is installed system-wide.
@MainActor @Observable
final class ReaderFontLibrary {
    static let shared = ReaderFontLibrary()
    private(set) var resources: [ReaderFontResource] = []
    private(set) var available: Set<String> = []
    private(set) var revision = 0
    private(set) var busy = false
    private(set) var error: String?
    private var loaded = false
    private var manifestReadable = true
    let root: URL
    @ObservationIgnored private let register: (URL) throws -> Void
    @ObservationIgnored private let unregister: (URL) throws -> Void

    init(root: URL = URL.applicationSupportDirectory.appendingPathComponent("ReaderFonts", isDirectory: true),
         register: @escaping (URL) throws -> Void = ReaderFontPlatform.register,
         unregister: @escaping (URL) throws -> Void = ReaderFontPlatform.unregister) {
        self.root = root; self.register = register; self.unregister = unregister
    }
    private var manifest: URL { root.appendingPathComponent("manifest.json") }
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        do {
            if FileManager.default.fileExists(atPath: manifest.path) {
                resources = try decodeReaderFontManifest(json: String(contentsOf: manifest, encoding: .utf8))
            }
        } catch {
            manifestReadable = false
            self.error = String(localized: "无法读取字体清单，原有文件已保留。")
            return
        }
        for resource in resources {
            do { try register(root.appendingPathComponent(resource.relativePath)); available.insert(resource.sha256) }
            catch { /* Keep its reference and row; the renderer temporarily uses System. */ }
        }
        revision += 1
    }
    func isAvailable(_ font: ImportedReaderFont) -> Bool {
        available.contains(font.resourceSha256) && resources.contains {
            $0.sha256 == font.resourceSha256 && $0.faces.contains { $0.postscriptName == font.face }
        }
    }
    func name(for font: ImportedReaderFont) -> String {
        resources.first { $0.sha256 == font.resourceSha256 }?.faces.first { $0.postscriptName == font.face }?.displayName ?? font.face
    }
    private func write(_ resources: [ReaderFontResource]) throws {
        let json = try encodeReaderFontManifest(resources: resources)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: manifest, options: .atomic)
    }

    func importFile(_ url: URL) async throws -> ReaderFontResource {
        loadIfNeeded()
        guard manifestReadable else { throw ReaderFontFailure.unreadableManifest }
        guard !busy else { throw ReaderFontFailure.busy }
        busy = true
        defer { busy = false }
        let access = ProtectedFileAccess(), probe = SourceIdentityProbe()
        let source = ProtectedFileAccess.Source(selectedFile: url)
        let ext = url.pathExtension.lowercased()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staged = root.appendingPathComponent("import-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: staged) }
        var resource = try await withTaskCancellationHandler {
            try await access.readAsync(at: source.url) { coordinated in
                try source.requireContained(coordinated)
                try FileManager.default.copyItem(at: coordinated, to: staged)
                try access.checkCancellation()
                let sha = try probe.rawSha256(filePath: staged.path)
                let faces = try ReaderFontPlatform.faces(at: staged)
                do { return try makeReaderFontResource(sha256: sha, extension: ext, sourceName: url.lastPathComponent, faces: faces) }
                catch { throw ReaderFontFailure.invalidFont }
            }
        } onCancel: { access.cancel(); probe.cancel() }
        try Task.checkCancellation()
        if let existing = resources.first(where: { $0.sha256 == resource.sha256 }) {
            if available.contains(existing.sha256) { return existing }
            resource = existing
        }
        // Validate both catalogue collisions and Core Text's existing system/process
        // names before registration, so no other resource can be overwritten.
        let next = resources.filter { $0.sha256 != resource.sha256 } + [resource]
        for face in resource.faces {
            if UIFont(name: face.postscriptName, size: 20) != nil || resources.contains(where: { $0.sha256 != resource.sha256 && $0.faces.contains { $0.postscriptName == face.postscriptName } }) {
                throw ReaderFontFailure.nameConflict(face.postscriptName)
            }
        }
        _ = try encodeReaderFontManifest(resources: next)
        let destination = root.appendingPathComponent(resource.relativePath)
        // A stale/unregisterable copy may be replaced only by the same raw SHA.
        // The source remains untouched; copy completes before process registration.
        let hadFile = FileManager.default.fileExists(atPath: destination.path)
        if hadFile { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged) }
        else { try FileManager.default.moveItem(at: staged, to: destination) }
        do {
            try register(destination)
            try write(next)
        } catch {
            try? unregister(destination)
            // Preserve an existing resource on failure, including a missing-font
            // reimport attempt. A newly copied resource has not been committed.
            if !hadFile { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
        resources = next; available.insert(resource.sha256); revision += 1
        return resource
    }

    func remove(_ resource: ReaderFontResource, settings: ReaderSettingsStore) async throws {
        guard !busy, !settings.fontSaving else { throw ReaderFontFailure.busy }
        busy = true
        defer { busy = false }
        if settings.value?.importedFont?.resourceSha256 == resource.sha256 {
            try await settings.selectFont(.builtin(font: .system))
        }
        let next = resources.filter { $0.sha256 != resource.sha256 }
        let url = root.appendingPathComponent(resource.relativePath)
        let wasAvailable = available.contains(resource.sha256)
        // Prepare the new manifest first, but keep the old catalogue in memory
        // until file removal succeeds. A failed delete retains its row for retry.
        try write(next)
        var unregistered = false
        do {
            if wasAvailable { try unregister(url); unregistered = true }
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } catch {
            do { try write(resources) } catch { manifestReadable = false }
            if unregistered {
                do { try register(url) }
                catch { available.remove(resource.sha256); revision += 1 }
            }
            throw error
        }
        resources = next; available.remove(resource.sha256); revision += 1
    }
}

enum ReaderFontFailure: LocalizedError {
    case invalidFont, unreadableManifest, busy, nameConflict(String)
    var errorDescription: String? {
        switch self {
        case .invalidFont: String(localized: "这个文件没有可用的字体。")
        case .unreadableManifest: String(localized: "无法读取字体清单，原有文件已保留。")
        case .busy: String(localized: "正在处理字体，请稍后再试。")
        case .nameConflict(let name): String(format: String(localized: "字体内部名称“%@”已被使用，请先移除旧文件或选择其他字体。"), name)
        }
    }
}

private enum ReaderFontPlatform {
    nonisolated static func faces(at url: URL) throws -> [ReaderFontFace] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], !descriptors.isEmpty else { throw ReaderFontFailure.invalidFont }
        return try descriptors.map {
            guard let name = CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String else { throw ReaderFontFailure.invalidFont }
            return ReaderFontFace(postscriptName: name, displayName: CTFontDescriptorCopyAttribute($0, kCTFontDisplayNameAttribute) as? String ?? name)
        }
    }
    nonisolated static func register(_ url: URL) throws {
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) else {
            throw error?.takeRetainedValue() as Error? ?? ReaderFontFailure.invalidFont
        }
        // Font collections must expose every face, not just a usable first face.
        do {
            for face in try faces(at: url) {
                let font = CTFontCreateWithName(face.postscriptName as CFString, 20, nil)
                guard CTFontCopyPostScriptName(font) as String == face.postscriptName else { throw ReaderFontFailure.invalidFont }
            }
        } catch { try? unregister(url); throw error }
    }
    nonisolated static func unregister(_ url: URL) throws {
        var error: Unmanaged<CFError>?
        guard CTFontManagerUnregisterFontsForURL(url as CFURL, .process, &error) else {
            throw error?.takeRetainedValue() as Error? ?? ReaderFontFailure.invalidFont
        }
    }
}
