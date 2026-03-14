# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project Overview

timeSlice is a macOS menu bar app that periodically captures the frontmost window, runs text recognition, and stores results locally for automated work report generation. Privacy-first design: all data stays local. Menu bar only (no Dock icon via `LSUIElement = YES`).

## Build & Run Commands

This project uses **Xcode only** (no Package.swift).

```bash
# Build (Xcode project)
xcodebuild -project timeSlice.xcodeproj -scheme timeSlice -configuration Debug -derivedDataPath ./.xcode-derived build

# Run the built .app
open ./.xcode-derived/Build/Products/Debug/timeSlice.app

# Run tests (currently unavailable: scheme has no test action configured)
# xcodebuild -project timeSlice.xcodeproj -scheme timeSlice -configuration Debug -derivedDataPath ./.xcode-derived test
# xcodebuild -project timeSlice.xcodeproj -scheme timeSlice -configuration Debug -derivedDataPath ./.xcode-derived test -only-testing:TimeSliceCoreTests/TestClassName/testMethodName
```

**Note:** `swift build` / `swift test` / `swift run` do NOT work.

## Architecture

**Xcode project (swift-tools-version: 6.2, macOS 14+)** with a single app target:

- `timeSlice` — menu bar app target containing both app-layer code (`Sources/timeSliceApp`) and core/business logic modules (`Sources/TimeSliceCore`)

### Capture Pipeline

```
CaptureScheduler (actor, periodic loop)
  → ScreenCapturing protocol → ScreenCaptureManager (ScreenCaptureKit)
                             → RectangleCaptureScreenCapturing (screencapture -i)
    → CapturedWindow { image, windowTitle?, browserURL?, documentPath?, applicationBundlePath? }
  → BrowserURLResolving protocol → BrowserURLResolver (AppleScript, per-browser)
  → TextRecognizing protocol → Vision-based recognizer implementation
  → DuplicateDetector (actor, hash-based consecutive dedup)
  → DataStore (JSON) + ImageStore (PNG/JPG selectable)
```

- `CaptureScheduler.performCaptureCycle(captureTrigger:manualComment:)` returns `CaptureCycleOutcome` enum (.saved/.skipped/.failed)
- `CaptureScheduler.prepareManualCaptureDraft()` / `saveManualCaptureDraft(_:manualComment:captureTrigger:)` — two-phase flow used by both manual and rectangle captures. `captureTrigger` defaults to `.manual`
- `CaptureTrigger` enum: `.scheduled` (periodic loop) / `.manual` ("Capture Now" button or global hotkey) / `.rectangleCapture` (interactive rectangle via `screencapture -i`)
- `CaptureRecord` includes: `windowTitle: String?`, `captureTrigger: CaptureTrigger`, `comments: String?`, `browserURL: String?`, `documentPath: String?`, `applicationBundlePath: String?`
- Capture exclusion supports **partial matching** on both foreground `applicationName` and `windowTitle`; when matched, text-recognition/image save is skipped and metadata-only record is stored. For scheduled captures, OCR text is also checked against `excludedWindowTitles`; if matched, image save is skipped and metadata-only record is stored (same behavior as window-title exclusion). Manual/rectangle captures are not subject to OCR-text exclusion.
- Non-scheduled captures (`.manual`, `.rectangleCapture`) are persisted even when recognized text is short/duplicate. Manual blank Enter input is stored as `comments: ""`; rectangle captures also store `comments` (from popup after selection)
- For scheduled captures, OCR text is normalized line-by-line and lines shorter than `minimumTextLength` are excluded; if no valid lines remain, the cycle is skipped as `.shortText`
- `normalizeManualComment` returns `nil` only for `.scheduled`; both `.manual` and `.rectangleCapture` always persist `comments`

### Report Pipeline

```
ReportGenerator (struct, orchestrator)
  → DataStore.loadRecords(on:timeRange:) — loads daily CaptureRecords (optionally filtered by time range)
  → DataStore.loadRecordsForSlot(...) — merges primary-day and overflow-day records for cross-midnight slots
  → PromptBuilder.buildDailyReportPrompt(...) — template with {{DATE}}, {{TIME_RANGE}}, {{JSON_GLOB_PATH}}, {{JSON_FILE_LIST}}, {{RECORD_COUNT}}
  → CLIExecutor (runs external AI CLI, e.g. gemini -p "...")
  → saves markdown → GeneratedReport { reportDate, reportFileURL, markdownText, sourceRecordCount, timeSlotLabel? }
```

- **ReportGenerationConfiguration**: runtime params (command, arguments, timeout, outputFileName, outputDirectoryURL, promptTemplate). `withOutputFileName()` returns a copy with different file name
- **CLIExecutor** runs with cwd set to `data/` directory so the AI CLI can read `./YYYY/MM/DD/*.json` directly
- Handles SIGPIPE, PATH injection for GUI context, `-p`/`--prompt` trailing-flag auto-fill, and configurable timeout
- **PromptBuilder** uses file-reference strategy with customizable template (localized default via `NSLocalizedString`)
- Placeholder expansion:
  - `{{JSON_GLOB_PATH}}`: space-separated glob paths
  - `{{JSON_FILE_LIST}}`: newline-separated glob paths
  - cross-midnight slots include both target-day and next-day globs
- **Backup on re-generation**: existing report is backed up as `report-YYYY-MM-DD-HHmmss.md` before overwriting
- **Last-run diagnostics log**: each report execution (success/failure) overwrites `logs/report-last-run.json` with command, arguments, prompt, output, status, and error message

### Report Scheduling

```
ReportScheduler (actor, time-slot-based auto-generation)
  → checks enabled + configured time slots
  → ReportGenerator.generateReport(for:targetDate:configuration:)
  → ReportSchedulerResult (.succeeded / .skippedNoRecords / .failed)
  → ReportNotificationManager (UNUserNotificationCenter)
```

- **Time-slot-only model**: no single-time mode — all scheduling uses time slots
- `ReportTimeSlot` (Codable, Identifiable): configurable time window with start/end times, enable/disable, and optional `promptTemplateID: UUID?`. No label field — uses auto-generated `timeRangeLabel` (e.g. "08:00-25:00")
- `endHour` supports values up to 30 (next day 06:00). `endHour >= 24` means execution fires after midnight, targeting the previous day's records
- `executionIsNextDay`, `executionHour`, `primaryDayTimeRange`, `overflowDayTimeRange` — computed properties for cross-midnight handling
- `ReportTimeRange`: lightweight filter struct with `contains(_:Date)` for record filtering
- Default slots: Full day 08:00-25:00 (enabled), Morning 08:00-12:00, Afternoon 12:00-18:00, Evening 18:00-25:00 (all disabled)
- Output naming: `report.md` when only one slot is enabled, `report-HHMM-HHMM.md` when multiple slots are enabled
- `snapshot()` returns `ReportSchedulerState` (includes `timeSlots`, `nextTimeSlotRangeLabel`, `lastResultSequence`) for UI status display
- Next execution time is calculated from each slot's `executionHour:executionMinute` on the current day, then shifted to next day only when already past
- Target date auto-calculated per slot: `executionIsNextDay` → previous day, otherwise current day
- `DataStore.loadRecordsForSlot()` handles cross-midnight loading by merging records from two calendar days
- Scheduled result notifications are deduplicated via `lastResultSequence` and emitted once per execution
- Scheduler loop lifecycle is guarded by a generation counter (`schedulerLoopGeneration`) so stale canceled loops cannot clear or replace the active loop state during `updateSchedule()` races; this prevents duplicate auto-generation for the same slot time.
- Migration from legacy settings (`reportTargetDayOffset`, `reportTimeSlotsEnabled`, `reportAutoGenerationHour/Minute`) via `AppSettingsResolver.migrateReportSettingsIfNeeded()`
- Migration from legacy single prompt template to multi-template list via `AppSettingsResolver.migratePromptTemplateIfNeeded()` (migration key: `migration.promptTemplates.v1`)
- Migration from legacy single CLI config (`reportCLICommand` + `reportCLIArguments`) to CLI profile list via `AppSettingsResolver.migrateCLIProfilesIfNeeded()` (migration key: `migration.cliProfiles.v1`)

### Global Keyboard Shortcuts

- **`GlobalHotKeyManager`** (in AppStateSupport.swift): manages three system-wide hotkeys using Carbon `RegisterEventHotKey` API
  - `id: 1` — Capture Now (`onHotKeyPressed` callback → comment popup → manual capture)
  - `id: 2` — Rectangle Capture (`onRectangleCaptureHotKeyPressed` callback → `screencapture -i` → comment popup → save)
  - `id: 3` — Open Viewer (`onOpenViewerHotKeyPressed` callback → opens Capture Viewer window)
- `updateRegistration(_:)` / `updateRectangleCaptureRegistration(_:)` / `updateOpenViewerRegistration(_:)` — separate registration methods per hotkey slot
- User records shortcuts in Settings → General tab via `CaptureNowShortcutRecorderView` (uses `NSEvent.addLocalMonitorForEvents`)
- Modifier key required (⌘/⌥/⌃/⇧). Esc cancels, Delete clears
- Settings keys for Capture Now: `captureNowShortcutKey`, `captureNowShortcutModifiers`, `captureNowShortcutKeyCode`
- Settings keys for Rectangle Capture: `rectangleCaptureShortcutKey`, `rectangleCaptureShortcutModifiers`, `rectangleCaptureShortcutKeyCode`
- Settings keys for Open Viewer: `openViewerShortcutKey`, `openViewerShortcutModifiers`, `openViewerShortcutKeyCode`
- Capture Now triggers Spotlight-like comment popup (`NSPanel`) first
- Rectangle Capture runs `screencapture -i` (interactive selection) first; comment popup appears after selection completes
- In popup: `Enter` executes capture + text recognition + save (blank input persists as `comments: ""`)
- In popup: `⌘ + ENTER` does not save; it opens Capture Viewer and applies current input as the search query
- Popup header shows capture target context values in two lines (no labels): frontmost application name and window title (`(No Title)` fallback)
- On popup open, tries to prefill the comment field with currently selected text from the frontmost app (AX permission required; first attempt prompts for permission when missing; falls back to empty when unavailable)
- While the comment popup is visible, pressing the same global shortcut again dismisses the popup (cancel, no save)

### Notifications

- **Capture completion**: both `.manual` and `.rectangleCapture` triggers post a notification with app name + window title (or fallback text); `.scheduled` captures do not post notifications. For saved records, notification `userInfo` includes `captureRecordID` + `capturedAtEpochSeconds`, and clicking the notification opens Capture Viewer with the corresponding record selected.
- **Report generation success**: both manual and scheduled, showing report file name + record count
- **Report generation failure**: both manual and scheduled, showing localized error message
- **`ReportNotificationManager`** (in AppStateSupport.swift): manages `UNUserNotificationCenter` authorization and posting
- **`TimeSliceAppDelegate`** (in timeSliceApp.swift): handles notification click routing — report notifications open report file via `/usr/bin/open`; capture notifications post a selection request event consumed by `AppState`

### Localization

- Full i18n with `ja.lproj/Localizable.strings` and `en.lproj/Localizable.strings` in `Sources/Resources/`
- `Localization.swift` provides `L10n` enum with `string(_:)` and `format(_:args...)` helpers
- All UI strings, menu items, notifications, and error messages are localized

### Storage Layout

App Sandbox is **disabled** (Hardened Runtime is enabled). All data goes to `~/Library/Application Support/timeSlice/`.

Stored structure:
- `data/YYYY/MM/DD/HHMMSS_xxxx.json` — CaptureRecord (30-day retention)
- `images/YYYY/MM/DD/HHMMSS_xxxx.(png|jpg)` — screenshots (3-day retention)
- `logs/report-last-run.json` — latest report execution details (command/prompt/output/status/error)
- `reports/YYYY/MM/DD/report.md` — full-day report (custom output directory supported)
- `reports/YYYY/MM/DD/report-HHMM-HHMM.md` — time-slot report (e.g. `report-0800-1200.md`)

`StoragePathResolver` builds all paths. `DataStore` and `ImageStore` handle persistence and expiry cleanup.

### App Layer (timeSliceApp)

- **`AppState`** (`@MainActor @Observable`): owns all core instances including `ReportScheduler`, `ReportNotificationManager`, and `GlobalHotKeyManager`. Coordinates UI state, handles capture start/stop and report generation, and bridges capture-notification click events into Capture Viewer selection requests
- **`AppSettings`**: `AppSettingsKey` enum for UserDefaults keys + `AppSettingsResolver` enum with static resolver functions (defaults, clamping, parsing). All settings persisted via `@AppStorage`
  - Capture settings: `captureIntervalSeconds`, `captureMinimumTextLength`, `captureShouldSaveImages`, `captureImageFormat`, `captureExcludedApplications`, `captureExcludedWindowTitles`
  - Report settings: `reportAutoGenerationEnabled`, `reportOutputDirectoryPath`, `reportPromptTemplate` (legacy), `reportPromptTemplatesJSON`, `reportTimeSlotsJSON`, `reportCLIProfilesJSON`, `reportSelectedCLIProfileID`
  - Viewer settings: `captureViewerTimeSortOrder`
  - Shortcut settings: `captureNowShortcutKey`, `captureNowShortcutModifiers`, `captureNowShortcutKeyCode`, `rectangleCaptureShortcutKey`, `rectangleCaptureShortcutModifiers`, `rectangleCaptureShortcutKeyCode`, `openViewerShortcutKey`, `openViewerShortcutModifiers`, `openViewerShortcutKeyCode`
  - Startup settings: `startCaptureOnAppLaunchEnabled`, `launchAtLoginEnabled`
- Loaded time slots are normalized in `resolveReportTimeSlots` (`startHour: 0...23`, `endHour: 1...30`, minutes `0...59`) and persisted back when needed
- Time-slot editor in Settings uses a single 10-minute-step control per time value (minute rollover increments/decrements hour); each row also includes a prompt template Picker (inline in the same HStack row)
- **`PromptTemplate`** (in `PromptTemplate.swift`): `Codable, Identifiable, Equatable, Sendable` struct with `id: UUID`, `name: String`, `template: String`. Stored as JSON array in `reportPromptTemplatesJSON`. "Default" template is not persisted — represented by `selectedPromptTemplateID == nil`
- **`ReportCLIProfile`** (in `PromptTemplate.swift`): `Codable, Identifiable, Equatable, Sendable` struct with `id: UUID`, `name: String`, `command: String`, `argumentsText: String`. Stored as JSON array in `reportCLIProfilesJSON`; active profile is tracked by `reportSelectedCLIProfileID`
- `AppSettingsResolver.resolvePromptTemplates()` / `savePromptTemplates()` — JSON encode/decode for template list
- `AppSettingsResolver.resolveReportCLIProfiles()` / `saveReportCLIProfiles()` — JSON encode/decode for CLI profile list
- `AppSettingsResolver.migratePromptTemplateIfNeeded()` — migrates legacy `reportPromptTemplate` to a named "カスタム" entry and assigns it to all existing slots; runs once per installation
- `AppSettingsResolver.migrateCLIProfilesIfNeeded()` — migrates legacy single CLI command/arguments to a named profile and keeps one active selection; runs once per installation
- `resolveReportGenerationConfigurationForSlot()` resolves prompt by looking up `slot.promptTemplateID` in the templates list; falls back to legacy `reportPromptTemplate` if `nil`
- **`SettingsView`**: `Form` + `grouped` style with 5 tabs (General / Capture / CLI / Report / Prompt). Uses `frame` with `idealWidth: 700, idealHeight: 640`
- General tab permission section tracks screen recording, accessibility (selected text + document path access), and Automation (browser URL) permissions with per-permission request/open-settings buttons
- CLI tab: Picker to select active CLI profile, +/- buttons to add/delete sets, editable set name/command/arguments fields, and shared timeout Stepper. Changes auto-saved via `saveCLIProfiles()`
- Prompt tab: Picker to select active template (Default + custom templates), +/- buttons to add/delete, name `TextField` for rename, `TextEditor` for content editing (computed `Binding<String>`). Default template is read-only and cannot be deleted. Changes auto-saved via `savePromptTemplates()`
- **`CaptureViewerView`**: dedicated viewer window opened from menu (not embedded in Settings). Supports start/end date range selection plus presets (`today`, `yesterday`, `last 3/7/30 days`, `all time`), sort (asc/desc, persisted), application filter (with app icons in menu), trigger filter (all / manual only — manual-only includes both `.manual` and `.rectangleCapture`), and text search over `windowTitle`/`ocrText`/`browserURL`/`documentPath`/`comments` (applies on Enter). Search matches are highlighted, and non-scheduled records (`.manual`, `.rectangleCapture`) show an indicator next to timestamps in both panes. List rows display app icons (48x48) resolved from `applicationBundlePath` (priority) → running apps → path guessing → generic fallback, with icon cache keyed by app name. Single-day ranges keep hour-based section headers with a time side index bar; multi-day ranges switch to date-based section headers with a date side index bar. `browserURL` and `documentPath` in the detail pane are clickable and expose right-click actions (open/copy, plus Finder reveal for file paths). Application name in detail pane is clickable (launches app) with context menu (launch / reveal in Finder). Image previews expose right-click actions to open, reveal in Finder, or move the image to Trash. Left-pane rows expose right-click actions to reveal the backing JSON in Finder or move the entire record (JSON + linked image) to Trash. It also accepts external selection requests (notification click), resets filters/search as needed, and selects the target record by ID.
- **Menu bar**: `MenuBarExtra` with `.menu` style — standard dropdown (settings, start/stop, capture now with optional keyboard shortcut, capture rectangle with optional keyboard shortcut, generate report, open viewer with optional keyboard shortcut, about, quit). Opening settings/viewer activates `timeSlice` to front.
  - "Generate report" (`reportGenerateButton` `@ViewBuilder` in `MenuBarMenuContentView`) adapts to enabled time slots: 1 slot → `Button` calling `generateReportForTimeSlot(isSoleEnabledSlot: true)`; 2+ slots → `Menu` submenu with one entry per enabled slot (label = `slot.timeRangeLabel`); 0 slots → fallback `generateDailyReport()` (full-day). Slot list is reactive via `@AppStorage(reportTimeSlotsJSON)`.

### Key Design Patterns

- **Protocol-based DI**: `ScreenCapturing`, `TextRecognizing`, `BrowserURLResolving`, `CLIExecutable` protocols enable mock injection for tests
- **Actor isolation**: `CaptureScheduler`, `DuplicateDetector`, `ReportScheduler` are actors for thread safety
- **`@unchecked Sendable`**: Used on `DataStore`, `ImageStore`, `StoragePathResolver`, `CLIExecutor`, `BrowserURLResolver` (value-type structs or classes with only Sendable-safe internal state)

### Concurrency Notes

- Swift 6 strict concurrency mode is active
- UI/application-layer types use explicit `@MainActor` isolation where needed (for example `AppState`)
- Code signing is enabled for both Debug and Release builds

### Screen Capture Permission

Running via terminal binds screen capture permission to Terminal/iTerm. Build and launch the `.app` bundle for proper permission binding.

### Browser URL Capture

- **`BrowserURLResolving`** protocol + **`BrowserURLResolver`** class in `BrowserURLResolving.swift`
- Supported browsers: Safari, Chrome (+ beta/dev/canary), Edge (+ Beta/Dev/Canary), Brave (+ beta/nightly), Arc, Vivaldi
- Firefox not supported (no AppleScript dictionary)
- Uses `NSAppleScript` via `Task.detached` with `withTaskGroup` timeout race pattern
- Per-browser first-attempt timeout: 30s (permission dialog may appear), subsequent: 3s
- Requires `com.apple.security.automation.apple-events` entitlement (`timeSlice.entitlements`) and `NSAppleEventsUsageDescription` in Info.plist
- macOS prompts Automation permission per target browser on first AppleScript execution; denied → returns `nil`, capture continues normally

## Not Yet Implemented

- `ReportPreviewView` (markdown preview, copy, open in Finder)
- Unit tests for report generation (`PromptBuilder` / `ReportGenerator`)

See `docs/scalable-meandering-mountain.md` for the full plan and `docs/implementation-todo.md` for task checklist.
