import SwiftUI
import WidgetKit

@main
struct LifeOSWidgetBundle: WidgetBundle {
    var body: some Widget {
        CalendarWidget()
        NextEventWidget()
        LifeOSUsageSmallWidget()
        LifeOSWidget()
        LifeOSUsageLockScreenWidget()
        NetWorthWidget()
        SpendRingWidget()
        CashFlowWidget()
        HealthMonitorWidget()
        RecoveryRingWidget()
        TasksWidget()
        NutritionOverviewWidget()
        CaloriesMacrosWidget()
        NetEnergyWidget()
        DailyOverviewWidget()
        FitnessHealthMonitorWidget()
        FitnessStressWidget()
        FitnessEnergyReserveWidget()
    }
}
