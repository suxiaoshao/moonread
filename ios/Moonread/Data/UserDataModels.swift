import Foundation
import SwiftData
import CoreData

// No unique constraints or required relationships: CloudKit may deliver independent
// records out of order. Logical identity and causal reduction belong to this service.
@Model final class UserValue {
    var key: String = ""
    var device: String = ""
    var payload: String = ""
    init(key: String, device: String, payload: String) { self.key = key; self.device = device; self.payload = payload }
}
@Model final class UserPosition {
    var contentKey: String = ""
    var payload: String = ""
    init(contentKey: String, payload: String) { self.contentKey = contentKey; self.payload = payload }
}
@Model final class AnnotationOperation {
    var id: String = ""
    var contentKey: String = ""
    var markID: String = ""
    var payload: String = ""
    init(id: String, contentKey: String, markID: String, payload: String) {
        self.id = id; self.contentKey = contentKey; self.markID = markID; self.payload = payload
    }
}
@Model final class ReadingFact {
    var id: String = ""
    var contentKey: String = ""
    var payload: String = ""
    init(id: String, contentKey: String, payload: String) { self.id = id; self.contentKey = contentKey; self.payload = payload }
}
@Model final class StatisticsClear {
    var payload: String = ""
    init(payload: String) { self.payload = payload }
}
@Model final class UserCover {
    var id: String = ""
    @Attribute(.externalStorage) var bytes: Data?
    init(id: String, bytes: Data) { self.id = id; self.bytes = bytes }
}
