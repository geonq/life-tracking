import SwiftUI

#if os(iOS)
import BackgroundTasks
import os

/// Requests short, system-scheduled refreshes that can update the shared
/// App Group snapshots while the containing app is not open.
///
/// This is intentionally a request rather than a timer: iOS chooses the
/// execution time based on battery, usage, connectivity, and its refresh
/// budget. WidgetKit timelines remain the fallback for display-only reset and
/// clock changes.
enum LifeOSBackgroundRefresh {
    static let identifier = "com.hermes.lifeos.app.refresh"
    static let earliestInterval: TimeInterval = 15 * 60
    private static let logger = Logger(subsystem: "com.hermes.lifeos", category: "background-refresh")

    static func schedule(now: Date = .now) {
        // The app requests refresh from launch, active, background, and the
        // task's own completion path. Cancel the prior pending request first
        // so repeated lifecycle transitions cannot accumulate requests or
        // turn a valid schedule into BGTaskScheduler's too-many-pending error.
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = now.addingTimeInterval(earliestInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // A simulator, missing capability, or development profile must
            // not affect foreground refresh or widget rendering. Keep the
            // reason in the OS log without exposing any provider payload.
            logger.debug("Unable to schedule app refresh: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
