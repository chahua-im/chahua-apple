import ChahuaAPI
import Combine
import Foundation

@MainActor
final class JoinGroupModel: ObservableObject {
    @Published var input: String {
        didSet {
            if GroupInviteLink.code(from: oldValue) != parsedCode { cancel() }
        }
    }
    @Published private(set) var preview: GroupInvitePreview?
    @Published private(set) var isLoadingPreview = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var completed = false
    @Published private(set) var error: String?
    @Published private(set) var canRetryPreview = false
    @Published private var eligibilityDate = Date()

    private let store: ChatStore
    private let initialInput: String
    private let accountUID: Int32?
    private let sessionRevision: Int
    private var lookupGeneration = 0
    private var attemptedInitialLookup = false
    private var previewTask: Task<Void, Never>?
    private var submissionTask: Task<ChatListItem?, Never>?
    private var expiryTask: Task<Void, Never>?
    private var observations = Set<AnyCancellable>()

    init(store: ChatStore, initialCode: String) {
        self.store = store
        initialInput = initialCode
        input = initialCode
        accountUID = store.currentUserProfile?.uid
        sessionRevision = store.sessionRevision
        store.$currentUserProfile.map { $0?.uid }.removeDuplicates().dropFirst()
            .sink { [weak self] uid in
                guard let self, uid != self.accountUID else { return }
                self.cancel()
            }
            .store(in: &observations)
        store.$sessionRevision.dropFirst()
            .sink { [weak self] revision in
                guard let self, revision != self.sessionRevision else { return }
                self.cancel()
            }
            .store(in: &observations)
    }

    deinit {
        previewTask?.cancel()
        submissionTask?.cancel()
        expiryTask?.cancel()
    }

    var parsedCode: String? { GroupInviteLink.code(from: input) }
    var isDirty: Bool { !completed && input != initialInput }
    var isCurrentSession: Bool {
        accountUID != nil && store.currentUserProfile?.uid == accountUID
            && store.sessionRevision == sessionRevision
    }
    var canSubmit: Bool {
        guard isCurrentSession, !isLoadingPreview, !isSubmitting, !completed,
            let preview, preview.invite.code == parsedCode
        else { return false }
        return preview.invite.revokedAt == nil
            && (preview.invite.expiresAt.map { $0 > Date() } ?? true)
            && (preview.alreadyMember || preview.canJoin)
    }

    var actionTitle: String {
        guard let preview else { return AppLanguage.localized("Join Group") }
        if preview.alreadyMember { return AppLanguage.localized("Open Group") }
        if !preview.canJoin {
            if preview.invite.usedAt != nil, preview.invite.targetUid == accountUID {
                return AppLanguage.localized("Invitation already used")
            }
            return AppLanguage.localized("You are not eligible to join with this invitation.")
        }
        return AppLanguage.localized("Join Group")
    }

    var statusTitle: String? {
        guard let preview else { return nil }
        if preview.invite.revokedAt != nil { return AppLanguage.localized("Revoked") }
        if preview.invite.usedAt != nil { return AppLanguage.localized("Used") }
        if let expiry = preview.invite.expiresAt, expiry <= eligibilityDate {
            return AppLanguage.localized("Expired")
        }
        return AppLanguage.localized("Active")
    }

    func loadPreview() async {
        guard !isSubmitting, !completed, !Task.isCancelled else { return }
        let immediate =
            !attemptedInitialLookup && input == initialInput
            && GroupInviteLink.code(from: initialInput) != nil
        attemptedInitialLookup = true
        await lookup(debounce: !immediate)
    }

    func retryPreview() async {
        guard !isSubmitting, !completed, !Task.isCancelled else { return }
        await lookup(debounce: false)
    }

    func submit() async -> ChatListItem? {
        eligibilityDate = Date()
        guard canSubmit, let preview, let code = parsedCode, !Task.isCancelled else { return nil }
        let generation = lookupGeneration
        isSubmitting = true
        error = nil
        canRetryPreview = false
        let task = Task<ChatListItem?, Never> { [weak self] in
            guard let self else { return nil }
            defer {
                if self.lookupGeneration == generation {
                    self.isSubmitting = false
                    self.submissionTask = nil
                }
            }
            do {
                let chat =
                    preview.alreadyMember
                    ? self.store.groupChatSnapshot(preview.chat)
                    : try await self.store.redeemGroupInvite(code: code)
                try Task.checkCancellation()
                guard self.isCurrent(generation: generation, code: code) else { return nil }
                self.completed = true
                self.expiryTask?.cancel()
                self.expiryTask = nil
                return chat
            } catch is CancellationError {
                return nil
            } catch {
                guard self.isCurrent(generation: generation, code: code), !Task.isCancelled else {
                    return nil
                }
                if let status = Self.statusCode(for: error), status == 403 || status == 409 {
                    // A membership/policy race must replace permission with an authoritative read.
                    self.preview = nil
                    self.expiryTask?.cancel()
                    self.isLoadingPreview = true
                    await self.requestPreview(code: code, generation: generation)
                    if self.isCurrent(generation: generation, code: code) {
                        self.isLoadingPreview = false
                    }
                } else {
                    self.recordFailure(error, isPreviewFailure: false)
                }
                return nil
            }
        }
        submissionTask = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard completed, isCurrentSession, lookupGeneration == generation, parsedCode == code,
            !Task.isCancelled
        else { return nil }
        return result
    }

    func cancel() {
        lookupGeneration += 1
        previewTask?.cancel()
        previewTask = nil
        submissionTask?.cancel()
        submissionTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        preview = nil
        error = nil
        canRetryPreview = false
        isLoadingPreview = false
        isSubmitting = false
    }

    private func lookup(debounce: Bool) async {
        cancel()
        guard isCurrentSession, let code = parsedCode else { return }
        let generation = lookupGeneration
        isLoadingPreview = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.lookupGeneration == generation {
                    self.isLoadingPreview = false
                    self.previewTask = nil
                }
            }
            do {
                if debounce { try await Task.sleep(for: .milliseconds(300)) }
                try Task.checkCancellation()
                guard self.isCurrent(generation: generation, code: code) else { return }
                await self.requestPreview(code: code, generation: generation)
            } catch is CancellationError {
                // A different input, account, or presentation owns the next lookup.
            } catch {
                if self.isCurrent(generation: generation, code: code), !Task.isCancelled {
                    self.recordFailure(error, isPreviewFailure: true)
                }
            }
        }
        previewTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func requestPreview(code: String, generation: Int) async {
        do {
            let response = try await store.previewGroupInvite(code: code)
            try Task.checkCancellation()
            guard isCurrent(generation: generation, code: code) else { return }
            guard response.invite.code == code else { throw APIError.unexpectedResponse }
            preview = response
            error = nil
            canRetryPreview = false
            eligibilityDate = Date()
            scheduleExpiry(for: response, generation: generation)
        } catch is CancellationError {
            // Transport cancellation is not a failed invitation.
        } catch {
            guard isCurrent(generation: generation, code: code), !Task.isCancelled else { return }
            recordFailure(error, isPreviewFailure: true)
        }
    }

    private func isCurrent(generation: Int, code: String) -> Bool {
        isCurrentSession && lookupGeneration == generation && parsedCode == code && !completed
    }

    private func scheduleExpiry(for preview: GroupInvitePreview, generation: Int) {
        expiryTask?.cancel()
        expiryTask = nil
        guard let expiry = preview.invite.expiresAt, expiry > eligibilityDate,
            expiry.timeIntervalSinceNow.isFinite
        else { return }
        let code = preview.invite.code
        expiryTask = Task { [weak self] in
            while !Task.isCancelled {
                let delay = expiry.timeIntervalSinceNow
                if delay > 0 {
                    do {
                        // Recheck long expiries periodically without overflowing a sleep deadline.
                        try await Task.sleep(for: .seconds(min(delay, 86_400)))
                    } catch { return }
                }
                guard let self, self.isCurrent(generation: generation, code: code) else { return }
                self.eligibilityDate = Date()
                if self.eligibilityDate >= expiry { return }
            }
        }
    }

    private func recordFailure(_ failure: Error, isPreviewFailure: Bool) {
        let issue: String?
        switch Self.statusCode(for: failure) {
        case 400: issue = AppLanguage.localized("This invitation code or URL is invalid.")
        case 404: issue = AppLanguage.localized("This invitation could not be found.")
        case 410: issue = AppLanguage.localized("This invitation has expired or been revoked.")
        case 403:
            issue = AppLanguage.localized("You are not eligible to join with this invitation.")
        default: issue = nil
        }
        if isPreviewFailure || issue != nil {
            preview = nil
            expiryTask?.cancel()
            expiryTask = nil
        }
        error =
            issue
            ?? (isPreviewFailure
                ? AppLanguage.localized("Could not load invitation. Please try again.")
                : AppLanguage.localized("Could not join group. Please try again."))
        canRetryPreview = isPreviewFailure && issue == nil
    }

    private static func statusCode(for error: Error) -> Int? {
        switch error {
        case APIError.http(let status, _), APIError.invalidResponse(let status): return status
        default: return nil
        }
    }
}
