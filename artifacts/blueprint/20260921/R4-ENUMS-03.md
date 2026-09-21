# Closed Wire4 enums
All Swift enums: String,Codable,Sendable; Python str/Enum; TS literal unions.
Fields are exact raw strings below. Unknown strings reject; no implicit aliases on wire.
Old source aliases decode only before migration. Schema parent version1 governs.

## Wire4Section
Source: ios/Shared/FitnessJournalStore.swift; frozen allowed raw values:
`pinned`; `day`; `night`; `automatic`.
Swift: enum Wire4Section:String,Codable,Sendable { case c0 = "pinned"; case c1 = "day"; case c2 = "night"; case c3 = "automatic" }.
Python: Wire4Section = Enum("Wire4Section", {"c0":"pinned", "c1":"day", "c2":"night", "c3":"automatic"}, type=str).
TS: type Wire4Section = "pinned" | "day" | "night" | "automatic";

## Wire4Source
Source: ios/Shared/FitnessJournalStore.swift; frozen allowed raw values:
`manual`; `healthKit`; `derived`; `inferred`; `unavailable`; `demo`.
Swift: enum Wire4Source:String,Codable,Sendable { case c0 = "manual"; case c1 = "healthKit"; case c2 = "derived"; case c3 = "inferred"; case c4 = "unavailable"; case c5 = "demo" }.
Python: Wire4Source = Enum("Wire4Source", {"c0":"manual", "c1":"healthKit", "c2":"derived", "c3":"inferred", "c4":"unavailable", "c5":"demo"}, type=str).
TS: type Wire4Source = "manual" | "healthKit" | "derived" | "inferred" | "unavailable" | "demo";

## Wire4SupplementAction
Source: ios/Shared/SupplementHistoryDomain.swift; frozen allowed raw values:
`taken`; `snooze`; `skip`.
Swift: enum Wire4SupplementAction:String,Codable,Sendable { case c0 = "taken"; case c1 = "snooze"; case c2 = "skip" }.
Python: Wire4SupplementAction = Enum("Wire4SupplementAction", {"c0":"taken", "c1":"snooze", "c2":"skip"}, type=str).
TS: type Wire4SupplementAction = "taken" | "snooze" | "skip";

## Wire4SupplementCorrectionEntityKind
Source: ios/Shared/SupplementHistoryDomain.swift; frozen allowed raw values:
`plan`; `schedule`; `occurrence`; `inventory`.
Swift: enum Wire4SupplementCorrectionEntityKind:String,Codable,Sendable { case c0 = "plan"; case c1 = "schedule"; case c2 = "occurrence"; case c3 = "inventory" }.
Python: Wire4SupplementCorrectionEntityKind = Enum("Wire4SupplementCorrectionEntityKind", {"c0":"plan", "c1":"schedule", "c2":"occurrence", "c3":"inventory"}, type=str).
TS: type Wire4SupplementCorrectionEntityKind = "plan" | "schedule" | "occurrence" | "inventory";

## Wire4SupplementForm
Source: ios/Shared/SupplementDomain.swift; frozen allowed raw values:
`capsule`; `tablet`; `powder`; `liquid`; `softgel`; `other`.
Swift: enum Wire4SupplementForm:String,Codable,Sendable { case c0 = "capsule"; case c1 = "tablet"; case c2 = "powder"; case c3 = "liquid"; case c4 = "softgel"; case c5 = "other" }.
Python: Wire4SupplementForm = Enum("Wire4SupplementForm", {"c0":"capsule", "c1":"tablet", "c2":"powder", "c3":"liquid", "c4":"softgel", "c5":"other"}, type=str).
TS: type Wire4SupplementForm = "capsule" | "tablet" | "powder" | "liquid" | "softgel" | "other";

## Wire4SupplementNotificationPreference
Source: ios/Shared/SupplementDomain.swift; frozen allowed raw values:
`product_and_timing`; `generic_private`; `disabled`.
Swift: enum Wire4SupplementNotificationPreference:String,Codable,Sendable { case c0 = "product_and_timing"; case c1 = "generic_private"; case c2 = "disabled" }.
Python: Wire4SupplementNotificationPreference = Enum("Wire4SupplementNotificationPreference", {"c0":"product_and_timing", "c1":"generic_private", "c2":"disabled"}, type=str).
TS: type Wire4SupplementNotificationPreference = "product_and_timing" | "generic_private" | "disabled";

## Wire4SupplementOccurrenceState
Source: ios/Shared/SupplementHistoryDomain.swift; frozen allowed raw values:
`planned`; `taken`; `snoozed`; `skipped`; `missed`.
Swift: enum Wire4SupplementOccurrenceState:String,Codable,Sendable { case c0 = "planned"; case c1 = "taken"; case c2 = "snoozed"; case c3 = "skipped"; case c4 = "missed" }.
Python: Wire4SupplementOccurrenceState = Enum("Wire4SupplementOccurrenceState", {"c0":"planned", "c1":"taken", "c2":"snoozed", "c3":"skipped", "c4":"missed"}, type=str).
TS: type Wire4SupplementOccurrenceState = "planned" | "taken" | "snoozed" | "skipped" | "missed";

## Wire4SupplementSource
Source: ios/Shared/SupplementDomain.swift; frozen allowed raw values:
`manual`; `package_label`; `imported`.
Swift: enum Wire4SupplementSource:String,Codable,Sendable { case c0 = "manual"; case c1 = "package_label"; case c2 = "imported" }.
Python: Wire4SupplementSource = Enum("Wire4SupplementSource", {"c0":"manual", "c1":"package_label", "c2":"imported"}, type=str).
TS: type Wire4SupplementSource = "manual" | "package_label" | "imported";

## Wire4TagState
Source: ios/Shared/FitnessJournalStore.swift; frozen allowed raw values:
`yes`; `no`; `unknown`.
Swift: enum Wire4TagState:String,Codable,Sendable { case c0 = "yes"; case c1 = "no"; case c2 = "unknown" }.
Python: Wire4TagState = Enum("Wire4TagState", {"c0":"yes", "c1":"no", "c2":"unknown"}, type=str).
TS: type Wire4TagState = "yes" | "no" | "unknown";

## Wire4TrainingActivityKind
Source: ios/Shared/FitnessTrainingDomain.swift; frozen allowed raw values:
`strength`; `cardio`; `mobility`; `flexibility`; `sport`; `other`.
Swift: enum Wire4TrainingActivityKind:String,Codable,Sendable { case c0 = "strength"; case c1 = "cardio"; case c2 = "mobility"; case c3 = "flexibility"; case c4 = "sport"; case c5 = "other" }.
Python: Wire4TrainingActivityKind = Enum("Wire4TrainingActivityKind", {"c0":"strength", "c1":"cardio", "c2":"mobility", "c3":"flexibility", "c4":"sport", "c5":"other"}, type=str).
TS: type Wire4TrainingActivityKind = "strength" | "cardio" | "mobility" | "flexibility" | "sport" | "other";

## Wire4TrainingLoadConvention
Source: ios/Shared/FitnessTrainingDomain.swift; frozen allowed raw values:
`external_total`; `bodyweight`; `assisted`.
Swift: enum Wire4TrainingLoadConvention:String,Codable,Sendable { case c0 = "external_total"; case c1 = "bodyweight"; case c2 = "assisted" }.
Python: Wire4TrainingLoadConvention = Enum("Wire4TrainingLoadConvention", {"c0":"external_total", "c1":"bodyweight", "c2":"assisted"}, type=str).
TS: type Wire4TrainingLoadConvention = "external_total" | "bodyweight" | "assisted";

## Wire4TrainingMuscleGroup
Source: ios/Shared/FitnessTrainingDomain.swift; frozen allowed raw values:
`arms`; `core`; `chest`; `back`; `legs`; `shoulders`; `other`.
Swift: enum Wire4TrainingMuscleGroup:String,Codable,Sendable { case c0 = "arms"; case c1 = "core"; case c2 = "chest"; case c3 = "back"; case c4 = "legs"; case c5 = "shoulders"; case c6 = "other" }.
Python: Wire4TrainingMuscleGroup = Enum("Wire4TrainingMuscleGroup", {"c0":"arms", "c1":"core", "c2":"chest", "c3":"back", "c4":"legs", "c5":"shoulders", "c6":"other"}, type=str).
TS: type Wire4TrainingMuscleGroup = "arms" | "core" | "chest" | "back" | "legs" | "shoulders" | "other";
