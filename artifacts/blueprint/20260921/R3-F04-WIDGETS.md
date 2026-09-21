# Complete registered widget coverage
Source: ios/LifeOSWidget/LifeOSWidget.swift and ios/LifeOSMacWidget/LifeOSMacWidget.swift bundles.
18 iOS registrations,17 Mac registrations; usage accessoryCircular is iOS-only.
P14 owns every row; P16 owns target membership. PRESENT configuration, PARTIAL final device/visual acceptance.
Files in table relative to ios/LifeOSWidget/. Existing kind strings/configuration identities MUST remain stable.
All rows depend on P07 and their source-store packet; widget extensions never fetch health/bank/network data.
All rows read last accepted snapshot, show stale/locked/empty/unsupported honestly and preserve previous file on failure.
Every row uses20/27 compact SF Pro/SF Symbols, platform outer corners and dark/tinted grey-wallpaper contrast.
No orb/TimelineView animations. Theme/tint/lock screenshots and deep-link target evidence are required per row.
P14 must trace each row's URL creation→app router function (CP-L:W-LINK-<kind>) before changing links;
record exact entity validation, removed-entity fallback, and module route in the packet amendment.
Current producer reference is implementation evidence; missing behavior for ALL rows is integrated source→reload→render
acceptance plus any styling difference from20/27. Reload requests cannot promise immediate display.

|Widget / stable kind|Family|File / renderer|Producer / source-of-truth projection|Release evidence|
|---|---|---|---|---|
|CalendarWidget / `LifeOSCalendarWidget`|medium|CalendarWidget.swift; CalendarWidgetView.body|CalendarWidgetProvider.getTimeline; CalendarStore accepted snapshot|G16 LifeOSCalendarWidget: normal/empty/stale/locked/tinted; deep link; physical signed App Group|
|NextEventWidget / `LifeOSNextEventWidget`|small; iOS accessoryRectangular|NextEventWidget.swift; NextEventWidgetView.body|CalendarWidgetProvider.getTimeline; CalendarStore accepted snapshot|G16 LifeOSNextEventWidget: normal/empty/stale/locked/tinted; deep link; physical signed App Group|
|LifeOSUsageSmallWidget / `LifeOSUsageSmallWidget`|small|UsageWidget.swift; CP-L:W-US-SMALL binds exact view body|LifeOSTimelineProvider.getTimeline; UsageCoordinator.publishSnapshot / SharedSnapshotStore|G16 LifeOSUsageSmallWidget: normal/empty/stale/locked/tinted; deep link; physical signed App Group|
|LifeOSWidget / `LifeOSWidget`|medium|UsageWidget.swift; CP-L:W-US-MEDIUM binds exact view body|LifeOSTimelineProvider.getTimeline; UsageCoordinator.publishSnapshot / SharedSnapshotStore|G16 LifeOSWidget: normal/empty/stale/locked/tinted; deep link; physical signed App Group|
|LifeOSUsageLockScreenWidget / `LifeOSUsageLockScreenWidget`|iOS accessoryCircular only|UsageWidget.swift; CP-L:W-US-LOCK binds exact view body|LifeOSTimelineProvider.getTimeline; UsageCoordinator.publishSnapshot / SharedSnapshotStore|G16 LifeOSUsageLockScreenWidget: normal/empty/stale/locked/tinted; deep link; physical signed App Group|
|NetWorthWidget / `NetWorthWidget`|medium|FutureModuleWidgets.swift; NetWorthWidgetView.body|FutureModuleTimelineProvider.getTimeline; mapFinance|G16 NetWorthWidget: normal/empty/stale/locked/tinted; deep link; physical signed App Group|
|SpendRingWidget / `SpendRingWidget`|small|FutureModuleWidgets.swift; SpendRingWidgetView.body|FutureModuleTimelineProvider.getTimeline; mapFinance|G16 SpendRingWidget: normal/empty/stale/locked/tinted; deep link; physical signed App Group|
|CashFlowWidget / `CashFlowWidget`|medium|FutureModuleWidgets.swift; CashFlowWidgetView.body|FutureModuleTimelineProvider.getTimeline; mapFinance|G16 CashFlowWidget: normal/empty/stale/locked/tinted; deep link; physical signed App Group|
|HealthMonitorWidget / `HealthMonitorWidget`|medium|FutureModuleWidgets.swift; HealthMonitorWidgetView.body|FutureModuleTimelineProvider.getTimeline; mapFitness|G16 HealthMonitorWidget: normal/empty/stale/locked/tinted; deep link; physical signed App Group|
|RecoveryRingWidget / `RecoveryRingWidget`|small|FutureModuleWidgets.swift; RecoveryRingWidgetView.body|FutureModuleTimelineProvider.getTimeline; mapFitness|G16 RecoveryRingWidget: normal/empty/stale/locked/tinted; deep link; physical signed App Group|
|TasksWidget / `TasksWidget`|small+medium|FutureModuleWidgets.swift; TasksWidgetView.body|FutureModuleTimelineProvider.getTimeline; TasksWidgetData.project/readSnapshot (Calendar source)|G16 TasksWidget: normal/empty/stale/locked/tinted; deep link; physical signed App Group|
|NutritionOverviewWidget / `NutritionOverviewWidget`|medium|FutureModuleWidgets.swift; NutritionOverviewWidgetView.body|FutureModuleTimelineProvider.getTimeline; mapNutrition|G16 NutritionOverviewWidget: normal/empty/stale/locked/tinted; deep link; physical signed App Group|
|CaloriesMacrosWidget / `CaloriesMacrosWidget`|medium|FutureModuleWidgets.swift; CaloriesMacrosWidgetView.body|FutureModuleTimelineProvider.getTimeline; mapNutrition|G16 CaloriesMacrosWidget: normal/empty/stale/locked/tinted; deep link; physical signed App Group|
|NetEnergyWidget / `NetEnergyWidget`|medium|FutureModuleWidgets.swift; NetEnergyWidgetView.body|FutureModuleTimelineProvider.getTimeline; mapNutrition|G16 NetEnergyWidget: normal/empty/stale/locked/tinted; deep link; physical signed App Group|
|DailyOverviewWidget / `DailyOverviewWidget`|medium|FutureModuleWidgets.swift; DailyOverviewWidgetView.body|FutureModuleTimelineProvider.getTimeline; mapFitnessWidgets|G16 DailyOverviewWidget: normal/empty/stale/locked/tinted; deep link; physical signed App Group|
|FitnessHealthMonitorWidget / `FitnessHealthMonitorWidget`|medium|FutureModuleWidgets.swift; FitnessHealthMonitorWidgetView.body|FutureModuleTimelineProvider.getTimeline; mapFitnessWidgets|G16 FitnessHealthMonitorWidget: normal/empty/stale/locked/tinted; deep link; physical signed App Group|
|FitnessStressWidget / `FitnessStressWidget`|medium|FutureModuleWidgets.swift; FitnessStressWidgetView.body|FutureModuleTimelineProvider.getTimeline; mapFitnessWidgets|G16 FitnessStressWidget: normal/empty/stale/locked/tinted; deep link; physical signed App Group|
|FitnessEnergyReserveWidget / `FitnessEnergyReserveWidget`|medium|FutureModuleWidgets.swift; FitnessEnergyReserveWidgetView.body|FutureModuleTimelineProvider.getTimeline; mapFitnessWidgets|G16 FitnessEnergyReserveWidget: normal/empty/stale/locked/tinted; deep link; physical signed App Group|

## Ownership and missing identity evidence
WidgetSnapshotPublisher.publish(finance:fitness:fitnessWidgets:nutrition:privacyMode:now:onWriteFailure:)
uses mapFinance/mapFitness/mapFitnessWidgets/mapNutrition; false means unchanged OR callback-reported failure.
CalendarWidgetProvider and LifeOSTimelineProvider have separate existing snapshot authorities; do not force them
through FutureWidgetSnapshot or introduce a second universal store. Version migration is R3-03 +19 M6.
NextEventWidget accessoryRectangular is the requested Notion-style Lock Screen event surface, not a new kind.
Its physical visual target is the user-provided Bilder/Zeugs reference; CP-L:W-LOCK-EVENT must record exact image path
and map displayed start time/title/calendar/privacy to NextEventWidgetView.body before changing layout.
Tasks currently projects Calendar data; no claim of a separate complete task manager. WG-10 remains honest setup
when source tasks absent; CP-L:WG-10 reconciles required checklist semantics before inventing new persistence.
