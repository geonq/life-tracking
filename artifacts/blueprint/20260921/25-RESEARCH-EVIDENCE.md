# Official sources used for revision2
Fetched during this pass; availability listed per member, not inferred from protocol availability.
Apple Markdown references were retrieved read-only when web renderer could not parse them.
No installed SDK compilation/OS upgrade performed; documentation evidence is not local compatibility proof.

|Source|Evidence used|
|---|---|
|https://developer.apple.com/news/releases/?id=02112026f|Current listing contains Xcode27 and iOS/macOS27 releases; do not freeze old beta label|
|https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes|Swift6.4; host macOS26.6+; SDK27; older-toolchain ASan issue|
|https://developer.apple.com/swiftui/whats-new/|2027 document, toolbar, arrangement and data-flow overview|
|https://developer.apple.com/documentation/swiftui/updating-your-document-based-app|URL document migration, distinct readers/writers and undo ownership|
|https://developer.apple.com/documentation/swiftui/creating-a-document-based-app|DocumentGroup lifecycle owns coordinated reading/writing|
|https://developer.apple.com/documentation/swiftui/document|iOS27/macOS27 protocol; reference type combining readable/writable|
|https://developer.apple.com/documentation/swiftui/readabledocument|27-only reader/apply snapshot interface|
|https://developer.apple.com/documentation/swiftui/writabledocument|27-only snapshot/writer; undo registration affects autosave|
|https://developer.apple.com/documentation/swiftui/navigationtransition|Protocol availability distinct from concrete transitions|
|https://developer.apple.com/documentation/swiftui/navigationtransition/zoom(sourceid:in:)|iOS18; matchedTransitionSource; native Mac not listed|
|https://developer.apple.com/documentation/swiftui/navigationtransition/crossfade|iOS27; native Mac not listed|
|https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)|iOS/macOS26+, explicit shape/regular glass|
|https://developer.apple.com/documentation/swiftui/toolbarcontent/visibilitypriority(_:)|iOS27/macOS26.1; high priority example|
|https://developer.apple.com/documentation/swiftui/view/toolbaroverflowmenu(content:)|iOS27; native Mac not listed|
|https://developer.apple.com/documentation/swiftui/toolbaritemplacement/topbarpinnedtrailing|iOS27; native Mac not listed|
|https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes|Historical26 notes; not substituted for27 member availability|

Requested toolbarMinimizeBehavior and reorderable-container guessed URLs returned404; no adopted signature inferred.
The overview establishes existence only. CP-C needs SDK declaration before adding those APIs; current decision is defer.
No bulk copying Apple examples; LifeOS interfaces/algorithms are architecture proposals.
Web transition/orb reference URLs and license handling remain in12-REFERENCES.md; supplied source audits reused.
No new direct source audit of their current commits in this pass; CP-E pins before substantial adaptation.

Additional official release-note reads:
- https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes
- https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes
Relevant consequences: native menu behavior, selectable Text gesture changes, State initialization,
HealthKit limited-history permissions, capacity reporting; applied in27. No unsupported new health fields inferred.
