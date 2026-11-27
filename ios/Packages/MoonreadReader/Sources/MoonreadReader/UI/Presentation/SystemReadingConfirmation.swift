import SwiftUI

@MainActor public protocol ReaderSystemConfirmation: AnyObject {
    var requestID: UUID { get }
    var confirmationTitle: String? { get }
    var requestError: String? { get set }
    func presentsConfirmation(active: Bool, editor: Bool) -> Bool
    func answerConfirmation(discard: Bool, expectedID: UUID?)
}

extension EnvironmentValues {
    @Entry public var systemReadingRouter: (any ReaderSystemConfirmation)? = nil
}
public struct SystemReadingConfirmation: ViewModifier {
    public init(editor: Bool = false, active: Bool = true) {
        self.editor = editor
        self.active = active
    }

    var editor = false
    var active = true
    @Environment(\.systemReadingRouter) private var router
    public func body(content: Content) -> some View {
        let requestID = router?.requestID
        return content.alert(Text(router?.confirmationTitle.map { String(format: String(localized: "放弃未保存的修改并打开《%@》？"), $0) } ?? String(localized: "暂时无法完成")), isPresented: Binding(get: {
            router?.presentsConfirmation(active: active, editor: editor) == true
        }, set: { if !$0, router?.requestID == requestID { router?.answerConfirmation(discard: false, expectedID: requestID); router?.requestError = nil } })) {
            if router?.confirmationTitle != nil {
                Button("取消", role: .cancel) { router?.answerConfirmation(discard: false, expectedID: requestID) }
                Button("放弃修改并打开", role: .destructive) { router?.answerConfirmation(discard: true, expectedID: requestID) }
            } else { Button("知道了") { router?.requestError = nil } }
        } message: { if let error = router?.requestError { Text(error) } }
    }
}
