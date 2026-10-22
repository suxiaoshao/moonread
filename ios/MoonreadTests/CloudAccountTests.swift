import CryptoKit
import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class CloudAccountReaderIntegrationTests: ReaderIntegrationFixture {
  // S323: 当前账户发现失败不清空已知书架，旧账户/超时代次的晚到回调不得发布；两个确定事件顺序。
  @MainActor func testBuiltinDiscoveryFailureAndStaleAccountDoNotPublishEmpty() async throws {
    let (root, service, _, _, _, _, _, suite) = try singleBookFixture()
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    let model = LibraryModel(
      service: service, prepareLibrary: {}, refreshLibrary: {},
      cloudDiscoveryRequired: true, adoptCloudDocuments: { _ in throw CocoaError(.fileReadUnknown) }
    )
    let old = model.discoveryGeneration
    model.failCloudDiscovery(old)  // Both query-start failure and the timeout use this boundary.
    XCTAssertEqual(model.builtinDiscovery, .unavailable)
    model.resetCloudDiscovery()
    XCTAssertNotEqual(model.discoveryGeneration, old)
    model.receiveCloudDiscovery(.init(generation: old, revision: 99, gathered: true, items: []))
    model.builtinDirectoryLoaded(generation: old, snapshotRevision: 99)
    model.failCloudDiscovery(old)
    XCTAssertEqual(model.builtinDiscovery, .discovering)
    XCTAssertEqual(model.discoveryRevision, 0)
    model.failCloudDiscovery(model.discoveryGeneration)
    XCTAssertEqual(model.builtinDiscovery, .unavailable)
    CloudDocumentQuery.shared.stop()
  }
}

final class CloudAccountCloudAccountTests: CloudAccountFixture {
  // S481: 临时不可用/退出账户保留用户同步意图，明确关闭才改意图，防错误切换本地数据。
  func testUnavailableSignOutAndExplicitOffPreserveIntentCorrectly() async throws {
    let (service, coordinator, probe, suite) = try fixture()
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    await coordinator.setEnabled(true)
    var status = await coordinator.currentStatus()
    XCTAssertTrue(status.requested)
    XCTAssertTrue(status.enabled)
    await probe.set([nil])
    await coordinator.identityChanged()
    status = await coordinator.currentStatus()
    XCTAssertTrue(status.requested)
    XCTAssertFalse(status.enabled)
    let requested = await service.cloudSyncRequested()
    XCTAssertTrue(requested)
    await probe.set(["A"])
    await coordinator.resume()
    status = await coordinator.currentStatus()
    XCTAssertTrue(status.enabled)
    await coordinator.setEnabled(false)
    await coordinator.resume()
    status = await coordinator.currentStatus()
    XCTAssertFalse(status.requested)
    XCTAssertFalse(status.enabled)
    let (unsupportedService, unsupported, _, unsupportedSuite) = try fixture(available: false)
    defer {
      UserDefaults(suiteName: unsupportedSuite)?.removePersistentDomain(forName: unsupportedSuite)
    }
    await unsupported.setEnabled(true)
    let unsupportedIntent = await unsupportedService.cloudSyncRequested()
    XCTAssertTrue(unsupportedIntent)
    let unsupportedStatus = await unsupported.currentStatus()
    XCTAssertFalse(unsupportedStatus.enabled)
  }

  // S482: 切换账户必须用户确认，旧账户确认和初始化失败不授权新账户；两个确定 gate。
  @MainActor func testDifferentAccountCancelRepeatedRefreshAndConsent() async throws {
    let (service, coordinator, probe, suite) = try fixture()
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    await coordinator.setEnabled(true)
    await probe.set(["B"])
    await coordinator.identityChanged()
    let cloud = CloudStore(coordinator: coordinator)
    await cloud.updateStatus()
    XCTAssertTrue(cloud.status.requested)
    XCTAssertFalse(cloud.status.enabled)
    XCTAssertEqual(cloud.status.accountToConfirm, "B")
    XCTAssertNil(cloud.confirmationAccount)
    cloud.requestConfirmation()
    XCTAssertEqual(cloud.confirmationAccount, "B")
    cloud.confirmationAccount = nil  // Cancel does not touch persistent intent or configuration.
    await coordinator.resume()
    await cloud.updateStatus()
    XCTAssertNil(cloud.confirmationAccount)
    let before = await probe.configurations
    XCTAssertEqual(before.filter { $0 }.count, 1)
    let ownerBefore = await service.userCloudOwner()
    XCTAssertEqual(ownerBefore, "A")
    await coordinator.confirmAccount("B")
    let status = await coordinator.currentStatus()
    XCTAssertTrue(status.enabled)
    XCTAssertNil(status.accountToConfirm)
    let owner = await service.userCloudOwner()
    XCTAssertEqual(owner, "B")
    // A stale account approval cannot authorize the replacement account.
    do {

      let (service, coordinator, probe, suite) = try fixture()
      defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
      await probe.fail()
      await coordinator.setEnabled(true)
      var status = await coordinator.currentStatus()
      XCTAssertTrue(status.requested)
      XCTAssertFalse(status.enabled)
      await coordinator.resume()
      status = await coordinator.currentStatus()
      XCTAssertTrue(status.enabled)
      await probe.set(["B"])
      await coordinator.identityChanged()
      await probe.set(["B", "C"])
      await coordinator.confirmAccount("B")
      status = await coordinator.currentStatus()
      XCTAssertFalse(status.enabled)
      XCTAssertEqual(status.accountToConfirm, "C")
      let ownerBefore = await service.userCloudOwner()
      XCTAssertEqual(ownerBefore, "A")
      await probe.fail()
      await coordinator.confirmAccount("C")
      status = await coordinator.currentStatus()
      XCTAssertTrue(status.requested)
      XCTAssertFalse(status.enabled)
      let owner = await service.userCloudOwner()
      XCTAssertEqual(owner, "C")
      await coordinator.resume()
      status = await coordinator.currentStatus()
      XCTAssertTrue(status.enabled)
      XCTAssertNil(status.accountToConfirm)

    }
  }
}
