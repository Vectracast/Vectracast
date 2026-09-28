import Foundation

@objc(LauncherRuntimeProtocol) protocol RuntimeProtocol {
    func evaluate(_ source: String, input: String, debug: Bool, withReply reply: @escaping (String) -> Void)
    func probe(_ path: String, withReply reply: @escaping (String) -> Void)
}

@objc(LauncherBrokerProtocol) protocol BrokerProtocol {
    func perform(_ method: String, payload: String, withReply reply: @escaping (String) -> Void)
}

func jsonString(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]),
          let string = String(data: data, encoding: .utf8) else { return "null" }
    return string
}

func jsonObject(_ value: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any] ?? [:]
}
