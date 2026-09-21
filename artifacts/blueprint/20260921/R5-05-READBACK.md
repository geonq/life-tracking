# Revision5 bank readback and cancellation contract
Supersedes the nonthrowing `BankReadbackProvider` declaration in R4-RELEASE-INTERFACES.
P09 owns the finance caller; P16 owns capability presentation; P17 owns gateway setup.

## Exact interface
```swift
public enum BankReadbackError: Error, Equatable, Sendable {
 case cancelled
 case unavailable(BankReadbackUnavailable)
 case unauthorized
 case expired
 case stale
 case malformed
 case transport
 case serverRejected
}
public enum BankReadbackUnavailable: String, Equatable, Sendable {
 case missingConfiguration, gatewayOffline, providerUnsupported, permissionDenied
}
public protocol BankReadbackProvider: Sendable {
 func readback() async throws -> FinanceReadbackResult
}
```
The provider throws; it never returns an empty `FinanceReadbackResult` for unavailable data. `TailscaleSyncClient.fetchFinanceReadback()`
is the existing transport call. `BankReadbackClient.readback()` maps configuration/offline/HTTP/auth/decoding failures
to the closed error above, and maps `CancellationError` or an already-cancelled task to `.cancelled`.

## Caller and task semantics
`FinanceCoordinator.refresh()` starts one owned generation task and awaits `BankReadbackProvider.readback()`.
On `.cancelled`, it cancels/awaits the task, restores the prior snapshot and leaves freshness unchanged. On
`unavailable`, `unauthorized`, `expired`, `stale`, `malformed`, `transport` or `serverRejected`, it publishes the
corresponding source-labelled failure while retaining the last committed snapshot; it never substitutes demo data.
`FinanceCoordinator.cancel()` increments the generation before cancelling, so a late response cannot publish.
The provider checks `Task.isCancelled` before request creation, after every network await and before decoding/returning;
it cancels the owned `URLSessionTask`. Cancellation after the server has committed a read has no local mutation to roll back.

## Exact references
PC-01A/B…PC-03A/B use `TailscaleSyncClient.requestBankConsent(institutionId:)`,
`bankConsentStatus(connectionId:)`, and `BankReadbackClient.readback`; `UsageProviderCatalog.descriptor(for:)` is not
part of bank readback. `FinanceCoordinator` remains the only UI-facing reader. Consent URLs/status remain gateway-owned;
no provider credential enters the client. Live acceptance covers Sparkasse/Enable Banking and both Revolut capability
states, expiry/revoke/retry, cancellation, malformed response and stale snapshot.

## Compile-safe unavailable path
`DisabledBankReadbackProvider.readback()` always throws `.unavailable(.missingConfiguration)` and is used only when
the personal gateway is not configured. This permits macOS/iOS compilation and honest UI setup state without fake data.

## Revision6 supersession
R6-07 supplies the concrete `BankReadbackTransport` bridge, initializers and the final symbol audit. R5-05 remains the
authority for the throwing error mapping and FinanceCoordinator cancellation semantics.
