# Revision 13 worker dispatch

Planning-only. R14-04 is the current Luna dispatch sheet. R13 is the historical ownership baseline. Read R14-01…04
before source work; stop and escalate if source evidence differs.

|packet|exclusive R13 work|existing allowlisted paths|
|---|---|---|
|P01|carrier framing, canonical JSON, payload codecs, validation/errors|`ios/Sync/SyncWireCodec.swift`, `ios/Sync/DomainWireValues.swift`|
|P18|two-phase manifest production, sink durability, receipt relocation and fixed path resolver|`ios/Shared/LifeOSDataArchiveWriter.swift`, `ios/Shared/LifeOSReceiptCoordinator.swift`, `ios/Shared/LifeOSDataManagement.swift`|
|P16|composition only after P01/P18 reports|existing P16 paths in `14-OWNERSHIP.json`|

P01 does not own receipt paths or production state. P18 does not reimplement canonical bytes or choose legacy paths.
`LifeOS/Receipts` is canonical only after the R14 authority marker commits; all three legacy paths are handled by
the P18 relocator. R14-01 owns the monotonic receipt phase/cursor/finalization record, R14-02 owns the two canonical
JSON manifest objects, and R14-03 owns `relocation-v8.json` plus authorized mutations and retirement. No other source
file, receipt sidecar, manifest authority or serializer is permitted. P18 calls
`LifeOSManifestStreamWriterV7` only in the staged→finalized→emitted order, and P16 composes injected protocols
after the P18 receipt/manifest report.

Every worker report must list exact symbols, existing path, phase/cursor persistence, canonical bytes, fsync/atomic
boundary, crash/cancellation branch, error mapping and evidence. A path, payload key, carrier order, receipt merge
choice or source fallback not present in R14 is an Astra checkpoint before coding.
