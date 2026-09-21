# Revision 16 manifest

> HISTORICAL: R17-08 section-level authority supersedes conflicting clauses and readiness claims. Read R17-MANIFEST before dispatch.

Planning-only. R16 is the current correction authority. Every listed document
must remain at or below 200 lines; the line-count table is refreshed after all
edits. No source path is added.

## Read order and ownership

Read `R16-READINESS.md`, this manifest, `R16-CHANGELOG.md`, then R16-01…05.
Read R15-01…06 for retained schemas only where R16 points back. P01 owns
canonical bytes, codecs, signatures and typed errors. P18 owns receipt/sink/
authority persistence and recovery. P16 composes only through named APIs.

## Files

|file|action|lines|
|---|---|---:|
|00-INDEX.md|revision16 read order/verdict|37|
|R16-READINESS.md|four-blocker readiness|33|
|R16-CHANGELOG.md|correction summary|18|
|R16-MANIFEST.md|this manifest|34|
|R16-01-CURSOR-STATES.md|tagged cursor, validators and pre-emission record|181|
|R16-02-SINK-AHEAD-RECOVERY.md|durable frame discovery and adoption|130|
|R16-03-RELOCATION-CRASH-RECOVERY.md|bootstrap and unlink crash recovery|94|
|R16-04-POST-RETIREMENT-MUTATIONS.md|fenced updates and bounded log|128|
|R16-05-WORKER-DISPATCH.md|exact packet dispatch|27|
|14-OWNERSHIP.json|revision16 metadata and allowlist authority|1|

## Affected historical sheets

R15-01/02/04/05/06 are amended with R16 pointers. R15-MANIFEST and
R15-READINESS are historical and point to R16; R12-02/03 remain historical
transport/binding references. The ownership audit must preserve the existing
203 unique source paths and zero dependency cycles; R16 adds no source path.
