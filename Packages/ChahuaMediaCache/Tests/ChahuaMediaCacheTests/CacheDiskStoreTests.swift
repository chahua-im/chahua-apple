import Foundation
import Darwin
import XCTest
@testable import ChahuaMediaCache

@MainActor
final class CacheDiskStoreTests: XCTestCase {
    func testSequentialBytesAndTagsSurviveRecoveryWithActualAllocations() async throws {
        try await withStore { store, directory in
            var record = self.record(length: 8, etag: "W/\"v1\"")
            let payload = try await store.create(record: record)
            record = try await store.write(record: record, offset: 0, data: Data("abcd".utf8))
            XCTAssertFalse(record.complete)
            let prefixIsValid = try await store.validate(record: record)
            XCTAssertTrue(prefixIsValid)
            record = try await store.write(record: record, offset: 4, data: Data("efgh".utf8))
            record.tags.insert(CacheTag(rawValue: "second"))
            try await store.persist(record: record)
            XCTAssertTrue(record.complete)
            XCTAssertEqual(record.cachedBytes, 8)
            XCTAssertEqual(try Data(contentsOf: payload), Data("abcdefgh".utf8))

            let metadata = payload.deletingLastPathComponent().appendingPathComponent("metadata.json")
            let allocation = try await store.allocations()
            let expected = try self.allocatedBytes(payload) + self.allocatedBytes(metadata)
            XCTAssertEqual(allocation.entries[record.generation], expected)
            await store.close()

            try await self.withReopenedStore(directory) { reopened in
                let recovered = try await reopened.recover()
                let restored = try XCTUnwrap(recovered.first)
                XCTAssertEqual(recovered.map(\.generation), [record.generation])
                XCTAssertEqual(restored.tags, record.tags)
                XCTAssertEqual(restored.etag, "W/\"v1\"")
                XCTAssertTrue(restored.complete)
                XCTAssertEqual(restored.committedBytes, 8)
                XCTAssertEqual(try Data(contentsOf: reopened.payloadURL(for: restored)), Data("abcdefgh".utf8))
            }
        }
    }

    func testWritesRejectGapsRewindsAndStaleCommitsWithoutChangingBytes() async throws {
        try await withStore { store, _ in
            var record = self.record(length: 8)
            let payload = try await store.create(record: record)
            let stale = record
            record = try await store.write(record: record, offset: 0, data: Data("abcd".utf8))
            do {
                _ = try await store.write(record: record, offset: 6, data: Data("gh".utf8))
                XCTFail("A sequential write must not create a gap")
            } catch MediaCacheError.invalidResponse { }
            do {
                _ = try await store.write(record: record, offset: 0, data: Data("oops".utf8))
                XCTFail("A sequential write must not overwrite committed bytes")
            } catch MediaCacheError.invalidResponse { }
            do {
                _ = try await store.write(record: stale, offset: 0, data: Data("oops".utf8))
                XCTFail("An obsolete record must not overwrite a newer durable commit")
            } catch MediaCacheError.storageFailure { }
            XCTAssertEqual(try Data(contentsOf: payload), Data("abcd".utf8))
            record = try await store.write(record: record, offset: 4, data: Data("efgh".utf8))
            XCTAssertTrue(record.complete)
            XCTAssertEqual(try Data(contentsOf: payload), Data("abcdefgh".utf8))
        }
    }

    func testPersistCannotAdvanceOrRewindCommittedBytes() async throws {
        try await withStore { store, _ in
            // Transients have a private recovery marker rather than a persisted response record.
            for retained in [true, false] {
                var record = self.record(character: retained ? "a" : "b", length: 8, retained: retained)
                let payload = try await store.create(record: record)
                let stale = record
                record = try await store.write(record: record, offset: 0, data: Data("abcd".utf8))
                do {
                    try await store.persist(record: stale)
                    XCTFail("Metadata persistence must not roll back a durable byte count")
                } catch MediaCacheError.storageFailure { }
                var fabricated = record
                fabricated.committedBytes = 8
                do {
                    try await store.persist(record: fabricated)
                    XCTFail("Metadata persistence must not publish bytes that were never committed")
                } catch MediaCacheError.storageFailure { }
                record.tags.insert(CacheTag(rawValue: "second"))
                try await store.persist(record: record)
                let valid = try await store.validate(record: record)
                XCTAssertTrue(valid)
                XCTAssertEqual(try Data(contentsOf: payload), Data("abcd".utf8))
            }
        }
    }

    func testRecoveryKeepsCompleteDataAndRemovesIncompleteCorruptAndOrphanedEntries() async throws {
        try await withStore { store, directory in
            var valid = self.record(character: "a", length: 4)
            _ = try await store.create(record: valid)
            valid = try await store.write(record: valid, offset: 0, data: Data("data".utf8))
            var truncated = self.record(character: "b", length: 6)
            _ = try await store.create(record: truncated)
            truncated = try await store.write(record: truncated, offset: 0, data: Data("abcdef".utf8))
            let malformed = self.record(character: "c", length: 0)
            _ = try await store.create(record: malformed)
            let missing = self.record(character: "d", length: 0)
            _ = try await store.create(record: missing)
            var transient = self.record(character: "e", length: 4, retained: false)
            _ = try await store.create(record: transient)
            transient = try await store.write(record: transient, offset: 0, data: Data("temp".utf8))
            var incomplete = self.record(character: "f", length: 8)
            _ = try await store.create(record: incomplete)
            incomplete = try await store.write(record: incomplete, offset: 0, data: Data("part".utf8))
            let unknown = self.record(character: "0")
            _ = try await store.create(record: unknown)
            _ = try await store.write(record: unknown, offset: 0, data: Data("unknown".utf8))
            await store.close()

            let shortFile = try FileHandle(forWritingTo: store.payloadURL(for: truncated))
            try shortFile.truncate(atOffset: 2)
            try shortFile.close()
            let malformedURL = store.payloadURL(for: malformed).deletingLastPathComponent().appendingPathComponent("metadata.json")
            try Data("broken metadata".utf8).write(to: malformedURL)
            try FileManager.default.removeItem(at: store.payloadURL(for: missing))
            let orphan = directory.appendingPathComponent("v1/entries/\(String(repeating: "1", count: 64))/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
            try Data("orphan".utf8).write(to: orphan.appendingPathComponent("payload"))
            let trash = directory.appendingPathComponent("v1/trash/abandoned")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try Data("trash".utf8).write(to: trash.appendingPathComponent("payload"))

            try await self.withReopenedStore(directory) { reopened in
                let recovered = try await reopened.recover()
                XCTAssertEqual(recovered.map(\.generation), [valid.generation])
                XCTAssertEqual(try Data(contentsOf: reopened.payloadURL(for: valid)), Data("data".utf8))
                let allocation = try await reopened.allocations()
                XCTAssertEqual(Set(allocation.entries.keys), [valid.generation])
                XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: trash.path))
            }
        }
    }

    func testRecoveryDiscardsUncommittedTrailingBytes() async throws {
        try await withStore { store, directory in
            var record = self.record(length: 4)
            let payload = try await store.create(record: record)
            record = try await store.write(record: record, offset: 0, data: Data("head".utf8))
            await store.close()
            let handle = try FileHandle(forWritingTo: payload)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("tail".utf8))
            try handle.synchronize()
            try handle.close()

            try await self.withReopenedStore(directory) { reopened in
                let recovered = try await reopened.recover()
                XCTAssertTrue(recovered.isEmpty)
                XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
            }
        }
    }

    func testLiveValidationRepairsMissingAndTruncatedPayloadsButPreservesTransientData() async throws {
        try await withStore { store, _ in
            var truncated = self.record(character: "a", length: 4)
            _ = try await store.create(record: truncated)
            truncated = try await store.write(record: truncated, offset: 0, data: Data("data".utf8))
            let missing = self.record(character: "b", length: 0)
            _ = try await store.create(record: missing)
            var transient = self.record(character: "c", length: 4, retained: false)
            _ = try await store.create(record: transient)
            transient = try await store.write(record: transient, offset: 0, data: Data("temp".utf8))
            let handle = try FileHandle(forWritingTo: store.payloadURL(for: truncated))
            try handle.truncate(atOffset: 1)
            try handle.close()
            try FileManager.default.removeItem(at: store.payloadURL(for: missing))

            let truncatedIsValid = try await store.validate(record: truncated)
            let missingIsValid = try await store.validate(record: missing)
            let transientIsValid = try await store.validate(record: transient)
            XCTAssertFalse(truncatedIsValid)
            XCTAssertFalse(missingIsValid)
            XCTAssertTrue(transientIsValid)
            XCTAssertEqual(try Data(contentsOf: store.payloadURL(for: transient)), Data("temp".utf8))
            let allocation = try await store.allocations()
            XCTAssertEqual(Set(allocation.entries.keys), [transient.generation])
        }
    }

    func testNoStoreTransitionDoesNotPersistTagsOrHTTPMetadata() async throws {
        try await withStore { store, directory in
            var record = self.record(length: 4)
            let payload = try await store.create(record: record)
            record.retained = false
            record.tags = [CacheTag(rawValue: "private-category")]
            record.etag = "W/\"private-validator\""
            record.lastModified = "private-date"
            record.mimeType = "private/type"
            try await store.persist(record: record)
            record = try await store.write(record: record, offset: 0, data: Data("temp".utf8))
            let metadata = payload.deletingLastPathComponent().appendingPathComponent("metadata.json")
            let persisted = try String(contentsOf: metadata, encoding: .utf8)
            XCTAssertFalse(persisted.contains("private-category"))
            XCTAssertFalse(persisted.contains("private-validator"))
            XCTAssertFalse(persisted.contains("private-date"))
            XCTAssertFalse(persisted.contains("private/type"))
            let valid = try await store.validate(record: record)
            XCTAssertTrue(valid)
            XCTAssertEqual(try Data(contentsOf: payload), Data("temp".utf8))
            await store.close()
            try await self.withReopenedStore(directory) { reopened in
                let recovered = try await reopened.recover()
                XCTAssertTrue(recovered.isEmpty)
                XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
            }
        }
    }

    func testOwnerLockPreventsSecondOwnerUntilClose() async throws {
        try await withStore { store, directory in
            do {
                let competing = try await CacheDiskStore(configuration: CacheConfiguration(directory: directory))
                await competing.close()
                XCTFail("Competing ownership must fail without waiting")
            } catch let error as POSIXError {
                XCTAssertEqual(error.code.rawValue, EWOULDBLOCK)
            }
            await store.close()
            try await self.withReopenedStore(directory) { reopened in
                let record = self.record(length: 0)
                let payload = try await reopened.create(record: record)
                XCTAssertEqual(try Data(contentsOf: payload), Data())
            }
        }
    }

    func testRemovalDoesNotRecreateGenerationAndIsIdempotent() async throws {
        try await withStore { store, _ in
            var record = self.record(length: 8)
            _ = try await store.create(record: record)
            record = try await store.write(record: record, offset: 0, data: Data("data".utf8))
            try await store.remove(record: record)
            try await store.remove(record: record)
            do {
                _ = try await store.write(record: record, offset: 4, data: Data("late".utf8))
                XCTFail("A stale producer must not recreate a removed generation")
            } catch MediaCacheError.missingEntry { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.payloadURL(for: record).path))
            let allocation = try await store.allocations()
            XCTAssertTrue(allocation.entries.isEmpty)
            let recovered = try await store.recover()
            XCTAssertTrue(recovered.isEmpty)
        }
    }

    func testRecoveryUnlinksSymlinksWithoutTouchingTheirTargets() async throws {
        try await withStore { store, directory in
            let outside = directory.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outside) }
            let sentinel = outside.appendingPathComponent("sentinel")
            try Data("untouched".utf8).write(to: sentinel)
            let record = self.record(length: 0)
            _ = try await store.create(record: record)
            await store.close()
            let payload = store.payloadURL(for: record)
            try FileManager.default.removeItem(at: payload)
            try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: sentinel)
            let keyLink = directory.appendingPathComponent("v1/entries/\(String(repeating: "b", count: 64))")
            try FileManager.default.createSymbolicLink(at: keyLink, withDestinationURL: outside)
            let trashLink = directory.appendingPathComponent("v1/trash/external")
            try FileManager.default.createSymbolicLink(at: trashLink, withDestinationURL: outside)

            try await self.withReopenedStore(directory) { reopened in
                let records = try await reopened.recover()
                XCTAssertTrue(records.isEmpty)
                XCTAssertEqual(try Data(contentsOf: sentinel), Data("untouched".utf8))
                let allocation = try await reopened.allocations()
                XCTAssertTrue(allocation.entries.isEmpty)
            }
        }
    }

    func testRootSymlinkIsRejectedWithoutTouchingTarget() async throws {
        try await withStore { store, directory in
            await store.close()
            let alias = directory.deletingLastPathComponent().appendingPathComponent("alias-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: alias) }
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
            let sentinel = directory.appendingPathComponent("sentinel")
            try Data("untouched".utf8).write(to: sentinel)
            do {
                let linked = try await CacheDiskStore(configuration: CacheConfiguration(directory: alias))
                await linked.close()
                XCTFail("The cache root must not follow a symbolic link")
            } catch let error as POSIXError {
                XCTAssertTrue(error.code == .ELOOP || error.code == .ENOTDIR)
            }
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("untouched".utf8))
        }
    }

    func testReplacedInfrastructurePropagatesFailureWithoutFollowingLink() async throws {
        try await withStore { store, directory in
            let record = self.record(length: 0)
            _ = try await store.create(record: record)
            let entries = directory.appendingPathComponent("v1/entries")
            let displaced = directory.appendingPathComponent("displaced")
            try FileManager.default.moveItem(at: entries, to: displaced)
            try FileManager.default.createSymbolicLink(at: entries, withDestinationURL: displaced)
            do {
                try await store.remove(record: record)
                XCTFail("Replaced infrastructure must fail instead of accessing a substituted path")
            } catch MediaCacheError.storageFailure { }
            let displacedPayload = displaced.appendingPathComponent(record.key)
                .appendingPathComponent(record.generation.uuidString).appendingPathComponent("payload")
            XCTAssertEqual(try Data(contentsOf: displacedPayload), Data())
        }
    }

    func testWriteAdmissionHonorsBatchAndRepresentationBoundaries() async throws {
        try await withStore { store, _ in
            var record = self.record(length: 1_048_576)
            let payload = try await store.create(record: record)
            do {
                _ = try await store.write(record: record, offset: 0, data: Data(count: 1_048_577))
                XCTFail("A write larger than the admission batch must fail")
            } catch MediaCacheError.invalidResponse { }
            XCTAssertEqual(try Data(contentsOf: payload), Data())
            let body = Data(repeating: 0x7b, count: 1_048_576)
            record = try await store.write(record: record, offset: 0, data: body)
            do {
                _ = try await store.write(record: record, offset: record.committedBytes, data: Data([0]))
                XCTFail("A body must not exceed its declared length")
            } catch MediaCacheError.invalidResponse { }
            XCTAssertTrue(record.complete)
            XCTAssertEqual(try Data(contentsOf: payload), body)
        }
    }

    func testUnknownLengthBecomesRecoverableOnlyAfterFinalLengthPersists() async throws {
        try await withStore { store, directory in
            var record = self.record()
            let payload = try await store.create(record: record)
            record = try await store.write(record: record, offset: 0, data: Data("data".utf8))
            XCTAssertFalse(record.complete)
            record.contentLength = record.committedBytes
            try await store.persist(record: record)
            await store.close()
            try await self.withReopenedStore(directory) { reopened in
                let recovered = try await reopened.recover()
                let restored = try XCTUnwrap(recovered.first)
                XCTAssertTrue(restored.complete)
                XCTAssertEqual(restored.contentLength, 4)
                XCTAssertEqual(try Data(contentsOf: payload), Data("data".utf8))
            }
        }
    }

    func testRecoveryDiscardsAmbiguousRetainedGenerations() async throws {
        try await withStore { store, directory in
            let first = self.record(character: "a", length: 0)
            let competing = self.record(character: "a", length: 0)
            let unrelated = self.record(character: "b", length: 0)
            _ = try await store.create(record: first)
            _ = try await store.create(record: competing)
            _ = try await store.create(record: unrelated)
            await store.close()
            try await self.withReopenedStore(directory) { reopened in
                let recovered = try await reopened.recover()
                XCTAssertEqual(recovered.map(\.generation), [unrelated.generation])
                let allocation = try await reopened.allocations()
                XCTAssertEqual(Set(allocation.entries.keys), [unrelated.generation])
            }
        }
    }

    func testEmptyCompleteFileSurvivesRecoveryWithoutValidator() async throws {
        try await withStore { store, directory in
            let record = self.record(length: 0, etag: nil)
            _ = try await store.create(record: record)
            await store.close()
            try await self.withReopenedStore(directory) { reopened in
                let recovered = try await reopened.recover()
                let empty = try XCTUnwrap(recovered.first)
                XCTAssertTrue(empty.complete)
                XCTAssertEqual(empty.cachedBytes, 0)
                XCTAssertEqual(try Data(contentsOf: reopened.payloadURL(for: empty)), Data())
            }
        }
    }

    private func record(
        character: Character = "a", length: Int64? = nil, retained: Bool = true, etag: String? = "\"v1\""
    ) -> EntryRecord {
        EntryRecord(
            key: String(repeating: String(character), count: 64), generation: UUID(),
            tags: [CacheTag(rawValue: "first")], committedBytes: 0, contentLength: length,
            mimeType: "application/octet-stream", etag: etag, lastModified: nil,
            freshUntil: .distantFuture, lastAccess: Date(timeIntervalSince1970: 1_000), retained: retained
        )
    }

    private func allocatedBytes(_ url: URL) throws -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Int64(info.st_blocks) * 512
    }

    private func withStore(_ body: @MainActor (CacheDiskStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChahuaDiskTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await CacheDiskStore(configuration: CacheConfiguration(directory: directory))
        do { try await body(store, directory) }
        catch { await store.close(); throw error }
        await store.close()
    }

    private func withReopenedStore(_ directory: URL, _ body: @MainActor (CacheDiskStore) async throws -> Void) async throws {
        let store = try await CacheDiskStore(configuration: CacheConfiguration(directory: directory))
        do { try await body(store) }
        catch { await store.close(); throw error }
        await store.close()
    }
}
