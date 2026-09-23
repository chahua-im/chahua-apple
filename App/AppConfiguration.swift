import ChahuaAPI
import Foundation

enum AppConfiguration {
    static let apiConfiguration: ChahuaConfiguration = {
        guard
            let rawValue = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String,
            let baseURL = URL(string: rawValue),
            let scheme = baseURL.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            baseURL.host != nil
        else {
            preconditionFailure("APIBaseURL is missing or invalid.")
        }

        return ChahuaConfiguration(baseURL: baseURL, appVersion: appVersionHeader)
    }()

    private static var appVersionHeader: String {
        #if os(iOS)
            let platform = "ios"
        #elseif os(macOS)
            let platform = "macos"
        #else
            #error("Unsupported Chahua platform")
        #endif

        guard
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            !version.isEmpty,
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            !build.isEmpty
        else {
            preconditionFailure("App version or build number is missing.")
        }
        return "\(platform)-\(version)-\(build)"
    }
}
