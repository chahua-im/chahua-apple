import Foundation

protocol CredentialLoginProviding: Sendable {
    func login(username: String, password: String) async throws -> String?
}

enum CredentialLoginError: Error, Sendable { case unavailable }

struct PrototypeCredentialLoginClient: CredentialLoginProviding {
    private static let endpoint = URL(string: "https://www.shireyishunjian.com/main/shireyishunjian-telegram-api/chahua_login.php")!
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    func login(username: String, password: String) async throws -> String? {
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = Data("username=\(encode(username))&password=\(encode(password))".utf8)
        do {
            let (data, response) = try await session.data(for: request)
            guard response is HTTPURLResponse else { throw CredentialLoginError.unavailable }
            let candidate = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return candidate?.isEmpty == false ? candidate : nil
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw CredentialLoginError.unavailable }
    }

    private func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
    }
}
