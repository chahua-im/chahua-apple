import ChahuaAPI
import SwiftUI

struct FriendRequestsView: View {
    let currentUserID: Int32
    @ObservedObject var store: ChatStore
    let onOpenProfile: (Int32) -> Void
    @State private var requests: [FriendRequest] = []
    @State private var loading = false
    @State private var busyID: String?
    @State private var error: String?
    @State private var revision = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            if loading { ProgressView("Loading requests…") }
            if let error {
                Text(error).foregroundStyle(.red)
                Button("Refresh") { Task { await load() } }.disabled(busyID != nil)
            }
            ForEach(requests) { request in
                requestRow(request)
            }
            if !loading && error == nil && requests.isEmpty {
                Text("No friend requests")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Friend Requests")
        .listStyle(.plain)
        .task { await load() }
        .refreshable { await load() }
        .onReceive(store.socialInvalidations) { _ in
            // Fence any older snapshot immediately, before the refresh task starts.
            revision &+= 1
            loading = true
            guard busyID == nil else { return }
            Task { await load() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load() } }
        }
    }

    private func requestRow(_ request: FriendRequest) -> some View {
        let incoming =
            request.direction.map { $0 == .incoming } ?? (request.to.uid == currentUserID)
        let peer = incoming ? request.from : request.to
        let displayName = peer.username ?? String(peer.uid)
        let actionable = incoming && (request.status == .pending || request.status == .archived)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    onOpenProfile(peer.uid)
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(
                            url: peer.avatarUrl.flatMap(URL.init(string:)),
                            displayName: displayName, diameter: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(displayName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(incoming ? "Friend request" : "Friend request sent")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(statusTitle(request.status))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if actionable {
                if let question = request.question { Text(question).font(.subheadline.bold()) }
                if let message = request.message { Text(message).textSelection(.enabled) }
            }
            if actionable {
                HStack {
                    Button("Accept") { Task { await decide(request, .accept) } }
                    Button("Reject", role: .destructive) { Task { await decide(request, .reject) } }
                    if request.status == .pending {
                        Button("Archive") { Task { await decide(request, .archive) } }
                    }
                    if busyID == request.id { ProgressView().controlSize(.small) }
                }
                .buttonStyle(.bordered)
                .disabled(busyID != nil || loading)
            }
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }

    private func statusTitle(_ status: FriendRequestStatus) -> String {
        switch status {
        case .pending: AppLanguage.localized("Pending")
        case .archived: AppLanguage.localized("Archived")
        case .accepted: AppLanguage.localized("Accepted")
        case .rejected: AppLanguage.localized("Rejected")
        }
    }

    private func load() async {
        guard busyID == nil, store.currentUserProfile?.uid == currentUserID else { return }
        revision &+= 1
        let requestRevision = revision
        loading = true
        error = nil
        defer { if revision == requestRevision { loading = false } }
        do {
            async let incoming = store.listFriendRequests(archived: false)
            async let history = store.listFriendRequests(archived: true)
            let (inbox, records) = try await (incoming, history)
            try Task.checkCancellation()
            guard revision == requestRevision,
                store.currentUserProfile?.uid == currentUserID
            else { return }
            // History includes sent/resolved requests; the inbox supplies pending incoming ones.
            // Prefer a history record when a decision moves an ID between the two snapshots.
            var merged: [String: FriendRequest] = [:]
            merged.reserveCapacity(inbox.requests.count + records.requests.count)
            for request in inbox.requests { merged[request.id] = request }
            for request in records.requests { merged[request.id] = request }
            requests = merged.values.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id < $1.id
            }
        } catch is CancellationError {} catch {
            guard revision == requestRevision, store.currentUserProfile?.uid == currentUserID else {
                return
            }
            self.error = error.localizedDescription
        }
    }

    private func decide(_ request: FriendRequest, _ decision: FriendRequestDecision) async {
        guard busyID == nil, store.currentUserProfile?.uid == currentUserID else { return }
        busyID = request.id
        error = nil
        do {
            try await store.decideFriendRequest(id: request.id, decision: decision)
            guard store.currentUserProfile?.uid == currentUserID else {
                busyID = nil
                return
            }
            // Remove the successfully decided row before reloading. A failed read offers Refresh,
            // not a misleading repeat of the already committed accept/reject/archive action.
            requests.removeAll { $0.id == request.id }
            busyID = nil
            await load()
            await store.refreshActiveChats()
        } catch is CancellationError {
            busyID = nil
            await load()
        } catch {
            busyID = nil
            self.error = error.localizedDescription
            // A concurrent decision may have resolved this request on another device.
            // Refresh authoritative rows while retaining the action failure for the user.
            let actionError = error.localizedDescription
            await load()
            self.error = actionError
        }
    }
}
