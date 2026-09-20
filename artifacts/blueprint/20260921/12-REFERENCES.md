# Sources and reference policy
Accessed 2026-09-21 during planning, except supplied Luna report details explicitly noted.
References are design/API evidence, not proof that app behavior passes.
Local design authority: /Users/georgdomke/Arbeit/VS Code/LifeOS Design/developers/design-coordination/.
Brand source: /Users/georgdomke/Library/Mobile Documents/com~apple~CloudDocs/geon/colors.md.
Newer explicit user decisions override older files: green estimates, no generic AI, planning-only phase.

## Transition references
- https://github.com/Jakubantalik/transitions-dev — inspected; README now points to canonical transitions.dev repository.
- https://github.com/Jakubantalik/transitions.dev — canonical linked home; pin revision before copying implementation ideas.
- https://github.com/Jakubantalik/thinking-orbs — inspected repository; native adaptation informed by supplied Luna source audit.
- https://github.com/Jakubantalik/transitions-dev/blob/main/LICENSE
- https://github.com/Jakubantalik/thinking-orbs/blob/main/LICENSE
These are reference algorithms/interaction principles, not native dependencies.
Any copied/adapted substantial code retains MIT attribution; verify license at pinned revision.
Our concrete native timings, state boundaries and rendering caps are architecture choices requiring measurement.
Prior references retained: Linear, Vercel, motion.dev, Kokonut UI, bklit,
https://forevercomponents.com/infinite/ and https://www.skillsui.app/skills/clean.
They were not newly visually inspected in this pass; do not claim a new screenshot comparison.
Existing Bevel/Revolut/Notion reference requirements must be carried into P00 inventory.
Lock-screen references: /Users/georgdomke/Library/Mobile Documents/com~apple~CloudDocs/Bilder/Zeugs.
No wholesale installation or execution of reference repository scripts during planning.

## Apple primary API references
- https://developer.apple.com/documentation/swiftui/canvas
- https://developer.apple.com/documentation/swiftui/graphicscontext
- https://developer.apple.com/documentation/swiftui/timelineview
- https://developer.apple.com/documentation/swiftui/magnifygesture
- https://developer.apple.com/documentation/swiftui/containerrelativeshape
- https://developer.apple.com/documentation/swiftui/roundedrectangle
- https://developer.apple.com/documentation/swiftui/phaseanimator
- https://developer.apple.com/documentation/swiftui/keyframeanimator
- https://developer.apple.com/documentation/swiftui/view/matchedgeometryeffect
- https://developer.apple.com/documentation/uikit/uiviewpropertyanimator
- https://developer.apple.com/documentation/swiftui/appkit-integration
- https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date
- https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities
- https://developer.apple.com/documentation/appintents/appintent
- https://developer.apple.com/documentation/healthkit/hkworkoutbuilder
- https://developer.apple.com/documentation/healthkit/hkliveworkoutbuilder
- https://developer.apple.com/documentation/foundation/nsfilecoordinator
- https://developer.apple.com/documentation/foundation/nsfilepresenter
- https://developer.apple.com/documentation/foundation/urlsession
- https://developer.apple.com/documentation/cryptokit
- https://developer.apple.com/documentation/cryptokit/curve25519/signing
- https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly
- https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app
- https://developer.apple.com/documentation/photosui/photospicker
- https://developer.apple.com/documentation/visionkit/vndocumentcameraviewcontroller
- https://developer.apple.com/documentation/eventkit/ekeventstore
- https://developer.apple.com/financekit/
- https://developer.apple.com/documentation/cloudkit/ckcontainer
- https://developer.apple.com/help/account/basics/about-your-developer-account

Apple HTML pages may require JavaScript; .md variant was available through curl for MagnifyGesture,
confirming iOS17/macOS14 availability. Other API mappings also use supplied Apple audit;
SDK compile/entitlement verification remains the implementation gate.
Apple account page explicitly states seven-day Personal Team profile expiry and periodic rebuild/reinstall.
No documentation claims that Tailscale keeps suspended iOS applications running.

## Source inspection scope and limits
Inspected required bootstrap/task docs, project.yml, git state, graph/session/index/reducer,
calendar store/coordinator/peer admission, motion/typography/color definitions,
finance detector/store/projector, training/nutrition/supplement APIs,
usage registry, widget publisher/App Intents, gateway admission and Windows launcher.
No canonical Windows/live account/device state was checked in planning.
No runtime security test, visual acceptance run, build or new completion percentage.
13-SOURCE-ANCHORS lists actual symbol anchors and content hashes for audit/rebase.
