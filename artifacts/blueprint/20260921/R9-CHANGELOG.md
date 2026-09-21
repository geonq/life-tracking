# Revision 9 changelog — exact implementation contracts

Planning-only correction. No Swift, TypeScript or Python source was edited, deleted, built, tested,
generated, committed or pushed.

R9 closes the independent review by making Calendar intent plumbing, receipt preparation/finalization and
resume cursors, typed export framing/backpressure, store-ID alias migration, signed handshake carriers, and
the canonical packet/path allowlist mutually consistent. R9 is read before R8 where it supersedes a clause.

The contract now separates a deterministic prepared artifact identity from the final artifact hash, uses one
chunk-derived file digest, persists a resumable cursor before projection, fences multi-file alias migration,
and binds the detached HTTP signature to method, route, content type and exact body bytes. Ordinary files over
4 MiB and domain envelopes over 32 MiB have explicit rejection outcomes.

R9 does not claim implementation, runtime proof, physical-device evidence, security acceptance or release readiness.
