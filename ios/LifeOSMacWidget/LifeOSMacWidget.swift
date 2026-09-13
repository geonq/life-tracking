import SwiftUI
import WidgetKit

@main
struct LifeOSMacWidgetBundle: WidgetBundle {
    var body: some Widget {
        CalendarWidget()
        NextEventWidget()
        LifeOSUsageSmallWidget()
        LifeOSWidget()
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
