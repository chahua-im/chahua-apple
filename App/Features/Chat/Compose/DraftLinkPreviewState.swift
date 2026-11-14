import ChahuaAPI
import Combine
import Foundation

/// Local discovery only. Metadata and thumbnails are always supplied by the server.
enum DraftLinkURLs {
    private static let detector = try! NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func extract(_ text: String) -> [String] {
        let source = text as NSString
        var seen = Set<String>()
        return detector.matches(in: text, range: NSRange(location: 0, length: source.length))
            .compactMap { match in
                let raw = source.substring(with: match.range)
                guard raw.lowercased().hasPrefix("https://"), !raw.contains("\\"),
                    !raw.dropFirst(8).prefix(while: { !"/?#".contains($0) }).contains("@"),
                    match.range.upperBound == source.length
                        || source.substring(
                            with: NSRange(location: match.range.upperBound, length: 1)) != "@",
                    var components = URLComponents(string: raw), components.user == nil,
                    components.password == nil, components.port == nil || components.port == 443,
                    let host = components.url?.host, !host.hasPrefix("["), !host.contains(":"),
                    host.range(
                        of: #"(?:^|\.)[0-9]+\.?$|(?:^|\.)0[xX][0-9a-fA-F]+\.?$"#,
                        options: .regularExpression) == nil
                else { return nil }
                components.scheme = "https"
                components.host = host.lowercased()
                components.port = nil
                if components.path.isEmpty { components.path = "/" }
                guard let url = components.url?.absoluteString, url.count <= 4096,
                    seen.insert(url).inserted
                else { return nil }
                return url
            }
    }

    static func choices(_ choices: [LinkPreviewInput], in text: String) -> [LinkPreviewInput] {
        Self.choices(choices, in: extract(text))
    }

    static func choices(_ choices: [LinkPreviewInput], in urls: [String]) -> [LinkPreviewInput] {
        urls.compactMap { url in
            guard let choice = choices.last(where: { $0.url == url }) else { return nil }
            // Never send cached draft images (which may be data URLs) back as imageUrl.
            return LinkPreviewInput(url: url, status: choice.status)
        }
    }

    static func disabledURLs(_ choices: [LinkPreviewInput]) -> Set<String> {
        Set(choices.filter { $0.status == .disabled }.map(\.url))
    }
}

@MainActor
final class DraftLinkPreviewState: ObservableObject {
    @Published private(set) var urls: [String] = []
    @Published private(set) var choices: [LinkPreviewInput] = []
    @Published private(set) var results: [String: MessageLinkPreview] = [:]
    @Published private(set) var pending = Set<String>()
    @Published private(set) var isManagementOpen = false

    private var scope: String?
    private var generation = UUID()
    private var text = ""
    private var automatic = false
    private var scheduled: Task<Void, Never>?
    private var requests: [String: Task<Void, Never>] = [:]
    private var requestIDs: [String: UUID] = [:]
    private var fetch: (([String]) async throws -> [MessageLinkPreview])?
    private var saveChoices: (([LinkPreviewInput]) -> Void)?

    var selected: [String] {
        Array(urls.filter { !isDisabled($0) }.prefix(3))
    }

    var firstReady: MessageLinkPreview? {
        selected.compactMap { results[$0] }.first { $0.status == .ready }
    }

    var fallbackURL: String? {
        guard firstReady == nil else { return nil }
        return selected.first { results[$0]?.status == .unavailable }
    }

    func isDisabled(_ url: String) -> Bool {
        choices.contains { $0.url == url && $0.status == .disabled }
    }

    func configure(
        scope: String, text: String, automatic: Bool, choices: [LinkPreviewInput],
        initial: [MessageLinkPreview],
        fetch: @escaping ([String]) async throws -> [MessageLinkPreview],
        saveChoices: @escaping ([LinkPreviewInput]) -> Void
    ) {
        let changedScope = self.scope != scope
        let changedText = self.text != text
        if changedScope {
            invalidate()
            self.scope = scope
            results = Dictionary(
                initial.filter { $0.status == .ready || $0.status == .unavailable }
                    .map { ($0.url, $0) }, uniquingKeysWith: { _, last in last })
        }
        self.text = text
        self.automatic = automatic
        self.fetch = fetch
        self.saveChoices = saveChoices
        urls = DraftLinkURLs.extract(text)
        self.choices = DraftLinkURLs.choices(choices, in: urls)
        let retained = Set(urls)
        results = results.filter { retained.contains($0.key) }
        for url in Array(requests.keys) where !retained.contains(url) {
            requests.removeValue(forKey: url)?.cancel()
            requestIDs.removeValue(forKey: url)
            pending.remove(url)
        }
        if self.choices != choices { saveChoices(self.choices) }
        schedule(debounce: (changedText && !changedScope) || scheduled != nil)
    }

    func setManagementOpen(_ open: Bool) {
        isManagementOpen = open
        schedule(debounce: false)
    }

    func toggle(_ url: String) {
        guard urls.contains(url) else { return }
        let status: LinkPreviewInput.Status = isDisabled(url) ? .enabled : .disabled
        choices.removeAll { $0.url == url }
        choices.append(LinkPreviewInput(url: url, status: status))
        choices = DraftLinkURLs.choices(choices, in: urls)
        saveChoices?(choices)
        schedule(debounce: false)
    }

    /// Fences responses even when the transport cannot cancel an already sent request.
    func invalidate() {
        suspend()
        scope = nil
        urls = []
        choices = []
        results = [:]
    }

    func suspend() {
        generation = UUID()
        scheduled?.cancel()
        scheduled = nil
        for request in requests.values { request.cancel() }
        requests.removeAll()
        requestIDs.removeAll()
        pending.removeAll()
        isManagementOpen = false
        fetch = nil
        saveChoices = nil
    }

    private func schedule(debounce: Bool) {
        scheduled?.cancel()
        scheduled = nil
        guard isManagementOpen || automatic else { return }
        if debounce {
            scheduled = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.scheduled = nil
                self?.loadTargets()
            }
        } else {
            loadTargets()
        }
    }

    private func loadTargets() {
        guard scheduled == nil else { return }
        if isManagementOpen {
            for url in selected where results[url] == nil { load(url) }
        } else if automatic {
            // A failure consumes a slot; only a disabled URL lets a later URL move up.
            for url in selected {
                if results[url]?.status == .ready { return }
                if results[url] == nil {
                    load(url)
                    return
                }
            }
        }
    }

    private func load(_ url: String) {
        guard requestIDs[url] == nil, let fetch else { return }
        let generation = generation
        let requestID = UUID()
        requestIDs[url] = requestID
        pending.insert(url)
        requests[url] = Task { [weak self] in
            let result: MessageLinkPreview
            do {
                let previews = try await fetch([url])
                result =
                    previews.first(where: { $0.url == url })
                    ?? MessageLinkPreview(url: url, status: .unavailable)
            } catch {
                result = MessageLinkPreview(url: url, status: .unavailable)
            }
            guard let self, self.generation == generation,
                self.requestIDs[url] == requestID, self.urls.contains(url)
            else { return }
            self.results[url] = result
            self.requestIDs.removeValue(forKey: url)
            self.requests.removeValue(forKey: url)
            self.pending.remove(url)
            self.loadTargets()
        }
    }
}
