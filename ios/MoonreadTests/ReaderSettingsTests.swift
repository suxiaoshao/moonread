import CryptoKit
import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class ReaderSettingsAppStorePrivacyTests: AppStorePrivacyFixture {
  // S250: 已发布设置 raw value 保持可读，不因本地化改键；删错误文案逐字匹配，存储不重置由 Rust 迁移测试。
  func testReleaseSettingsUseStableIdentifiersAndStoreErrorsPreserveData() {
    XCTAssertEqual(
      ReadingSettingsTab.allCases.map(\.rawValue), ["typography", "colors", "controls"])
    XCTAssertNil(ReadingSettingsTab(rawValue: "排版"))
    XCTAssertFalse(ReaderMessages.error(ReaderError.IncompatibleStore).contains("重新安装"))
    XCTAssertEqual(
      ReaderMessages.error(ReaderError.StoreTooNew(version: 21, current: 20)),
      String(localized: "数据由更新版本的月读创建，请更新应用后再打开。"))
  }
}

final class ReaderSettingsReaderIntegrationTests: ReaderIntegrationFixture {
  // S343: 内存设置只发布经过 Rust 验证且持久化成功的值，失败不污染当前读者配置。
  @MainActor func testSettingsMemoryCopyTracksValidatedPersistence() async throws {
    let (root, service, _, _, _, _, _, suite) = try singleBookFixture()
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    var settings = try service.settings()
    settings.fontSize = 23
    settings.lineSpacing = 9
    try await service.saveSettings(settings)
    XCTAssertEqual(try service.settings(), settings)
    XCTAssertEqual(
      try decodeReaderSettings(
        json: UserDefaults(suiteName: suite)!.string(forKey: "Moonread.readerSettings")!), settings)
  }

  // S418: 设置连续编辑只发布最终已保存值，保存失败回退最后成功值；不锁 coalescing 写次数。
  @MainActor
  func testThemePreferenceFailureRollsBackToLastSavedEdit() async {
    let writer = ThemePreferenceWriterProbe()
    let store = ThemeStore(persistPreferences: writer.save)
    writer.snapshot = store.snapshot
    let firstWrite = expectation(description: "First write")
    let nextWrite = expectation(description: "Queued write")
    writer.started = { count in
      if count == 1 { firstWrite.fulfill() }
      if count == 2 { nextWrite.fulfill() }
    }
    store.update {
      $0.reduceMotion.toggle()
      $0.readerLightTexture = ReaderTextureChoice(id: .paper, strength: .medium)
      $0.readerDarkTexture = nil
    }
    let saved = store.snapshot.preferences
    await fulfillment(of: [firstWrite], timeout: 2)
    store.update {
      $0.readerMode = $0.readerMode == .dark ? .light : .dark
      $0.readerDarkTexture = ReaderTextureChoice(id: .grain, strength: .strong)
    }
    let newer = store.snapshot.preferences
    writer.succeed()
    await fulfillment(of: [nextWrite], timeout: 2)
    XCTAssertEqual(store.snapshot.preferences, newer)
    writer.fail()
    await store.flushPreferences()
    XCTAssertEqual(store.snapshot.preferences, saved)
    XCTAssertEqual(store.snapshot.preferences.readerLightTexture, ReaderTextureChoice(id: .paper, strength: .medium))
    XCTAssertNil(store.snapshot.preferences.readerDarkTexture)
    XCTAssertNotNil(store.error)
    XCTAssertFalse(store.saving)
  }
}

final class ReaderSettingsUserDataTests: UserDataFixture {
  // S484: 共享配色保存不带设备选择偏好，删除当前配色只让本机选择回退；Rust 编解码和 Swift 写入边界分开。
  @MainActor func testPaletteStorageDoesNotCaptureDevicePreferences() async throws {
    let (root, service, _, store) = try await editorFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var template = defaultThemeSnapshot().palettes[0]
    template.name = "Independent"
    template.colors.ink = template.colors.paper
    XCTAssertFalse(themeColorsReadable(c: template.colors))
    XCTAssertTrue(template.isValidDraft)
    let palette = try await service.savePalette(template, creating: true)
    let rows = try await store.allValues(prefix: "palette/")
    let json = try XCTUnwrap(rows["palette/\(palette.id)"])
    let stored = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    XCTAssertNil(stored["preferences"])
    XCTAssertNil(stored["palettes"])
    var preferences = defaultThemeSnapshot().preferences
    preferences.appLight = .palette(id: palette.id)
    preferences.readerLightTexture = ReaderTextureChoice(id: .linen, strength: .medium)
    preferences.readerDarkTexture = ReaderTextureChoice(id: .grain, strength: .strong)
    let selected = try await service.saveThemes(preferences)
    XCTAssertEqual(selected.preferences.appLight, .palette(id: palette.id))
    let reloaded = try await service.themes()
    XCTAssertEqual(reloaded.preferences.readerLightTexture, preferences.readerLightTexture)
    XCTAssertEqual(reloaded.preferences.readerDarkTexture, preferences.readerDarkTexture)
    let deleted = try await service.deletePalette(palette.id)
    XCTAssertEqual(deleted.preferences.appLight, defaultThemeSnapshot().preferences.appLight)
    XCTAssertFalse(deleted.palettes.contains { $0.id == palette.id })
    XCTAssertEqual(deleted.preferences.readerLightTexture, preferences.readerLightTexture)
    XCTAssertEqual(deleted.preferences.readerDarkTexture, preferences.readerDarkTexture)
  }
}
