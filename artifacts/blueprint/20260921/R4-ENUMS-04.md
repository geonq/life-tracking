# Closed Wire4 enums
All Swift enums: String,Codable,Sendable; Python str/Enum; TS literal unions.
Fields are exact raw strings below. Unknown strings reject; no implicit aliases on wire.
Old source aliases decode only before migration. Schema parent version1 governs.

## Wire4TrainingSessionStatus
Source: ios/Shared/FitnessTrainingDomain.swift; frozen allowed raw values:
`active`; `paused`; `completed`; `discarded`.
Swift: enum Wire4TrainingSessionStatus:String,Codable,Sendable { case c0 = "active"; case c1 = "paused"; case c2 = "completed"; case c3 = "discarded" }.
Python: Wire4TrainingSessionStatus = Enum("Wire4TrainingSessionStatus", {"c0":"active", "c1":"paused", "c2":"completed", "c3":"discarded"}, type=str).
TS: type Wire4TrainingSessionStatus = "active" | "paused" | "completed" | "discarded";

## Wire4TrainingSetKind
Source: ios/Shared/FitnessTrainingDomain.swift; frozen allowed raw values:
`warmup`; `working`.
Swift: enum Wire4TrainingSetKind:String,Codable,Sendable { case c0 = "warmup"; case c1 = "working" }.
Python: Wire4TrainingSetKind = Enum("Wire4TrainingSetKind", {"c0":"warmup", "c1":"working"}, type=str).
TS: type Wire4TrainingSetKind = "warmup" | "working";
