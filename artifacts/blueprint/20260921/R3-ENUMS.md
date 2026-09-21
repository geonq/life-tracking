# Closed wire enums
P01 owns declarations; raw strings identical in Python/TS; invalid case rejects before store mutation.
```swift
public enum SyncDomain: String, Codable, Sendable { case calendar, finance, fitness, planning, tax }
```
```python
class SyncDomain(str, Enum):
    calendar = "calendar"
    finance = "finance"
    fitness = "fitness"
    planning = "planning"
    tax = "tax"
```
```typescript
type SyncDomain = "calendar" | "finance" | "fitness" | "planning" | "tax";
```
```swift
public enum SyncOperationKind: String, Codable, Sendable { case put, delete, resolve, bootstrap }
```
```python
class SyncOperationKind(str, Enum):
    put = "put"
    delete = "delete"
    resolve = "resolve"
    bootstrap = "bootstrap"
```
```typescript
type SyncOperationKind = "put" | "delete" | "resolve" | "bootstrap";
```
```swift
public enum SyncAckLevel: String, Codable, Sendable { case stored, applied, retainedConflict }
```
```python
class SyncAckLevel(str, Enum):
    stored = "stored"
    applied = "applied"
    retainedConflict = "retainedConflict"
```
```typescript
type SyncAckLevel = "stored" | "applied" | "retainedConflict";
```
```swift
public enum SyncReplicaRole: String, Codable, Sendable { case applying, storing }
```
```python
class SyncReplicaRole(str, Enum):
    applying = "applying"
    storing = "storing"
```
```typescript
type SyncReplicaRole = "applying" | "storing";
```
```swift
public enum SyncOutboxState: String, Codable, Sendable { case unsigned, ready, awaitingAcks, blocked }
```
```python
class SyncOutboxState(str, Enum):
    unsigned = "unsigned"
    ready = "ready"
    awaitingAcks = "awaitingAcks"
    blocked = "blocked"
```
```typescript
type SyncOutboxState = "unsigned" | "ready" | "awaitingAcks" | "blocked";
```
```swift
public enum SyncErrorCode: String, Codable, Sendable { case invalidInput, hashMismatch, unauthenticated, revoked, replay, missingParent, conflict, staleBase, membershipMismatch, idCollision, capacity, unsupportedMedia, unsupportedSchema, busy, offline, identityUnavailable, corruptStore, timedOut, diskFull, cancelled }
```
```python
class SyncErrorCode(str, Enum):
    invalidInput = "invalidInput"
    hashMismatch = "hashMismatch"
    unauthenticated = "unauthenticated"
    revoked = "revoked"
    replay = "replay"
    missingParent = "missingParent"
    conflict = "conflict"
    staleBase = "staleBase"
    membershipMismatch = "membershipMismatch"
    idCollision = "idCollision"
    capacity = "capacity"
    unsupportedMedia = "unsupportedMedia"
    unsupportedSchema = "unsupportedSchema"
    busy = "busy"
    offline = "offline"
    identityUnavailable = "identityUnavailable"
    corruptStore = "corruptStore"
    timedOut = "timedOut"
    diskFull = "diskFull"
    cancelled = "cancelled"
```
```typescript
type SyncErrorCode = "invalidInput" | "hashMismatch" | "unauthenticated" | "revoked" | "replay" | "missingParent" | "conflict" | "staleBase" | "membershipMismatch" | "idCollision" | "capacity" | "unsupportedMedia" | "unsupportedSchema" | "busy" | "offline" | "identityUnavailable" | "corruptStore" | "timedOut" | "diskFull" | "cancelled";
```
