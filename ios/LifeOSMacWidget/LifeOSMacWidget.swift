import SwiftUI
import WidgetKit

@main
struct LifeOSMacWidgetBundle: WidgetBundle {
    init() {
        LifeOSFontRegistrar.registerBundledFonts()
    }

    var body: some Widget {
        LifeOSWidget()
        CalendarWidget()
    }
}
