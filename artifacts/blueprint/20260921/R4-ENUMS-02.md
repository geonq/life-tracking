# Closed Wire4 enums
All Swift enums: String,Codable,Sendable; Python str/Enum; TS literal unions.
Fields are exact raw strings below. Unknown strings reject; no implicit aliases on wire.
Old source aliases decode only before migration. Schema parent version1 governs.

## Wire4FitnessLifestyleEventState
Source: ios/Shared/FitnessLifestyleLedger.swift; frozen allowed raw values:
`quantity`; `explicitNone`; `alcoholFree`.
Swift: enum Wire4FitnessLifestyleEventState:String,Codable,Sendable { case c0 = "quantity"; case c1 = "explicitNone"; case c2 = "alcoholFree" }.
Python: Wire4FitnessLifestyleEventState = Enum("Wire4FitnessLifestyleEventState", {"c0":"quantity", "c1":"explicitNone", "c2":"alcoholFree"}, type=str).
TS: type Wire4FitnessLifestyleEventState = "quantity" | "explicitNone" | "alcoholFree";

## Wire4FitnessLifestyleJournalLinkage
Source: ios/Shared/FitnessLifestyleLedger.swift; frozen allowed raw values:
`unavailable`.
Swift: enum Wire4FitnessLifestyleJournalLinkage:String,Codable,Sendable { case c0 = "unavailable" }.
Python: Wire4FitnessLifestyleJournalLinkage = Enum("Wire4FitnessLifestyleJournalLinkage", {"c0":"unavailable"}, type=str).
TS: type Wire4FitnessLifestyleJournalLinkage = "unavailable";

## Wire4FitnessLifestyleKind
Source: ios/Shared/FitnessLifestyleLedger.swift; frozen allowed raw values:
`hydration`; `caffeine`; `alcohol`.
Swift: enum Wire4FitnessLifestyleKind:String,Codable,Sendable { case c0 = "hydration"; case c1 = "caffeine"; case c2 = "alcohol" }.
Python: Wire4FitnessLifestyleKind = Enum("Wire4FitnessLifestyleKind", {"c0":"hydration", "c1":"caffeine", "c2":"alcohol"}, type=str).
TS: type Wire4FitnessLifestyleKind = "hydration" | "caffeine" | "alcohol";

## Wire4FitnessLifestyleLocalTimeFoldPolicy
Source: ios/Shared/FitnessLifestyleLedger.swift; frozen allowed raw values:
`earlierOffset`; `laterOffset`.
Swift: enum Wire4FitnessLifestyleLocalTimeFoldPolicy:String,Codable,Sendable { case c0 = "earlierOffset"; case c1 = "laterOffset" }.
Python: Wire4FitnessLifestyleLocalTimeFoldPolicy = Enum("Wire4FitnessLifestyleLocalTimeFoldPolicy", {"c0":"earlierOffset", "c1":"laterOffset"}, type=str).
TS: type Wire4FitnessLifestyleLocalTimeFoldPolicy = "earlierOffset" | "laterOffset";

## Wire4FitnessLifestyleProvenance
Source: ios/Shared/FitnessLifestyleLedger.swift; frozen allowed raw values:
`manual`; `healthKit`.
Swift: enum Wire4FitnessLifestyleProvenance:String,Codable,Sendable { case c0 = "manual"; case c1 = "healthKit" }.
Python: Wire4FitnessLifestyleProvenance = Enum("Wire4FitnessLifestyleProvenance", {"c0":"manual", "c1":"healthKit"}, type=str).
TS: type Wire4FitnessLifestyleProvenance = "manual" | "healthKit";

## Wire4FitnessLifestyleReminderContext
Source: ios/Shared/FitnessLifestyleLedger.swift; frozen allowed raw values:
`wake`; `beforeLunch`; `nightly`; `custom`; `beforeBedtime`.
Swift: enum Wire4FitnessLifestyleReminderContext:String,Codable,Sendable { case c0 = "wake"; case c1 = "beforeLunch"; case c2 = "nightly"; case c3 = "custom"; case c4 = "beforeBedtime" }.
Python: Wire4FitnessLifestyleReminderContext = Enum("Wire4FitnessLifestyleReminderContext", {"c0":"wake", "c1":"beforeLunch", "c2":"nightly", "c3":"custom", "c4":"beforeBedtime"}, type=str).
TS: type Wire4FitnessLifestyleReminderContext = "wake" | "beforeLunch" | "nightly" | "custom" | "beforeBedtime";

## Wire4FitnessLifestyleUnit
Source: ios/Shared/FitnessLifestyleLedger.swift; frozen allowed raw values:
`ml`; `mg`; `standardDrinks`.
Swift: enum Wire4FitnessLifestyleUnit:String,Codable,Sendable { case c0 = "ml"; case c1 = "mg"; case c2 = "standardDrinks" }.
Python: Wire4FitnessLifestyleUnit = Enum("Wire4FitnessLifestyleUnit", {"c0":"ml", "c1":"mg", "c2":"standardDrinks"}, type=str).
TS: type Wire4FitnessLifestyleUnit = "ml" | "mg" | "standardDrinks";

## Wire4FoodUnit
Source: ios/Shared/NutritionDomain.swift; frozen allowed raw values:
`g`; `kg`; `ml`; `l`; `oz`; `lb`; `serving`; `portion`; `piece`; `slice`; `cup`; `tbsp`; `tsp`.
Swift: enum Wire4FoodUnit:String,Codable,Sendable { case c0 = "g"; case c1 = "kg"; case c2 = "ml"; case c3 = "l"; case c4 = "oz"; case c5 = "lb"; case c6 = "serving"; case c7 = "portion"; case c8 = "piece"; case c9 = "slice"; case c10 = "cup"; case c11 = "tbsp"; case c12 = "tsp" }.
Python: Wire4FoodUnit = Enum("Wire4FoodUnit", {"c0":"g", "c1":"kg", "c2":"ml", "c3":"l", "c4":"oz", "c5":"lb", "c6":"serving", "c7":"portion", "c8":"piece", "c9":"slice", "c10":"cup", "c11":"tbsp", "c12":"tsp"}, type=str).
TS: type Wire4FoodUnit = "g" | "kg" | "ml" | "l" | "oz" | "lb" | "serving" | "portion" | "piece" | "slice" | "cup" | "tbsp" | "tsp";

## Wire4Format
Source: ios/Shared/CalendarIconAsset.swift; frozen allowed raw values:
`png`; `jpeg`.
Swift: enum Wire4Format:String,Codable,Sendable { case c0 = "png"; case c1 = "jpeg" }.
Python: Wire4Format = Enum("Wire4Format", {"c0":"png", "c1":"jpeg"}, type=str).
TS: type Wire4Format = "png" | "jpeg";

## Wire4InventoryEventKind
Source: ios/Shared/SupplementHistoryDomain.swift; frozen allowed raw values:
`taken_decrement`; `manual_adjustment`; `refill`; `correction`.
Swift: enum Wire4InventoryEventKind:String,Codable,Sendable { case c0 = "taken_decrement"; case c1 = "manual_adjustment"; case c2 = "refill"; case c3 = "correction" }.
Python: Wire4InventoryEventKind = Enum("Wire4InventoryEventKind", {"c0":"taken_decrement", "c1":"manual_adjustment", "c2":"refill", "c3":"correction"}, type=str).
TS: type Wire4InventoryEventKind = "taken_decrement" | "manual_adjustment" | "refill" | "correction";

## Wire4NutritionBarcodeBasis
Source: ios/Shared/NutritionBarcode.swift; frozen allowed raw values:
`per100g`; `perServing`.
Swift: enum Wire4NutritionBarcodeBasis:String,Codable,Sendable { case c0 = "per100g"; case c1 = "perServing" }.
Python: Wire4NutritionBarcodeBasis = Enum("Wire4NutritionBarcodeBasis", {"c0":"per100g", "c1":"perServing"}, type=str).
TS: type Wire4NutritionBarcodeBasis = "per100g" | "perServing";

## Wire4NutritionMealProvenance
Source: ios/Shared/NutritionMealDomain.swift; frozen allowed raw values:
`manual`; `confirmedFromPhoto`; `confirmedFromBarcode`.
Swift: enum Wire4NutritionMealProvenance:String,Codable,Sendable { case c0 = "manual"; case c1 = "confirmedFromPhoto"; case c2 = "confirmedFromBarcode" }.
Python: Wire4NutritionMealProvenance = Enum("Wire4NutritionMealProvenance", {"c0":"manual", "c1":"confirmedFromPhoto", "c2":"confirmedFromBarcode"}, type=str).
TS: type Wire4NutritionMealProvenance = "manual" | "confirmedFromPhoto" | "confirmedFromBarcode";
