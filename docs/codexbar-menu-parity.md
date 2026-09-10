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

The UI keeps the five-hour session pace and adds an automatic weekly mode plus explicit 4/5/7-day schedules. Automatic uses the existing local analytics records when at least two completed weekly cycles have observations within three hours of the current phase and six hours of cycle end. It compares median usage at that phase and projects the median remaining observed consumption; ETA spreads that projected consumption over the remaining wall time. This historical estimator is Pool Manager-specific, not a port of CodexBar’s learned model. Insufficient coverage is labeled and uses the seven-day linear estimate. Explicit schedules override history (Monday–Thursday, Monday–Friday, or every day in the local calendar). The existing usage client normalizes primary to the five-hour window and secondary to the weekly window. The menu admits predictions only when at least 3% of the window elapsed, remaining quota is positive, the reset lies in that window, and the account has no sync error/exclusion. Missing or expired windows do not produce invented forecasts.

Expected use is elapsed/window duration. Delta is actual minus expected. ETA uses average actual use since window start. The default Codex headroom hint requires reserve over 15 percentage points and at least 1.5 times the safe burn rate. At most 2 percentage points of deviation is on pace and has no progress marker.

## Pool Manager integration

Each account appends the same block vertically. A visible switch button sits beside the account name; the active account shows a Current label in that position. Refresh/open-dashboard stay in the footer. The prior subscription record is retained on the plan line, with stale-record details in a popover. Reset-credit estimates keep their existing approximation marker. No account, OAuth, or router configuration is changed by this display path.

Visual QA uses `ReadmeMenuBarScreenshotGenerationTests` for the full stack in both appearances and an isolated weekly block for comparison with the requested CodexBar reference. Main-window styling is outside this menu change.

## History and alerts

The application runtime records successful usage syncs into the existing analytics store even with the dashboard closed; the dashboard reads that same store. The menu offers a 14-day chart of observed weekly-quota consumption in percentage points. Missing observations are not zero usage. Existing retention settings apply, so tight retention can prevent historical predictions. Invalid stored history is preserved and reported instead of overwritten.

Reset-expiry reminders default on and notify once per account/expiry batch within 24 hours. The notification must be accepted by macOS before its delivery marker is persisted. Estimated expiries remain labeled. Failed/excluded accounts, expired credits, and usage snapshots older than one hour are withheld. The app must remain running, and notification permission is required. This does not redeem credits.

Official service status defaults on and fetches the public OpenAI `api/v2/summary.json` at most once every five minutes. The menu explicitly describes OpenAI-wide status, links to the official page, and shows the last check time. Errors make retained results non-authoritative. The status request contains no account credentials. Both alerts and the work-day schedule can be configured in Settings.
