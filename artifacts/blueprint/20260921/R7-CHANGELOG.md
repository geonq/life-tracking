# Revision7 changelog
Planning-only. No Swift/TypeScript/Python source, generated project, build, test, commit or push was touched.

1. Replaced the R6 single-store recovery shape with one heterogeneous `RecoveryBundleV3` containing all 17 replicated
   stores, signed mappings, checkpoints, per-store key indexes and a receipt-first retry path.
2. Added the exact owner-signed epoch envelope, pinned-owner verification, historical-key bootstrap and one consistent
   10,000-record-per-store bound. The former 100,000 index and unsigned membership-only path are historical.
3. Made `SyncAdapterEnvelopeV2` the sole persisted replication wrapper and restored the complete durable adapter method
   surface for inbox, ACK enumeration, frontier retrieval/advance and checkpointing.
4. Split Calendar viewport gestures from item edits and made local commits allocate a durable operation inside the
   Calendar transaction while replicated commits accept an already persisted operation.
5. Replaced the R6 data-management archive with an exact 26-pack directory format, including recovery-import receipts,
   original nutrition photos, path allowlists, chunk limits, receipt lineage and interrupted-operation recovery.
6. Audited R6 names and false leaf bindings, including RF-02, BF-0384 and DT-03A, and added a final no-guessing packet
  dispatch sheet with external evidence gates separated from architecture readiness.

## Revision8 supersession

R8-CHANGELOG records the final corrections to historical epochs, store IDs, derivations, Calendar commands, receipts,
streaming export and packet ownership.
