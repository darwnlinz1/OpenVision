// OpenVision Runtime Configuration
// Auto-generated config file
import Foundation

enum Config {
    // MARK: - Optional Default API Keys
    static let defaultOpenClawGatewayURL = ""
    static let defaultOpenClawAuthToken = ""
    static let defaultGeminiAPIKey = ""

    // MARK: - App Constants
    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    static let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
}
