import Dispatch
import Foundation
import Testing

@testable import SilveranKit

private final class PersistenceWriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    private var bytes: Int64 = 0
    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        lock.lock()
        writes += 1
        bytes += Int64(data.count)
        lock.unlock()
    }
    func reset() { lock.lock(); writes = 0; bytes = 0; lock.unlock() }
    func snapshot() -> (writes: Int, bytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        return (writes, bytes)
    }
}

private struct PersistenceWorkload: Codable {
    let name: String
    let sections: Int
    let notesPerSection: Int
    let strokesPerNote: Int
    let pointsPerStroke: Int
}
private struct ActiveFileMeasurement: Codable {
    let workload: PersistenceWorkload
    let samples: Int
    let saveMedianMilliseconds: Double
    let saveP95Milliseconds: Double
    let saveMaximumMilliseconds: Double
    let physicalWrites: Int
    let physicalBytesWritten: Int64
    let finalInkFileBytes: Int
    let coldLoadMilliseconds: Double
    let startupReconciliationMilliseconds: Double
    let recoveryConflicts: Int
    let recoveryFiles: Int
    let recoveryBytes: Int64
    let backupCaptureMilliseconds: Double
    let backupEncodingMilliseconds: Double
    let backupUncompressedBytes: Int64
    let backupArchiveBytes: Int
}
private struct RepositoryGrowthMeasurement: Codable {
    let revisions: Int
    let strokesInCurrentNote: Int
    let databaseBytes: Int64
    let snapshotBytes: Int
    let pendingBackupIntents: Int
    let commitMedianMilliseconds: Double
    let commitP95Milliseconds: Double
}
private struct PersistenceMeasurementReport: Codable {
    let schema = 1
    let generatedAt: Date
    let osVersion: String
    let processorCount: Int
    let physicalMemoryBytes: UInt64
    let buildMode: String
    let activeFiles: [ActiveFileMeasurement]
    let inactiveRepositoryGrowth: [RepositoryGrowthMeasurement]
    let limitations: [String]
}

@Suite("Opt-in annotation persistence measurements")
struct AnnotationPersistenceMeasurements {
    private func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
    private func percentile(_ samples: [Double], _ fraction: Double) -> Double {
        let sorted = samples.sorted()
        return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1)]
    }
    private func stroke(_ index: Int, points: Int) -> InkStroke {
        let coordinates: [[Double]] = (0..<points).map { point in
            let x = Double(point) * 0.75
            let y = Double(index) + Double(point % 5) / 4.0
            return [x, y]
        }
        return InkStroke(points: coordinates)
    }
    private func note(_ id: String, strokes: Int, points: Int) -> InkNote {
        InkNote(id: id, anchor: TextAnchor(exact: "Synthetic measurement passage"), strokes: (0..<strokes).map { stroke($0, points: points) }, createdAt: Date(timeIntervalSince1970: 100))
    }
    private func fileBytes(_ directory: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            throw BackupFailure("Measurement inventory failed.")
        }
        var bytes: Int64 = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
        }
        return bytes
    }
    private func highlight(_ id: UUID, book: BookID, text: String) -> Highlight {
        Highlight(id: id, bookID: book, locator: BookLocator(href: "c0", type: "application/xhtml+xml", title: "Synthetic", locations: nil, text: BookLocator.Text(after: nil, before: nil, highlight: "Synthetic passage")), text: "Synthetic passage", color: .yellow, note: text, createdAt: Date(timeIntervalSince1970: 100))
    }
    private func active(_ workload: PersistenceWorkload, root: URL) async throws -> ActiveFileMeasurement {
        let directory = root.appendingPathComponent(workload.name)
        let epoch = AnnotationMutationEpoch()
        let counter = PersistenceWriteCounter()
        let inkDirectory = directory.appendingPathComponent("Ink")
        let ink = InkActor(directory: inkDirectory, mutationEpoch: epoch, writeFile: { try counter.write($0, to: $1) })
        let filesystem = FilesystemActor(applicationSupportDirectory: directory, mutationEpoch: epoch, writeHighlights: { try counter.write($0, to: $1) })
        let bookmarks = BookmarkActor(store: filesystem)
        let book = BookID(sourceID: "measurement", uuid: workload.name)
        for section in 0..<workload.sections {
            let notes = (0..<workload.notesPerSection).map {
                note("note-\(section)-\($0)", strokes: workload.strokesPerNote, points: workload.pointsPerStroke)
            }
            try await ink.setSection(SectionInk(notes: notes), href: "c\(section)", bookID: book).get()
        }
        var edited = try #require(await ink.ink(bookID: book).sections["c0"])
        counter.reset()
        var latencies: [Double] = []
        for sample in 0..<32 {
            edited.notes[0].strokes.append(stroke(workload.strokesPerNote + sample, points: workload.pointsPerStroke))
            let start = DispatchTime.now().uptimeNanoseconds
            try await ink.setSection(edited, href: "c0", bookID: book).get()
            latencies.append(milliseconds(since: start))
        }
        let writes = counter.snapshot()
        let cold = InkActor(directory: inkDirectory, mutationEpoch: epoch)
        var start = DispatchTime.now().uptimeNanoseconds
        let loaded = await cold.load(bookID: book)
        let coldMilliseconds = milliseconds(since: start)
        #expect(loaded.state == .valid)
        #expect(loaded.ink.sections.count == workload.sections)
        let finalInkBytes = try #require(loaded.original).count
        let syncDirectory = directory.appendingPathComponent("Sync")
        let engine = AnnotationSyncEngine(ink: ink, bookmarks: bookmarks, filesystem: filesystem, directory: syncDirectory, deviceID: "measurement", now: { Date(timeIntervalSince1970: 100) }, mutationEpoch: epoch, writeFile: { try counter.write($0, to: $1) })
        start = DispatchTime.now().uptimeNanoseconds
        #expect(await engine.reconcileAll())
        let startupMilliseconds = milliseconds(since: start)
        let highlightID = UUID()
        for conflict in 0..<12 {
            try await filesystem.saveHighlights(bookID: book, highlights: [highlight(highlightID, book: book, text: "Local competing edit \(conflict)")])
            #expect(await engine.reconcile(bookID: book))
            let remote = AnnotationSyncRecord(bookID: book, kind: .highlight, annotationID: highlightID.uuidString, href: nil, clock: SyncClock(millis: 1_000_000 + Int64(conflict) * 1_000, counter: 0, device: "other"), deleted: false, payload: try SyncPayloadCodec.encode(highlight(highlightID, book: book, text: "Remote competing edit \(conflict)")))
            await engine.receive(remote)
        }
        let recovery = await engine.recoveredVersions()
        #expect(recovery.count >= 12)
        let service = BackupService(participants: [LegacyAnnotationsBackupParticipant(ink: ink, filesystem: filesystem), RecoveryMaterialBackupParticipant(directories: [
            "ink-local-mutations": inkDirectory.appendingPathComponent("LocalMutations"),
            "ink-drafts": inkDirectory.appendingPathComponent("Recovery"),
            "highlight-local-mutations": directory.appendingPathComponent("Highlights/LocalMutations"),
            "sync-versions": syncDirectory.appendingPathComponent("Recovery"),
            "sync-inbox": syncDirectory.appendingPathComponent("Inbox"),
            "sync-books": syncDirectory.appendingPathComponent("Books"),
            "sync-moves": syncDirectory.appendingPathComponent("Moves"),
            "sync-receipts": syncDirectory.appendingPathComponent("Completed"),
            "sync-operations": syncDirectory.appendingPathComponent("Operations"),
        ], originalFiles: [
            "sync-index.json": syncDirectory.appendingPathComponent("index.json"),
            "sync-clock.json": syncDirectory.appendingPathComponent("clock.json"),
            "sync-account-context.json": syncDirectory.appendingPathComponent("account-context.json"),
        ])], appVersion: "measurement", deviceID: "isolated", deviceClass: "Mac", stateDirectory: directory.appendingPathComponent("Backup"), mutationEpoch: epoch)
        start = DispatchTime.now().uptimeNanoseconds
        let archive = try await service.createArchive()
        let captureMilliseconds = milliseconds(since: start)
        #expect(archive.manifest.isComplete)
        start = DispatchTime.now().uptimeNanoseconds
        let bytes = try BackupArchiveCodec.encode(archive)
        let encodingMilliseconds = milliseconds(since: start)
        let total = archive.manifest.participants.flatMap(\.files).reduce(Int64(0)) { $0 + Int64($1.fingerprint.byteCount) }
        return ActiveFileMeasurement(workload: workload, samples: latencies.count, saveMedianMilliseconds: percentile(latencies, 0.5), saveP95Milliseconds: percentile(latencies, 0.95), saveMaximumMilliseconds: latencies.max()!, physicalWrites: writes.writes, physicalBytesWritten: writes.bytes, finalInkFileBytes: finalInkBytes, coldLoadMilliseconds: coldMilliseconds, startupReconciliationMilliseconds: startupMilliseconds, recoveryConflicts: 12, recoveryFiles: recovery.count, recoveryBytes: try fileBytes(syncDirectory.appendingPathComponent("Recovery")), backupCaptureMilliseconds: captureMilliseconds, backupEncodingMilliseconds: encodingMilliseconds, backupUncompressedBytes: total, backupArchiveBytes: bytes.count)
    }
    private func repositoryGrowth(root: URL) async throws -> [RepositoryGrowthMeasurement] {
        let url = root.appendingPathComponent("experimental.sqlite")
        let repository = try AnnotationRepository(url: url)
        let scope = AnnotationScope(bookID: BookID(sourceID: "measurement", uuid: "repository"))
        var current = note("note", strokes: 0, points: 16)
        var previous: UUID?
        var latencies: [Double] = []
        var results: [RepositoryGrowthMeasurement] = []
        for revision in 1...256 {
            current.strokes.append(stroke(revision, points: 16))
            let command = AnnotationCommand(scope: scope, annotationID: current.id, deviceID: "measurement", parents: previous.map { [$0] } ?? [], document: AnnotationDocument(target: AnnotationTarget(href: "chapter", text: current.anchor), payload: .inkNote(current)))
            let start = DispatchTime.now().uptimeNanoseconds
            try await repository.commit(command)
            latencies.append(milliseconds(since: start))
            previous = command.operationID
            if [32, 128, 256].contains(revision) {
                let snapshot = try await repository.captureSnapshot()
                #expect(snapshot.revisions.count == revision)
                let databaseBytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                results.append(RepositoryGrowthMeasurement(revisions: revision, strokesInCurrentNote: revision, databaseBytes: databaseBytes, snapshotBytes: try AnnotationSnapshotCodec.encode(snapshot).count, pendingBackupIntents: try await repository.pendingBackupOperations().count, commitMedianMilliseconds: percentile(latencies, 0.5), commitP95Milliseconds: percentile(latencies, 0.95)))
            }
        }
        return results
    }

    @Test("Measure actual active owners and inactive full-history growth", .enabled(if: ProcessInfo.processInfo.environment["SILVERAN_PERSISTENCE_MEASURE"] == "1"))
    func measure() async throws {
        let output = try #require(ProcessInfo.processInfo.environment["SILVERAN_PERSISTENCE_MEASURE_OUTPUT"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("silveran-persistence-measure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workloads = [
            PersistenceWorkload(name: "small", sections: 5, notesPerSection: 2, strokesPerNote: 10, pointsPerStroke: 12),
            PersistenceWorkload(name: "medium", sections: 20, notesPerSection: 4, strokesPerNote: 40, pointsPerStroke: 16),
            PersistenceWorkload(name: "large", sections: 80, notesPerSection: 5, strokesPerNote: 50, pointsPerStroke: 24),
        ]
        var measurements: [ActiveFileMeasurement] = []
        for workload in workloads { measurements.append(try await active(workload, root: root)) }
        #if DEBUG
        let buildMode = "debug"
        #else
        let buildMode = "release"
        #endif
        let report = PersistenceMeasurementReport(generatedAt: Date(), osVersion: ProcessInfo.processInfo.operatingSystemVersionString, processorCount: ProcessInfo.processInfo.processorCount, physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, buildMode: buildMode, activeFiles: measurements, inactiveRepositoryGrowth: try await repositoryGrowth(root: root), limitations: ["Synthetic deterministic points; no real Pencil input, EPUB reflow or renderer latency.", "Process-local atomic write timings; not process-kill, power-loss or hardware flush acceptance.", "Unoptimized host test binary; results are observations, not iPad/iPhone or release-build budgets.", "No CloudKit transport, upload quota, signed accounts or historical retention acceptance.", "Byte totals cover injected atomic payload writes, not filesystem journal or flash wear."])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: destination, options: .atomic)
    }
}
