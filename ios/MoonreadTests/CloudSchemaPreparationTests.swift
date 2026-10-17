import XCTest
import CoreData
@testable import Moonread

final class CloudSchemaPreparationTests: XCTestCase {
    func testGeneratedModelMatchesExactlyTheSixUserTypesWithoutAIEntities() throws {
        let model = try CloudSchemaPreparation.model()
        XCTAssertEqual(Set(model.entities.compactMap(\.name)), Set(["UserPosition", "UserValue", "AnnotationOperation", "ReadingFact", "StatisticsClear", "UserCover"]))
        let cover = try XCTUnwrap(model.entities.first { $0.name == "UserCover" })
        XCTAssertTrue(try XCTUnwrap(cover.attributesByName["bytes"]).allowsExternalBinaryDataStorage)
        for entity in model.entities {
            XCTAssertTrue(entity.uniquenessConstraints.isEmpty)
            XCTAssertTrue(entity.relationshipsByName.values.allSatisfy(\.isOptional))
        }
        let report = try CloudSchemaPreparation.report()
        XCTAssertTrue(report.contains("UserCover")); XCTAssertTrue(report.contains("external=true"))
        XCTAssertFalse(report.contains("AISession"))
    }
}
