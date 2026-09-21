# R12 worker dispatch and ownership addendum

Planning-only. This is the current worker prompt for the R12 contracts; it supersedes conflicting P01/P05 wording
in older historical sheets. Workers edit only their existing allowlisted paths and stop on source evidence that
differs from R12.

|packet|exclusive contract ownership|dependency/action|
|---|---|---|
|P01|`ios/Sync/SyncTrustStore.swift` (sole trust owner), `ios/Sync/DomainWireValues.swift`, `ios/Sync/SyncWireCodec.swift` (`LifeOSCanonicalJSONV7`, carrier codec, `LifeOSArchiveIntegrityV7`) and public trust/alias ports|first; no P05 import|
|P05|`ios/Planning/PlanningMutationJournal.swift`; SQLite implementation of P01 `SyncAliasPlanningPort`|after P01; never edit SyncTrustStore|
|P06|`ios/Planning/PlanningFilesystemPublication.swift`; staging, backups, replace and fsync|after P01/P05; no trust decisions|
|P18|`ios/Shared/LifeOSReceiptCoordinator.swift` (receipt store/records), `ios/Shared/LifeOSDataArchiveWriter.swift` (manifest sink/source/verifier/archive projection), `ios/Shared/LifeOSDataManagement.swift` (composition)|after P01/P06; no duplicate hash codec|

The concrete dispatch order is P01 contract/types → P05 SQL port → P06 filesystem port → P18 receipt/archive
streaming, with P16 composition only after all four reports. P01's `SyncTrustStore` receives injected ports and
does not import P05, preventing a dependency cycle. P05 may call only the public P01 port signatures. P18 uses
`LifeOSArchiveIntegrityV7.archiveHash` and `LifeOSReceiptStoreV6`; it may not reimplement canonical JSON or store a
second binding/manifest authority.

Every worker report must name changed paths, exact symbols, actor isolation, schema version, old/new migration
behavior, canonical bytes, cancellation/crash branch and evidence. No worker may add a file outside `14-OWNERSHIP.json`,
change packet ownership, materialize a complete manifest, write a binding sidecar, or resolve an interrupted alias
by choosing a live mixed set. A mismatch becomes an Astra amendment before coding.

R13-04 is the current worker prompt. It supersedes this table for carrier serialization, manifest production order,
receipt relocation and P16/P18 dispatch while retaining R12 trust/hash ownership.
