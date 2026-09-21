# SyncHealth — unauthenticated public shape
Owner:P01 definition/P02 HTTP producer. Transient; required keys/no defaults/version1 only; R3-00 bounds apply.
```swift
public struct SyncHealth: Codable, Equatable, Sendable {
 public let schemaVersion: Int
 public let status: String
}
```
```python
@dataclass(frozen=True)
class SyncHealth:
    schemaVersion: int
    status: str
```
```typescript
interface SyncHealth { readonly schemaVersion:number; readonly status:"ok"; }
```
|Encoding key|Validation / ownership / storage|
|---|---|
|schemaVersion|Int exactly1; P01; transient; unknown versions reject|
|status|Literal ok only; not a domain/data freshness or production readiness assertion. P02 emits/P01 validates; transient|
No migration of public replies; reject unknown/duplicate/missing fields. Body <=1024bytes.
Canonical JSON:
```json
{"schemaVersion":1,"status":"ok"}
```
Invalid JSON shape/value, must reject:
```json
{"schemaVersion":1,"status":"running-with-keys"}
```
