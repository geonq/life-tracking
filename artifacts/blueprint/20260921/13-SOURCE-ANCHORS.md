# Source anchors at planning time
Repository: /Users/georgdomke/Developer/life-tracking
HEAD d3e62b7d265259dd3954c719365d161328aa32dd. Hashes for all existing owned files are in 14-OWNERSHIP.json.
Line numbers are navigation aids; locate symbols again before editing. New-file entries have no existing implementation.
No source code was changed or compiled in this planning phase.

|Owner|Source path and first named type/entrypoint|Line|
|---|---|---|
|P02|[services/gateway/main.py](../../../services/gateway/main.py) — def _is_allowed_upstream(value: str, expected_path: str) -> bool:|66|
|P03|[ios/Shared/CalendarStore.swift](../../../ios/Shared/CalendarStore.swift) — public enum CalendarStoreError: Error, Equatable, Sendable {|3|
|P03|[ios/Shared/CalendarDomain.swift](../../../ios/Shared/CalendarDomain.swift) — public enum CalendarProgress: String, Codable, CaseIterable, Sendable {|8|
|P03|[ios/Shared/CalendarCoordinator.swift](../../../ios/Shared/CalendarCoordinator.swift) — public enum CalendarLocalSaveResult: Equatable, Sendable {|7|
|P03|[ios/Shared/CalendarPeerSync.swift](../../../ios/Shared/CalendarPeerSync.swift) — public enum CalendarPeerSyncError: Error, Equatable, Sendable {|5|
|P03|[ios/Shared/FinanceImportedTransactionStore.swift](../../../ios/Shared/FinanceImportedTransactionStore.swift) — public enum FinanceImportedTransactionStoreError: Error, Equatable, Sendable {|5|
|P03|[ios/Shared/FinanceRecurringPaymentStore.swift](../../../ios/Shared/FinanceRecurringPaymentStore.swift) — public enum FinanceRecurringPaymentStoreError: Error, Equatable, Sendable {|5|
|P03|[ios/Shared/FinanceInvestmentActivityStore.swift](../../../ios/Shared/FinanceInvestmentActivityStore.swift) — public enum FinanceInvestmentActivityStoreError: Error, Equatable, Sendable {|5|
|P03|[ios/Shared/FinanceBudgetStore.swift](../../../ios/Shared/FinanceBudgetStore.swift) — public enum FinanceBudgetStoreError: Error, Equatable, Sendable {|8|
|P03|[ios/Shared/FinanceAllocationStore.swift](../../../ios/Shared/FinanceAllocationStore.swift) — public enum FinanceAllocationStoreError: Error, Equatable, Sendable {|8|
|P03|[ios/Shared/FinanceTrackingPreferencesStore.swift](../../../ios/Shared/FinanceTrackingPreferencesStore.swift) — public enum FinanceTrackingPreferencesStoreError: Error, Equatable, Sendable {|7|
|P04|[ios/Shared/FitnessTrainingStore.swift](../../../ios/Shared/FitnessTrainingStore.swift) — public enum TrainingStoreError: Error, Equatable, LocalizedError, Sendable {|9|
|P04|[ios/Shared/NutritionMealStore.swift](../../../ios/Shared/NutritionMealStore.swift) — private struct NutritionMealStoreAnyCodingKey: CodingKey {|3|
|P04|[ios/Shared/NutritionGoalStore.swift](../../../ios/Shared/NutritionGoalStore.swift) — public enum NutritionGoalStoreError: Error, Equatable, Sendable {|8|
|P04|[ios/Shared/SupplementStore.swift](../../../ios/Shared/SupplementStore.swift) — public enum SupplementStoreError: Error, Equatable, Sendable {|8|
|P04|[ios/Shared/FitnessJournalStore.swift](../../../ios/Shared/FitnessJournalStore.swift) — public struct FitnessJournalRecord: Codable, Equatable, Hashable, Identifiable {|8|
|P04|[ios/Shared/FitnessLifestyleLedger.swift](../../../ios/Shared/FitnessLifestyleLedger.swift) — public enum FitnessLifestyleKind: String, Codable, CaseIterable, Hashable, Sendable {|11|
|P05|[ios/Planning/PlanningMarkdownLinks.swift](../../../ios/Planning/PlanningMarkdownLinks.swift) — public struct PlanningMarkdownSourceRange: Codable, Equatable, Hashable, Sendable {|6|
|P05|[ios/Planning/PlanningGraphProjection.swift](../../../ios/Planning/PlanningGraphProjection.swift) — public enum PlanningGraphError: Error, Equatable, LocalizedError, Sendable {|3|
|P05|[ios/Planning/PlanningSpatialIndex.swift](../../../ios/Planning/PlanningSpatialIndex.swift) — public struct PlanningSpatialPoint: Codable, Equatable, Hashable, Sendable {|3|
|P05|[ios/Planning/PlanningCanvasEdit.swift](../../../ios/Planning/PlanningCanvasEdit.swift) — public struct PlanningCanvasPoint: Codable, Equatable, Sendable {|3|
|P05|[ios/Planning/PlanningCanvasSession.swift](../../../ios/Planning/PlanningCanvasSession.swift) — public struct PlanningCanvasAccessContext: Codable, Equatable, Sendable {|3|
|P05|[ios/LifeOSMacSnapshotTests/PlanningGraphTests.swift](../../../ios/LifeOSMacSnapshotTests/PlanningGraphTests.swift) — final class PlanningGraphTests: XCTestCase {|4|
|P05|[ios/LifeOSMacSnapshotTests/PlanningCanvasSessionTests.swift](../../../ios/LifeOSMacSnapshotTests/PlanningCanvasSessionTests.swift) — private enum PlanningTestPersistenceError: Error, Equatable {|4|
|P05|[ios/LifeOSTests/PlanningGraphTests.swift](../../../ios/LifeOSTests/PlanningGraphTests.swift) — final class PlanningGraphTests: XCTestCase {|4|
|P06|[ios/Planning/PlanningVaultAccess.swift](../../../ios/Planning/PlanningVaultAccess.swift) — public protocol PlanningVaultPickerAdapter: AnyObject {|10|
|P06|[ios/Planning/PlanningVaultStore.swift](../../../ios/Planning/PlanningVaultStore.swift) — public actor PlanningVaultStore {|3|
|P07|[ios/Shared/DesignTokens.swift](../../../ios/Shared/DesignTokens.swift) — enum LifeOSPalette {|13|
|P07|[ios/Shared/Typography.swift](../../../ios/Shared/Typography.swift) — public enum LifeOSTypography {|9|
|P07|[ios/Shared/LifeOSIcon.swift](../../../ios/Shared/LifeOSIcon.swift) — public enum LifeOSIconName: Sendable {|3|
|P07|[ios/Shared/LifeOSMotionKit.swift](../../../ios/Shared/LifeOSMotionKit.swift) — private struct LifeOSReduceMotionKey: EnvironmentKey {|20|
|P07|[ios/Shared/LifeOSInteractionKit.swift](../../../ios/Shared/LifeOSInteractionKit.swift) — public enum LifeOSInteractionPhase: String, CaseIterable, Sendable {|5|
|P07|[ios/Shared/LifeOSComponents.swift](../../../ios/Shared/LifeOSComponents.swift) — public enum LifeOSSurfaceLevel: String, CaseIterable, Sendable {|9|
|P07|[ios/Shared/LifeOSResponsiveContainer.swift](../../../ios/Shared/LifeOSResponsiveContainer.swift) — public enum LifeOSResponsiveContentAlignment: Equatable, Sendable {|6|
|P08|[ios/LifeOS/CalendarView.swift](../../../ios/LifeOS/CalendarView.swift) — enum CalendarDisplayMode: Hashable {|11|
|P08|[ios/Shared/CalendarViews.swift](../../../ios/Shared/CalendarViews.swift) — enum CalendarTimelineRestorationPolicy {|18|
|P08|[ios/Shared/CalendarLayout.swift](../../../ios/Shared/CalendarLayout.swift) — public struct CalendarEventPlacement: Identifiable, Equatable, Sendable {|4|
|P09|[ios/Shared/FinanceCoordinator.swift](../../../ios/Shared/FinanceCoordinator.swift) — public enum FinanceLoadState: Equatable, Sendable {|4|
|P09|[ios/Shared/FinanceReadback.swift](../../../ios/Shared/FinanceReadback.swift) — public enum FinanceBankingState: String, Codable, Equatable, Sendable {|6|
|P09|[ios/Shared/FinanceRecurringPaymentDetector.swift](../../../ios/Shared/FinanceRecurringPaymentDetector.swift) — public struct FinanceRecurringPaymentInput: Equatable, Sendable {|7|
|P09|[ios/Shared/FinanceRecurringPayment.swift](../../../ios/Shared/FinanceRecurringPayment.swift) — public enum FinanceRecurringPaymentContract {|9|
|P09|[ios/Shared/FinanceStatementImporter.swift](../../../ios/Shared/FinanceStatementImporter.swift) — public enum FinanceImportSkipReason: String, Equatable, Sendable {|11|
|P09|[ios/Shared/FinanceInstitutionDetector.swift](../../../ios/Shared/FinanceInstitutionDetector.swift) — public enum FinanceInstitution: String, CaseIterable, Codable, Equatable, Hashable, Sendable {|7|
|P09|[ios/Shared/FinanceRobinhoodImporter.swift](../../../ios/Shared/FinanceRobinhoodImporter.swift) — public enum FinanceRobinhoodImportError: Error, Equatable, Sendable {|5|
|P09|[ios/Shared/FinanceWealthProjection.swift](../../../ios/Shared/FinanceWealthProjection.swift) — public struct FinanceWealthObservationPoint: Equatable, Sendable {|14|
|P09|[ios/Shared/FinanceBankCashProjection.swift](../../../ios/Shared/FinanceBankCashProjection.swift) — public enum FinanceBankCashProjectionAvailability: String, Codable, Equatable, Sendable {|3|
|P09|[ios/Shared/FinanceInvestmentDomain.swift](../../../ios/Shared/FinanceInvestmentDomain.swift) — public enum FinanceInvestmentContract {|10|
|P09|[ios/LifeOS/Modules/Finance/FinanceView.swift](../../../ios/LifeOS/Modules/Finance/FinanceView.swift) — public enum FinanceDetailRoute: String, CaseIterable, Hashable, Sendable {|12|
|P09|[ios/LifeOS/Modules/Finance/FinanceAnalyticsView.swift](../../../ios/LifeOS/Modules/Finance/FinanceAnalyticsView.swift) — public struct FinanceAnalyticsView: View {|26|
|P09|[ios/LifeOS/Modules/Finance/FinanceChartModeViews.swift](../../../ios/LifeOS/Modules/Finance/FinanceChartModeViews.swift) — public enum FinanceChartMode: String, CaseIterable, Identifiable, Hashable {|12|
|P09|[ios/LifeOS/Modules/Finance/FinanceRecurringPaymentsView.swift](../../../ios/LifeOS/Modules/Finance/FinanceRecurringPaymentsView.swift) — struct FinanceRecurringEvidenceLine: Equatable, Identifiable, Sendable {|5|
|P09|[ios/LifeOS/Modules/Finance/FinanceImportView.swift](../../../ios/LifeOS/Modules/Finance/FinanceImportView.swift) — enum FinanceImportSyncState: Equatable {|33|
|P09|[services/gateway/enablebanking.py](../../../services/gateway/enablebanking.py) — class ProtectedStorageCapacityError(RuntimeError):|62|
|P09|[services/gateway/test_enablebanking.py](../../../services/gateway/test_enablebanking.py) — class FakeResponse:|23|
|P10|[ios/LifeOS/FitnessTrainingCoordinator.swift](../../../ios/LifeOS/FitnessTrainingCoordinator.swift) — public enum FitnessTrainingTemplateSource: String, CaseIterable, Equatable, Sendable {|5|
|P10|[ios/LifeOS/Modules/Fitness/FitnessView.swift](../../../ios/LifeOS/Modules/Fitness/FitnessView.swift) — public struct FitnessSnapshot {|14|
|P10|[ios/LifeOS/Modules/Fitness/FitnessTrainingView.swift](../../../ios/LifeOS/Modules/Fitness/FitnessTrainingView.swift) — private struct LifeOSHealthKitFitnessProjectionKey: EnvironmentKey {|5|
|P10|[ios/LifeOS/Modules/Fitness/FitnessTrainingSessionView.swift](../../../ios/LifeOS/Modules/Fitness/FitnessTrainingSessionView.swift) — private enum FitnessTrainingNumericField: Hashable {|4|
|P10|[ios/LifeOS/Modules/Fitness/FitnessNutritionView.swift](../../../ios/LifeOS/Modules/Fitness/FitnessNutritionView.swift) — public struct FitnessMacroValue: Identifiable {|10|
|P10|[ios/LifeOS/Modules/Fitness/FitnessBiologyView.swift](../../../ios/LifeOS/Modules/Fitness/FitnessBiologyView.swift) — struct FitnessBiologyPresentationPolicy: Equatable, Sendable {|8|
|P10|[ios/LifeOS/Modules/Fitness/FitnessStressView.swift](../../../ios/LifeOS/Modules/Fitness/FitnessStressView.swift) — public struct FitnessStressDetailView: View {|6|
|P10|[ios/LifeOS/Modules/Fitness/FitnessLifestyleView.swift](../../../ios/LifeOS/Modules/Fitness/FitnessLifestyleView.swift) — public struct FitnessLifestyleRepositorySnapshot: Equatable, Sendable {|4|
|P10|[ios/LifeOS/Modules/Fitness/FitnessStrengthView.swift](../../../ios/LifeOS/Modules/Fitness/FitnessStrengthView.swift) — public struct FitnessStrengthDetailView: View {|6|
|P10|[ios/LifeOS/Modules/Fitness/FitnessSupplementsView.swift](../../../ios/LifeOS/Modules/Fitness/FitnessSupplementsView.swift) — struct FitnessSupplementsView: View {|35|
|P10|[ios/LifeOS/Modules/Fitness/FitnessStressDomain.swift](../../../ios/LifeOS/Modules/Fitness/FitnessStressDomain.swift) — public struct FitnessStressEvidence: Equatable, Sendable {|6|
|P10|[ios/LifeOS/Modules/Fitness/FitnessCoreDetailDomain.swift](../../../ios/LifeOS/Modules/Fitness/FitnessCoreDetailDomain.swift) — public struct FitnessSourceCopy: Equatable {|14|
|P11|[ios/Shared/HealthKitAdapter.swift](../../../ios/Shared/HealthKitAdapter.swift) — public enum HealthKitAdapterError: Error, Equatable, Sendable {|7|
|P11|[ios/Shared/HealthKitReconciliation.swift](../../../ios/Shared/HealthKitReconciliation.swift) — public enum HealthKitReconciliationFailure: Error, Equatable, Sendable {|3|
|P11|[ios/Shared/HealthKitAnchorStore.swift](../../../ios/Shared/HealthKitAnchorStore.swift) — public enum HealthKitAnchorStoreError: Error, Equatable, Sendable {|7|
|P11|[ios/LifeOS/HealthKitProductionBridge.swift](../../../ios/LifeOS/HealthKitProductionBridge.swift) — public final class HealthKitProductionClient: HealthKitIntegrationClient {|8|
|P12|[ios/Shared/UsageProviderRegistry.swift](../../../ios/Shared/UsageProviderRegistry.swift) — public enum UsageRegistryError: Error, Equatable, LocalizedError, Sendable {|6|
|P12|[ios/Shared/UsageRegistryAdapter.swift](../../../ios/Shared/UsageRegistryAdapter.swift) — public enum UsageRegistryAdapter {|6|
|P12|[ios/Shared/UsageRegistryPreferences.swift](../../../ios/Shared/UsageRegistryPreferences.swift) — public enum UsageRegistryPreferencesError: Error, Equatable, LocalizedError, Sendable {|3|
|P12|[ios/Shared/UsageManualReadingStore.swift](../../../ios/Shared/UsageManualReadingStore.swift) — public enum UsageManualReadingStoreError: Error, Equatable, LocalizedError, Sendable {|3|
|P12|[ios/Shared/UsageConnectionActions.swift](../../../ios/Shared/UsageConnectionActions.swift) — public enum UsageConnectionDestination: String, CaseIterable, Hashable, Sendable {|6|
|P12|[ios/Shared/UsageCoordinator.swift](../../../ios/Shared/UsageCoordinator.swift) — public enum UsageWidgetTimelineReloader {|11|
|P12|[ios/LifeOS/CodexView.swift](../../../ios/LifeOS/CodexView.swift) — struct CodexView: View {|5|
|P12|[ios/LifeOS/Usage/UsageConnectionsView.swift](../../../ios/LifeOS/Usage/UsageConnectionsView.swift) — enum UsageConnectionControlMetrics {|7|
|P12|[ios/LifeOS/Usage/UsageRegistryDetailView.swift](../../../ios/LifeOS/Usage/UsageRegistryDetailView.swift) — struct UsageRegistryDetailView: View {|6|
|P12|[ios/LifeOS/Usage/UsageProjectionChart.swift](../../../ios/LifeOS/Usage/UsageProjectionChart.swift) — enum UsageChartAxisPolicy {|4|
|P12|[ios/LifeOS/Usage/UsageManualReadingView.swift](../../../ios/LifeOS/Usage/UsageManualReadingView.swift) — struct UsageManualReadingView: View {|7|
|P12|[ios/LifeOS/Usage/UsageFactsView.swift](../../../ios/LifeOS/Usage/UsageFactsView.swift) — struct UsageFactsView: View {|11|
|P13|[ios/Shared/TaxDocuments.swift](../../../ios/Shared/TaxDocuments.swift) — public enum TaxDocumentLimits {|3|
|P13|[ios/LifeOS/TaxDocumentsView.swift](../../../ios/LifeOS/TaxDocumentsView.swift) — final class TaxDocumentsViewModel: ObservableObject {|14|
|P14|[ios/LifeOS/WidgetSnapshotPublisher.swift](../../../ios/LifeOS/WidgetSnapshotPublisher.swift) — public actor WidgetSnapshotPublisher {|24|
|P14|[ios/Shared/FutureWidgetSnapshot.swift](../../../ios/Shared/FutureWidgetSnapshot.swift) — public enum WidgetPrivacyMode: String, Codable, Equatable, Sendable {|7|
|P14|[ios/LifeOSWidget/LifeOSWidget.swift](../../../ios/LifeOSWidget/LifeOSWidget.swift) — struct LifeOSWidgetBundle: WidgetBundle {|5|
|P14|[ios/LifeOSWidget/UsageWidget.swift](../../../ios/LifeOSWidget/UsageWidget.swift) — struct LifeOSTimelineProvider: TimelineProvider {|5|
|P14|[ios/LifeOSWidget/CalendarWidget.swift](../../../ios/LifeOSWidget/CalendarWidget.swift) — public enum CalendarWidgetData {|39|
|P14|[ios/LifeOSWidget/NextEventWidget.swift](../../../ios/LifeOSWidget/NextEventWidget.swift) — public struct NextEventWidgetView: View {|9|
|P14|[ios/LifeOSWidget/FutureModuleWidgets.swift](../../../ios/LifeOSWidget/FutureModuleWidgets.swift) — struct LifeOSWidgetChrome {|8|
|P14|[ios/LifeOSMacWidget/LifeOSMacWidget.swift](../../../ios/LifeOSMacWidget/LifeOSMacWidget.swift) — struct LifeOSMacWidgetBundle: WidgetBundle {|5|
|P14|[ios/LifeOS/Modules/Automation/LifeOSAppIntents.swift](../../../ios/LifeOS/Modules/Automation/LifeOSAppIntents.swift) — enum LifeOSAutomationHealthRefreshState: String, Codable, Equatable, Sendable {|9|
|P14|[ios/Shared/SigningStatus.swift](../../../ios/Shared/SigningStatus.swift) — public enum ProvisioningMode: String, Codable, CaseIterable, Equatable, Sendable {|3|
|P14|[scripts/install_personal_device_checks.py](../../../scripts/install_personal_device_checks.py) — class DeviceListError(ValueError):|102|
|P14|[scripts/tests/test_personal_device_installer.py](../../../scripts/tests/test_personal_device_installer.py) — def device_record(|34|
|P15|[ios/Shared/DemoFixtures.swift](../../../ios/Shared/DemoFixtures.swift) — public enum DemoDataProvider {|3|
|P15|[services/api/src/server.ts](../../../services/api/src/server.ts) — function usageStorePath(): string / undefined {|36|
|P15|[services/api/src/history.ts](../../../services/api/src/history.ts) — export class UsageHistoryError extends Error {|47|
|P15|[services/api/src/codex-adapter.ts](../../../services/api/src/codex-adapter.ts) — export class CodexRpcError extends Error {|20|
|P15|[services/api/src/claude-ingest.ts](../../../services/api/src/claude-ingest.ts) — export function constantTimeEqual(a: string, b: string): boolean {|18|
|P16|[ios/project.yml](../../../ios/project.yml) — targets:|19|
|P16|[ios/LifeOS/LifeOSApp.swift](../../../ios/LifeOS/LifeOSApp.swift) — private enum LifeOSAppTab: Hashable, CaseIterable {|7|
|P16|[ios/LifeOSMac/LifeOSMacApp.swift](../../../ios/LifeOSMac/LifeOSMacApp.swift) — final class FitnessObservationCoordinator: ObservableObject {|4|
|P16|[ios/LifeOS/OverviewView.swift](../../../ios/LifeOS/OverviewView.swift) — struct OverviewView: View {|5|
|P16|[ios/LifeOS/Settings.swift](../../../ios/LifeOS/Settings.swift) — struct RetainedHealthDataSettings: Equatable, Sendable {|9|
|P16|[ios/LifeOS/Modules/ModuleNavigation.swift](../../../ios/LifeOS/Modules/ModuleNavigation.swift) — public enum LifeOSModule: String, CaseIterable, Hashable, Identifiable, Sendable {|6|
|P16|[ios/LifeOS/LifeOSBackgroundRefresh.swift](../../../ios/LifeOS/LifeOSBackgroundRefresh.swift) — enum LifeOSBackgroundRefresh {|14|
|P16|[ios/Shared/TailscaleSyncClient.swift](../../../ios/Shared/TailscaleSyncClient.swift) — public enum TailscaleSyncError: Error, Equatable, Sendable {|4|
|P16|[packages/contracts/src/index.ts](../../../packages/contracts/src/index.ts) — export function parseOverview(input: unknown) { return Overview.parse(input); } export function parseCodexFixture(i|33|
|P17|[services/windows-service-host/deploy/install.ps1](../../../services/windows-service-host/deploy/install.ps1) — function Add-ManifestItem {|51|
|P17|[services/windows-service-host/deploy/verify-candidate.ps1](../../../services/windows-service-host/deploy/verify-candidate.ps1) — function Get-CandidateRelativePath {|11|
|P17|[services/windows-service-host/deploy/gateway_launcher.py](../../../services/windows-service-host/deploy/gateway_launcher.py) — class _WindowsTcpRowOwnerPid(ctypes.Structure):|96|
|P17|[services/windows-service-host/deploy/tests/Deployment.Behavior.Tests.ps1](../../../services/windows-service-host/deploy/tests/Deployment.Behavior.Tests.ps1) — function Assert-Behavior {|14|
|P17|[scripts/build_windows_release.sh](../../../scripts/build_windows_release.sh) — def normalize(name: str) -> str:|261|
|P17|[scripts/tests/test_windows_release_builder.py](../../../scripts/tests/test_windows_release_builder.py) — def _shell_array(source: str, name: str) -> list[str]:|30|
|P18|[scripts/tests/test_macos_storage_maintenance.py](../../../scripts/tests/test_macos_storage_maintenance.py) — class MacOSStorageMaintenanceTests(unittest.TestCase):|17|

## Critical symbols confirmed by direct inspection
- CalendarCoordinator.save/delete/performPersist/synchronizeRemoteSnapshot; CalendarStore.mutate/save.
- PlanningCanvasSession.commitInteraction/commitInspectorEdit/undo/redo/retryPending; PlanningCanvasReducer.apply.
- PlanningGraphProjector.project; PlanningReferenceResolver.resolve; PlanningSpatialIndex.rebuild.
- PlanningVaultStore.read/stage/publish/publishPendingPage/resolveConflict; PlanningVaultAccess.select/restore.
- FinanceRecurringPaymentDetector.makeInput/detect; FinanceWealthProjector.project; FinanceCoordinator.refresh.
- FitnessTrainingStore.begin/update/finish/delete/link/unlink/execute; NutritionMealStore.addConfirmed/correct/softDelete.
- LifeOSMotionLifecycle.send; LifeOSMotion.Timing; LifeOSTypography.Role; WidgetSnapshotPublisher.publish.
- Gateway require_tailscale_identity, _request_has_allowed_tailscale_identity and bounded calendar/import routes.
