# CloudKit schema

`schema.ckdb` defines every record type and field the app writes to its private iCloud database: `Annotation` (device sync, ADR 010), `LibraryBook` (book cards for matching books across devices, ADR 012) and `BackupAsset` / `BackupGeneration` (automatic backup, ADR 009). Keep it in step with `AnnotationCloudSync.swift` and `CloudKitBackupTransport.swift`; a field the code writes that isn't in the Production schema makes those saves fail in TestFlight and App Store builds.

The records live in private zones (`Annotations`, `Backups`), so the grants only matter for CloudKit's schema format. Enumeration uses zone changes, so no query indexes are needed beyond `___recordID`.

## Apply it without a token (recommended)

1. Build and run a signed Debug Mac build with the iCloud settings enabled in `Local.xcconfig`, passing `-SilveranCloudKitSchemaBootstrap`. It saves one sample record of each type to the Development database, deletes it, prints the result and quits. On an iOS device, launch a signed Debug build the same way (`xcrun devicectl device process launch --device <id> --console <bundle id> -- -SilveranCloudKitSchemaBootstrap`); the result is logged to the console and the app keeps running. `xcodebuild` can't create iCloud provisioning when Xcode's account isn't visible to the command line. In that case, press Run once in Xcode to provision, then build from the command line.
2. In the CloudKit Console, open **Schema** and choose **Deploy Schema Changes…**.

## Apply it with a management token

1. In the CloudKit Console (icloud.developer.apple.com), select the container, open **Settings > Tokens**, and create a **Management Token**.
2. Save it for command-line use (you paste the token; it goes to the macOS keychain):

   ```bash
   xcrun cktool save-token --type management
   ```

3. Import into the Development environment:

   ```bash
   xcrun cktool import-schema --team-id 82W37A9TM4 --container-id iCloud.com.robwilliams.SilveranReaderRobTest --environment development --file XCodeApps/CloudKit/schema.ckdb
   ```

4. In the CloudKit Console, open **Schema** and choose **Deploy Schema Changes…** to copy it to Production. Record types and fields can't be removed from Production afterwards; only added.

Development builds (run from Xcode) use the Development environment; TestFlight and App Store builds use Production. Their data is separate.
