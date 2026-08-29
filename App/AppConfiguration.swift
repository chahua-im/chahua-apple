import Foundation
import ChahuaAPI

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

        return ChahuaConfiguration(baseURL: baseURL)
    }()
}
