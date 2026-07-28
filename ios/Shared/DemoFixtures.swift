import Foundation
public enum DemoDataProvider {
 public static let observedAt=Date(timeIntervalSince1970:1_783_000_000)
 public static let provenance=Provenance(source:"Demo fixture",observedAt:observedAt,quality:.demo,connector:.healthy)
 public static let codex=ProviderSnapshot(provider:.codex,accountLabel:"Demo Codex account",windows:[UsageWindow(id:"5h",label:"5-hour",limit:1,used:0.42,resetAt:observedAt.addingTimeInterval(3600)),UsageWindow(id:"7d",label:"7-day",limit:1,used:0.18,resetAt:observedAt.addingTimeInterval(86400*3),projection:Projection(percentAtReset:0.22,percentAtExhaustion:0.95,confidence:0.72,sampleSpan:"14 days"))],model:"Demo model",metrics:[],provenance:provenance)
 public static let claude=ProviderSnapshot(provider:.claude,accountLabel:"Demo Claude account",windows:[UsageWindow(id:"5h",label:"5-hour"),UsageWindow(id:"7d",label:"7-day",limit:1,used:0.31,resetAt:observedAt.addingTimeInterval(86400*2))],provenance:provenance)
 public static var providers:[ProviderSnapshot]{[codex,claude]}
 public static func widget(now:Date = .now)->WidgetSnapshot { WidgetSnapshot(providers:providers,codexStatus:"Demo active",clipperSignal:"Blocked · connector",healthSignal:"Blocked · HealthKit",financeSignal:"Blocked · import",updatedAt:observedAt,freshness:provenance.freshness(now:now),warning:"Demo data only",provenance:provenance) }
}
