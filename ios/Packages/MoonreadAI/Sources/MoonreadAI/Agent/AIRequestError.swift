import Combine
import Foundation
import Observation
import AISDKProvider
import AISDKProviderUtils

public enum AIRequestError {
    public static func message(_ error: Error) -> String {
        if let value = AIChatGPTResponses.failure(error) { return value.localizedDescription }
        if let value = error as? AIError { return value.localizedDescription }
        if let value = error as? URLError {
            switch value.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                return String(localized: "网络连接中断")
            case .timedOut: return String(localized: "等待回复超时")
            default: break
            }
        }
        if let value = error as? APICallError {
            switch value.statusCode ?? 0 {
            case 401: return String(localized: "当前连接认证失效")
            case 429: return String(localized: "请求受到限制或额度不足")
            case 500...599: return String(localized: "服务暂时不可用")
            case 400, 403, 404, 422: return String(localized: "此次请求未被接受")
            default: break
            }
        }
        return String(localized: "请求未完成")
    }
}
