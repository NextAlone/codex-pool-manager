# CodexBar menu parity

Reference: [steipete/CodexBar at b76508292e6849929bb4e838ee3d5d2a1072bc64](https://github.com/steipete/CodexBar/tree/b76508292e6849929bb4e838ee3d5d2a1072bc64).
The MIT notice is bundled in `CodexPoolManager/ThirdPartyNotices/CodexBar.txt`.

## Layout and rendering

- `UsageMenuCardLayout.swift`, `MenuCardView.swift`: 310 pt base width, 20 pt horizontal padding, 6 pt header padding, 4 pt header line spacing, 12 pt header column spacing, 10 pt usage top padding, 12 pt metric/credit section spacing, 6 pt section bottom padding.
- Header: headline semibold provider, subheadline secondary account, footnote secondary update and plan. Metrics: body medium title, footnote reset and pace, 6 pt gaps.
- `MenuCardView+CodexResetCredits.swift`: body medium title, footnote semibold count, caption expiry summary (first four plus overflow count), complete expiry details on hover/click.
- `UsageProgressBar.swift`, `MenuHighlightStyle.swift`, `CodexProviderDescriptor.swift`: 6 pt Canvas bar, RGB (73, 163, 176), tertiary-label track at 0.22 opacity, 6 pt pace punch with 2 pt red/green center marker. Native `.menu` material bridges the SwiftUI MenuBarExtra window host.
- `UsageFormatter.swift`, `UsagePaceText.swift`: same countdown rounding and localized strings.

## Forecast

`CodexBarUsagePace.swift` preserves the upstream pure calculation, with renamed types and a local rate-window adapter. Upstream `UsagePaceTests.swift` is retained as a parity suite, including window boundaries, stage thresholds, ETA, and work-day behavior.

The UI uses CodexBar's defaults: seven-day linear weekly pace, five-hour session pace, no work-day restriction, no learned historical model (`historicalTrackingEnabled` defaults to false upstream). The existing usage client normalizes primary to the five-hour window and secondary to the weekly window. The menu admits predictions only when at least 3% of the window elapsed, remaining quota is positive, the reset lies in that window, and the account has no sync error/exclusion. Missing or expired windows do not produce invented forecasts.

Expected use is elapsed/window duration. Delta is actual minus expected. ETA uses average actual use since window start. The default Codex headroom hint requires reserve over 15 percentage points and at least 1.5 times the safe burn rate. At most 2 percentage points of deviation is on pace and has no progress marker.

## Pool Manager integration

Each account appends the same block vertically. A visible switch button sits beside the account name; the active account shows a Current label in that position. Refresh/open-dashboard stay in the footer. The prior subscription record is retained on the plan line, with stale-record details in a popover. Reset-credit estimates keep their existing approximation marker. No account, OAuth, or router configuration is changed by this display path.

Visual QA uses `ReadmeMenuBarScreenshotGenerationTests` for the full stack in both appearances and an isolated weekly block for comparison with the requested CodexBar reference. Main-window styling is outside this menu change.
