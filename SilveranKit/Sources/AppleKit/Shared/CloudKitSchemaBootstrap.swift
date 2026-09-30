#if DEBUG && (os(iOS) || os(macOS))
import CloudKit
import Foundation
import SilveranKit

/// Debug-only: teaches the CloudKit **Development** schema every record type and field the app
/// writes (XCodeApps/CloudKit/schema.ckdb), without a management token. It saves one sample
/// record of each type, with every field set, into a throwaway zone and then deletes the zone.
/// The schema can then be deployed to Production from the CloudKit Console.
///
/// Run a Debug build (Mac or iOS device) with the launch argument `-SilveranCloudKitSchemaBootstrap`.
enum CloudKitSchemaBootstrap {
    static let argument = "-SilveranCloudKitSchemaBootstrap"

    static var isRequested: Bool { CommandLine.arguments.contains(argument) }

    /// Returns a one-line result for logs.
    static func run(containerIdentifier: String) async -> String {
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let zone = CKRecordZone(zoneID: CKRecordZone.ID(zoneName: "SchemaBootstrap"))
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("silveran-schema-\(UUID().uuidString)")
        do {
            try Data("schema".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            _ = try await database.modifyRecordZones(saving: [zone], deleting: [])

            let annotation = CKRecord(
                recordType: AnnotationCloudSync.recordType,
                recordID: CKRecord.ID(recordName: "schema-annotation", zoneID: zone.zoneID)
            )
            AnnotationCloudSync.populate(
                annotation,
                with: AnnotationSyncRecord(
                    bookID: BookID(sourceID: "schema", uuid: "schema"),
                    kind: .inkNote,
                    annotationID: "schema",
                    href: "schema.xhtml",
                    clock: SyncClock(millis: 0, counter: 0, device: "schema"),
                    deleted: false,
                    payload: Data("{}".utf8),
                    erasedStrokes: ["schema"]
                )
            )
            annotation["payloadAsset"] = CKAsset(fileURL: file)  // normally only for large notes

            let asset = CKRecord(
                recordType: "BackupAsset",
                recordID: CKRecord.ID(recordName: "schema-asset", zoneID: zone.zoneID)
            )
            asset["data"] = CKAsset(fileURL: file)
            asset["byteCount"] = 6 as NSNumber

            let generation = CKRecord(
                recordType: "BackupGeneration",
                recordID: CKRecord.ID(recordName: "schema-generation", zoneID: zone.zoneID)
            )
            generation["manifest"] = CKAsset(fileURL: file)
            generation["deviceID"] = "schema" as NSString
            generation["deviceClass"] = "schema" as NSString
            generation["createdAt"] = Date() as NSDate
            generation["appVersion"] = "schema" as NSString
            generation["complete"] = 0 as NSNumber

            let results = try await database.modifyRecords(
                saving: [annotation, asset, generation],
                deleting: [],
                savePolicy: .allKeys,
                atomically: true
            )
            for (_, result) in results.saveResults {
                if case .failure(let error) = result { throw error }
            }
            _ = try await database.modifyRecordZones(saving: [], deleting: [zone.zoneID])
            return
                "CloudKit schema bootstrap succeeded: Annotation, BackupAsset and BackupGeneration are defined in Development."
        } catch {
            _ = try? await database.modifyRecordZones(saving: [], deleting: [zone.zoneID])
            return "CloudKit schema bootstrap failed: \(error)"
        }
    }
}
#endif
