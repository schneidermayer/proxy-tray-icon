import Foundation

struct SshSettings: Codable {
    var host: String
    var username: String
    var port: Int

    static let defaultSettings = SshSettings(host: "example.com", username: "user", port: 22)
}
