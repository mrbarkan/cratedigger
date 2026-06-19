import Foundation

public struct SubsonicConfig: Codable, Hashable, Sendable {
    public var url: String
    public var username: String
    public var password: String

    public init(url: String = "", username: String = "", password: String = "") {
        self.url = url
        self.username = username
        self.password = password
    }

    public var isValid: Bool {
        !url.isEmpty && !username.isEmpty && !password.isEmpty
    }
}
