import CoreData
import XCTest

@testable import Moonread

final class CloudSchemaPreparationTests: CloudSchemaPreparationFixture {
  // S252: 云用户模型集合不得混入 AI 会话/凭据；仅断言本应用持久化 schema 的允许类型，删 CoreData 自动属性和日志格式。
  func testGeneratedModelMatchesExactlyTheSixUserTypesWithoutAIEntities() throws {
    let model = try CloudSchemaPreparation.model()
    XCTAssertEqual(
      Set(model.entities.compactMap(\.name)),
      Set([
        "UserPosition", "UserValue", "AnnotationOperation", "ReadingFact", "StatisticsClear",
        "UserCover",
      ]))
    let cover = try XCTUnwrap(model.entities.first { $0.name == "UserCover" })
    XCTAssertTrue(try XCTUnwrap(cover.attributesByName["bytes"]).allowsExternalBinaryDataStorage)
    for entity in model.entities {
      XCTAssertTrue(entity.uniquenessConstraints.isEmpty)
      XCTAssertTrue(entity.relationshipsByName.values.allSatisfy(\.isOptional))
    }
    let report = try CloudSchemaPreparation.report()
    XCTAssertTrue(report.contains("UserCover"))
    XCTAssertTrue(report.contains("external=true"))
    XCTAssertFalse(report.contains("AISession"))
  }
}
