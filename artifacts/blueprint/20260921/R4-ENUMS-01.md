# Closed Wire4 enums
All Swift enums: String,Codable,Sendable; Python str/Enum; TS literal unions.
Fields are exact raw strings below. Unknown strings reject; no implicit aliases on wire.
Old source aliases decode only before migration. Schema parent version1 governs.

## Wire4CalendarItemKind
Source: ios/Shared/CalendarDomain.swift; frozen allowed raw values:
`event`; `todo`; `dailySchedule`.
Swift: enum Wire4CalendarItemKind:String,Codable,Sendable { case c0 = "event"; case c1 = "todo"; case c2 = "dailySchedule" }.
Python: Wire4CalendarItemKind = Enum("Wire4CalendarItemKind", {"c0":"event", "c1":"todo", "c2":"dailySchedule"}, type=str).
TS: type Wire4CalendarItemKind = "event" | "todo" | "dailySchedule";

## Wire4CalendarProgress
Source: ios/Shared/CalendarDomain.swift; frozen allowed raw values:
`planned`; `in_progress`; `done`; `aborted`.
Swift: enum Wire4CalendarProgress:String,Codable,Sendable { case c0 = "planned"; case c1 = "in_progress"; case c2 = "done"; case c3 = "aborted" }.
Python: Wire4CalendarProgress = Enum("Wire4CalendarProgress", {"c0":"planned", "c1":"in_progress", "c2":"done", "c3":"aborted"}, type=str).
TS: type Wire4CalendarProgress = "planned" | "in_progress" | "done" | "aborted";

## Wire4CalendarRecurrenceFrequency
Source: ios/Shared/CalendarDomain.swift; frozen allowed raw values:
`daily`; `weekly`; `monthly`; `yearly`.
Swift: enum Wire4CalendarRecurrenceFrequency:String,Codable,Sendable { case c0 = "daily"; case c1 = "weekly"; case c2 = "monthly"; case c3 = "yearly" }.
Python: Wire4CalendarRecurrenceFrequency = Enum("Wire4CalendarRecurrenceFrequency", {"c0":"daily", "c1":"weekly", "c2":"monthly", "c3":"yearly"}, type=str).
TS: type Wire4CalendarRecurrenceFrequency = "daily" | "weekly" | "monthly" | "yearly";

## Wire4FinanceImportSource
Source: ios/Shared/FinanceImportedTransaction.swift; frozen allowed raw values:
`tradeRepublicCSV`; `genericCSV`.
Swift: enum Wire4FinanceImportSource:String,Codable,Sendable { case c0 = "tradeRepublicCSV"; case c1 = "genericCSV" }.
Python: Wire4FinanceImportSource = Enum("Wire4FinanceImportSource", {"c0":"tradeRepublicCSV", "c1":"genericCSV"}, type=str).
TS: type Wire4FinanceImportSource = "tradeRepublicCSV" | "genericCSV";

## Wire4FinanceImportedIdentityScheme
Source: ios/Shared/FinanceImportedTransaction.swift; frozen allowed raw values:
`legacyCSVv2`; `mappedV3`.
Swift: enum Wire4FinanceImportedIdentityScheme:String,Codable,Sendable { case c0 = "legacyCSVv2"; case c1 = "mappedV3" }.
Python: Wire4FinanceImportedIdentityScheme = Enum("Wire4FinanceImportedIdentityScheme", {"c0":"legacyCSVv2", "c1":"mappedV3"}, type=str).
TS: type Wire4FinanceImportedIdentityScheme = "legacyCSVv2" | "mappedV3";

## Wire4FinanceImportedTransactionKind
Source: ios/Shared/FinanceImportedTransaction.swift; frozen allowed raw values:
`cash`; `investmentOrder`.
Swift: enum Wire4FinanceImportedTransactionKind:String,Codable,Sendable { case c0 = "cash"; case c1 = "investmentOrder" }.
Python: Wire4FinanceImportedTransactionKind = Enum("Wire4FinanceImportedTransactionKind", {"c0":"cash", "c1":"investmentOrder"}, type=str).
TS: type Wire4FinanceImportedTransactionKind = "cash" | "investmentOrder";

## Wire4FinanceInvestmentAccountCoverage
Source: ios/Shared/FinanceInvestmentDomain.swift; frozen allowed raw values:
`unknown`; `complete`.
Swift: enum Wire4FinanceInvestmentAccountCoverage:String,Codable,Sendable { case c0 = "unknown"; case c1 = "complete" }.
Python: Wire4FinanceInvestmentAccountCoverage = Enum("Wire4FinanceInvestmentAccountCoverage", {"c0":"unknown", "c1":"complete"}, type=str).
TS: type Wire4FinanceInvestmentAccountCoverage = "unknown" | "complete";

## Wire4FinanceInvestmentActivityKind
Source: ios/Shared/FinanceInvestmentDomain.swift; frozen allowed raw values:
`buy`; `sell`; `dividend`; `interest`; `fee`; `deposit`; `withdrawal`; `transfer`; `unknown`.
Swift: enum Wire4FinanceInvestmentActivityKind:String,Codable,Sendable { case c0 = "buy"; case c1 = "sell"; case c2 = "dividend"; case c3 = "interest"; case c4 = "fee"; case c5 = "deposit"; case c6 = "withdrawal"; case c7 = "transfer"; case c8 = "unknown" }.
Python: Wire4FinanceInvestmentActivityKind = Enum("Wire4FinanceInvestmentActivityKind", {"c0":"buy", "c1":"sell", "c2":"dividend", "c3":"interest", "c4":"fee", "c5":"deposit", "c6":"withdrawal", "c7":"transfer", "c8":"unknown"}, type=str).
TS: type Wire4FinanceInvestmentActivityKind = "buy" | "sell" | "dividend" | "interest" | "fee" | "deposit" | "withdrawal" | "transfer" | "unknown";

## Wire4FinanceInvestmentProvider
Source: ios/Shared/FinanceInvestmentDomain.swift; frozen allowed raw values:
`robinhood`.
Swift: enum Wire4FinanceInvestmentProvider:String,Codable,Sendable { case c0 = "robinhood" }.
Python: Wire4FinanceInvestmentProvider = Enum("Wire4FinanceInvestmentProvider", {"c0":"robinhood"}, type=str).
TS: type Wire4FinanceInvestmentProvider = "robinhood";

## Wire4FinanceRecurringCadence
Source: ios/Shared/FinanceRecurringPayment.swift; frozen allowed raw values:
`weekly`; `monthly`; `yearly`.
Swift: enum Wire4FinanceRecurringCadence:String,Codable,Sendable { case c0 = "weekly"; case c1 = "monthly"; case c2 = "yearly" }.
Python: Wire4FinanceRecurringCadence = Enum("Wire4FinanceRecurringCadence", {"c0":"weekly", "c1":"monthly", "c2":"yearly"}, type=str).
TS: type Wire4FinanceRecurringCadence = "weekly" | "monthly" | "yearly";

## Wire4FinanceRecurringPaymentStatus
Source: ios/Shared/FinanceRecurringPayment.swift; frozen allowed raw values:
`active`; `paused`; `ignored`.
Swift: enum Wire4FinanceRecurringPaymentStatus:String,Codable,Sendable { case c0 = "active"; case c1 = "paused"; case c2 = "ignored" }.
Python: Wire4FinanceRecurringPaymentStatus = Enum("Wire4FinanceRecurringPaymentStatus", {"c0":"active", "c1":"paused", "c2":"ignored"}, type=str).
TS: type Wire4FinanceRecurringPaymentStatus = "active" | "paused" | "ignored";

## Wire4FinanceTransactionCategory
Source: ios/Shared/FinanceTransactionCategory.swift; frozen allowed raw values:
`groceries`; `dining`; `transport`; `shopping`; `bills`; `subscriptions`; `health`; `travel`; `transfers`; `fees`; `taxes`; `investments`; `income`; `cash`; `uncategorized`.
Swift: enum Wire4FinanceTransactionCategory:String,Codable,Sendable { case c0 = "groceries"; case c1 = "dining"; case c2 = "transport"; case c3 = "shopping"; case c4 = "bills"; case c5 = "subscriptions"; case c6 = "health"; case c7 = "travel"; case c8 = "transfers"; case c9 = "fees"; case c10 = "taxes"; case c11 = "investments"; case c12 = "income"; case c13 = "cash"; case c14 = "uncategorized" }.
Python: Wire4FinanceTransactionCategory = Enum("Wire4FinanceTransactionCategory", {"c0":"groceries", "c1":"dining", "c2":"transport", "c3":"shopping", "c4":"bills", "c5":"subscriptions", "c6":"health", "c7":"travel", "c8":"transfers", "c9":"fees", "c10":"taxes", "c11":"investments", "c12":"income", "c13":"cash", "c14":"uncategorized"}, type=str).
TS: type Wire4FinanceTransactionCategory = "groceries" | "dining" | "transport" | "shopping" | "bills" | "subscriptions" | "health" | "travel" | "transfers" | "fees" | "taxes" | "investments" | "income" | "cash" | "uncategorized";
