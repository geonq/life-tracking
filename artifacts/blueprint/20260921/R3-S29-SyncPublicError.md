# SyncPublicError — unauthenticated public shape
Owner:P01 definition/P02 HTTP producer. Transient; required keys/no defaults/version1 only; R3-00 bounds apply.
```swift
public struct SyncPublicError: Codable, Equatable, Sendable {
 public let schemaVersion: Int
 public let code: SyncErrorCode
}
```
```python
@dataclass(frozen=True)
class SyncPublicError:
    schemaVersion: int
    code: SyncErrorCode
```
```typescript
interface SyncPublicError { readonly schemaVersion:number; readonly code:SyncErrorCode; }
```
|Encoding key|Validation / ownership / storage|
|---|---|
|schemaVersion|Int exactly1; P01; transient; unknown versions reject|
|code|Only unauthenticated,invalidInput,capacity,unsupportedMedia,busy; constant messages absent; code cannot command local state. P02 emits/P01 validates; transient|
No migration of public replies; reject unknown/duplicate/missing fields. Body <=1024bytes.
Canonical JSON:
```json
{"code":"unauthenticated","schemaVersion":1}
```
Invalid JSON shape/value, must reject:
```json
{"code":"secret-debug-dump","schemaVersion":1}
```
