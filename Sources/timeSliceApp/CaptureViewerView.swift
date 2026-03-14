import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

private enum CaptureViewerTimeSortOrder: String, CaseIterable, Identifiable {
    case ascending
    case descending

    var id: String {
        rawValue
    }
}

private enum CaptureViewerApplicationFilter: Hashable {
    case all
    case application(String)
}

private enum CaptureViewerCaptureTriggerFilter: String, CaseIterable, Identifiable {
    case all
    case manualOnly

    var id: String {
        rawValue
    }
}

private enum CaptureViewerDateRangePreset: String, CaseIterable, Identifiable {
    case today
    case yesterday
    case last3Days
    case last7Days
    case last30Days
    case allTime

    var id: String {
        rawValue
    }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .today:
            "viewer.preset.today"
        case .yesterday:
            "viewer.preset.yesterday"
        case .last3Days:
            "viewer.preset.last_3_days"
        case .last7Days:
            "viewer.preset.last_7_days"
        case .last30Days:
            "viewer.preset.last_30_days"
        case .allTime:
            "viewer.preset.all_time"
        }
    }
}

private enum CaptureViewerFocusTarget: Hashable {
    case searchInput
    case captureList
}

private enum CaptureViewerListSectionKind: Hashable {
    case hour(Int)
    case day(Date)
}

private struct CaptureViewerListSection: Identifiable {
    let kind: CaptureViewerListSectionKind
    let label: String
    let indexLabel: String
    let targetDate: Date
    let scrollTargetID: UUID
    let artifacts: [CaptureRecordArtifact]

    var id: String {
        switch kind {
        case let .hour(hour):
            return "hour-\(hour)"
        case let .day(date):
            let normalizedDate = Calendar.autoupdatingCurrent.startOfDay(for: date)
            return "day-\(Int(normalizedDate.timeIntervalSinceReferenceDate))"
        }
    }
}

private struct CaptureViewerIndexLabelPlacement: Identifiable {
    let id: String
    let text: String
    let positionRatio: CGFloat
}

private struct CaptureViewerIndexTrackMetrics {
    let minimumCenterY: CGFloat
    let travelHeight: CGFloat
}

private struct CaptureViewerIndexSectionRange {
    let section: CaptureViewerListSection
    let startDate: Date
    let endDateExclusive: Date
}

struct CaptureViewerView: View {
    @Bindable var appState: AppState

    @AppStorage(AppSettingsKey.captureViewerTimeSortOrder)
    private var selectedTimeSortOrderRawValue = CaptureViewerTimeSortOrder.ascending.rawValue
    @State private var captureViewerStartDate = Self.captureViewerDayCalendar.startOfDay(for: Date())
    @State private var captureViewerEndDate = Self.captureViewerDayCalendar.startOfDay(for: Date())
    @State private var selectedDateRangePreset: CaptureViewerDateRangePreset? = .today
    @State private var selectedCaptureArtifactID: UUID?
    @State private var displayedArtifacts: [CaptureRecordArtifact] = []
    @State private var displayedArtifactsByID: [UUID: CaptureRecordArtifact] = [:]
    @State private var isOCRSectionExpanded = false
    @State private var selectedApplicationFilter: CaptureViewerApplicationFilter = .all
    @State private var selectedCaptureTriggerFilter: CaptureViewerCaptureTriggerFilter = .all
    @State private var searchInputText = ""
    @State private var confirmedSearchQueryText = ""
    @State private var lastAppliedExternalSearchRequestSequence: UInt64 = 0
    @State private var lastAppliedExternalSelectionRequestSequence: UInt64 = 0
    @State private var pendingExternalSelectionRecordID: UUID?
    @State private var pendingSelectionAfterReloadRecordID: UUID?
    @State private var appIconCache: [String: NSImage] = [:]
    @State private var displayedSections: [CaptureViewerListSection] = []
    @State private var lastIndexScrolledArtifactID: UUID?
    @State private var isIndexBarHovered = false
    @State private var isIndexBarDragging = false
    @FocusState private var focusedControl: CaptureViewerFocusTarget?

    private var normalizedSearchQueryText: String {
        confirmedSearchQueryText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSingleDaySelection: Bool {
        Self.captureViewerDayCalendar.isDate(captureViewerStartDate, inSameDayAs: captureViewerEndDate)
    }

    private var isIndexBarActive: Bool {
        isIndexBarHovered || isIndexBarDragging
    }

    private var selectedTimeSortOrder: CaptureViewerTimeSortOrder {
        get {
            CaptureViewerTimeSortOrder(rawValue: selectedTimeSortOrderRawValue) ?? .ascending
        }
        nonmutating set {
            selectedTimeSortOrderRawValue = newValue.rawValue
        }
    }

    private var selectedTimeSortOrderBinding: Binding<CaptureViewerTimeSortOrder> {
        Binding(
            get: {
                selectedTimeSortOrder
            },
            set: { updatedSortOrder in
                selectedTimeSortOrder = updatedSortOrder
            }
        )
    }

    private var captureViewerStartDateBinding: Binding<Date> {
        Binding(
            get: {
                captureViewerStartDate
            },
            set: { updatedStartDate in
                setCaptureViewerDateRange(
                    startDate: updatedStartDate,
                    endDate: captureViewerEndDate,
                    preset: nil
                )
            }
        )
    }

    private var captureViewerEndDateBinding: Binding<Date> {
        Binding(
            get: {
                captureViewerEndDate
            },
            set: { updatedEndDate in
                setCaptureViewerDateRange(
                    startDate: captureViewerStartDate,
                    endDate: updatedEndDate,
                    preset: nil
                )
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                DatePicker(
                    L10n.string("viewer.label.start_date"),
                    selection: captureViewerStartDateBinding,
                    in: ...Date(),
                    displayedComponents: .date
                )

                DatePicker(
                    L10n.string("viewer.label.end_date"),
                    selection: captureViewerEndDateBinding,
                    in: ...Date(),
                    displayedComponents: .date
                )

                Menu {
                    ForEach(CaptureViewerDateRangePreset.allCases) { preset in
                        Button {
                            applyDateRangePreset(preset)
                        } label: {
                            Text(preset.localizedTitle)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(L10n.string("viewer.label.date_preset"))
                        Text(resolveSelectedDateRangePresetTitle())
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)

                Button("viewer.button.reload") {
                    loadCaptureViewerArtifacts()
                }
                .disabled(appState.isLoadingCaptureViewerArtifacts)

                Spacer()

                Text(L10n.format("viewer.label.record_count", displayedArtifacts.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {

                Picker("viewer.label.sort_order", selection: selectedTimeSortOrderBinding) {
                    Text("viewer.value.sort_ascending")
                        .tag(CaptureViewerTimeSortOrder.ascending)
                    Text("viewer.value.sort_descending")
                        .tag(CaptureViewerTimeSortOrder.descending)
                }
                .pickerStyle(.menu)
                .onChange(of: selectedTimeSortOrderRawValue) { _, _ in
                    refreshDisplayedArtifacts()
                }

                Picker("viewer.label.application_filter", selection: $selectedApplicationFilter) {
                    Text("viewer.value.filter_all_applications")
                        .tag(CaptureViewerApplicationFilter.all)
                    ForEach(availableApplicationNames, id: \.self) { applicationName in
                        Label {
                            Text(applicationName)
                        } icon: {
                            Image(nsImage: resolveApplicationIconForMenu(for: applicationName))
                        }
                        .tag(CaptureViewerApplicationFilter.application(applicationName))
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedApplicationFilter) { _, _ in
                    refreshDisplayedArtifacts()
                }

                Picker("viewer.label.capture_trigger_filter", selection: $selectedCaptureTriggerFilter) {
                    Text("viewer.value.filter_all_triggers")
                        .tag(CaptureViewerCaptureTriggerFilter.all)
                    Text("viewer.value.filter_manual_only")
                        .tag(CaptureViewerCaptureTriggerFilter.manualOnly)
                }
                .pickerStyle(.menu)
                .onChange(of: selectedCaptureTriggerFilter) { _, _ in
                    refreshDisplayedArtifacts()
                }

                TextField("viewer.placeholder.search_text", text: $searchInputText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220, maxWidth: .infinity)
                    .focused($focusedControl, equals: .searchInput)
                    .onSubmit {
                        applyCaptureViewerSearchQuery()
                    }

                if appState.isLoadingCaptureViewerArtifacts {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if appState.captureViewerStatusMessage.isEmpty == false {
                Text(appState.captureViewerStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HSplitView {
                ScrollViewReader { scrollProxy in
                    List(selection: $selectedCaptureArtifactID) {
                        ForEach(displayedSections) { section in
                            Section {
                                ForEach(section.artifacts) { artifact in
                                    captureViewerRowView(artifact: artifact)
                                        .id(artifact.id)
                                        .tag(artifact.id)
                                }
                            } header: {
                                Text(section.label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .id(section.id)
                        }
                    }
                    .focused($focusedControl, equals: .captureList)
                    .listStyle(.inset)
                    .overlay(alignment: .trailing) {
                        captureViewerIndexBar(sections: displayedSections, scrollProxy: scrollProxy)
                    }
                }
                .frame(minWidth: 320, idealWidth: 370, maxWidth: 440)

                Group {
                    if let selectedCaptureArtifact {
                        captureViewerDetailView(artifact: selectedCaptureArtifact)
                    } else {
                        Text("viewer.placeholder.select_record")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .onAppear {
            let didApplyExternalSelectionRequest = applyExternalSelectionRequestIfNeeded()
            _ = applyExternalSearchRequestIfNeeded()
            if didApplyExternalSelectionRequest == false {
                loadCaptureViewerArtifacts()
            }
            if didApplyExternalSelectionRequest == false {
                focusCaptureList()
            }
        }
        .onChange(of: selectedCaptureArtifactID) { _, _ in
            isOCRSectionExpanded = false
        }
        .onChange(of: appState.captureViewerSearchRequestSequence) { _, _ in
            applyExternalSearchRequestIfNeeded()
        }
        .onChange(of: appState.captureViewerSelectionRequestSequence) { _, _ in
            applyExternalSelectionRequestIfNeeded()
        }
        .onChange(of: appState.captureViewerArtifacts) { _, _ in
            synchronizeApplicationFilterIfNeeded()
            refreshDisplayedArtifacts()
        }
    }

    private var availableApplicationNames: [String] {
        let uniqueApplicationNames = Set(appState.captureViewerArtifacts.map(\.record.applicationName))
        return uniqueApplicationNames.sorted { leftName, rightName in
            leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
        }
    }

    private var selectedCaptureArtifact: CaptureRecordArtifact? {
        guard let selectedCaptureArtifactID else {
            return nil
        }
        return displayedArtifactsByID[selectedCaptureArtifactID]
    }

    private func resolveDisplayedArtifacts() -> [CaptureRecordArtifact] {
        let captureTriggerFilteredArtifacts = appState.captureViewerArtifacts.filter { artifact in
            switch selectedCaptureTriggerFilter {
            case .all:
                return true
            case .manualOnly:
                return artifact.record.captureTrigger.isUserInitiated
            }
        }
        let applicationFilteredArtifacts = captureTriggerFilteredArtifacts.filter { artifact in
            switch selectedApplicationFilter {
            case .all:
                return true
            case let .application(applicationName):
                return artifact.record.applicationName == applicationName
            }
        }
        let searchFilteredArtifacts = applicationFilteredArtifacts.filter(matchesSearchQuery)
        return searchFilteredArtifacts.sorted(by: compareCaptureArtifactsByTime)
    }

    private func compareCaptureArtifactsByTime(_ leftArtifact: CaptureRecordArtifact, _ rightArtifact: CaptureRecordArtifact) -> Bool {
        if leftArtifact.record.capturedAt == rightArtifact.record.capturedAt {
            switch selectedTimeSortOrder {
            case .ascending:
                return leftArtifact.record.id.uuidString < rightArtifact.record.id.uuidString
            case .descending:
                return leftArtifact.record.id.uuidString > rightArtifact.record.id.uuidString
            }
        }
        switch selectedTimeSortOrder {
        case .ascending:
            return leftArtifact.record.capturedAt < rightArtifact.record.capturedAt
        case .descending:
            return leftArtifact.record.capturedAt > rightArtifact.record.capturedAt
        }
    }

    private func matchesSearchQuery(_ artifact: CaptureRecordArtifact) -> Bool {
        guard normalizedSearchQueryText.isEmpty == false else {
            return true
        }

        let matchesWindowTitle = artifact.record.windowTitle?.range(
            of: normalizedSearchQueryText,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
        let matchesOCRText = artifact.record.ocrText.range(
            of: normalizedSearchQueryText,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
        let matchesComment = (artifact.record.comments ?? "").range(
            of: normalizedSearchQueryText,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
        let matchesBrowserURL = (artifact.record.browserURL ?? "").range(
            of: normalizedSearchQueryText,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
        let matchesDocumentPath = (artifact.record.documentPath ?? "").range(
            of: normalizedSearchQueryText,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
        return matchesWindowTitle || matchesOCRText || matchesComment || matchesBrowserURL || matchesDocumentPath
    }

    private func resolveHighlightedText(_ text: String) -> AttributedString {
        var highlightedText = AttributedString(text)
        guard normalizedSearchQueryText.isEmpty == false else {
            return highlightedText
        }

        var searchRange = text.startIndex..<text.endIndex
        while
            let matchedRange = text.range(
                of: normalizedSearchQueryText,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange
            ),
            let attributedMatchedRange = Range(matchedRange, in: highlightedText)
        {
            highlightedText[attributedMatchedRange].backgroundColor = Color.yellow.opacity(0.35)
            highlightedText[attributedMatchedRange].foregroundColor = .primary
            searchRange = matchedRange.upperBound..<text.endIndex
        }

        return highlightedText
    }

    private func resolveDisplayText(_ text: String) -> Text {
        if normalizedSearchQueryText.isEmpty {
            Text(text)
        } else {
            Text(resolveHighlightedText(text))
        }
    }

    private func normalizeCaptureViewerDate(_ date: Date) -> Date {
        let normalizedDate = Self.captureViewerDayCalendar.startOfDay(for: date)
        let today = Self.captureViewerDayCalendar.startOfDay(for: Date())
        return min(normalizedDate, today)
    }

    private func setCaptureViewerDateRange(
        startDate: Date,
        endDate: Date,
        preset: CaptureViewerDateRangePreset?
    ) {
        let normalizedStartDate = normalizeCaptureViewerDate(startDate)
        let normalizedEndDate = normalizeCaptureViewerDate(endDate)
        let resolvedStartDate = min(normalizedStartDate, normalizedEndDate)
        let resolvedEndDate = max(normalizedStartDate, normalizedEndDate)
        let hasDateRangeChanged =
            resolvedStartDate != captureViewerStartDate || resolvedEndDate != captureViewerEndDate

        captureViewerStartDate = resolvedStartDate
        captureViewerEndDate = resolvedEndDate
        selectedDateRangePreset = preset

        guard hasDateRangeChanged else {
            return
        }
        loadCaptureViewerArtifacts()
    }

    private func resolveSelectedDateRangePresetTitle() -> String {
        guard let selectedDateRangePreset else {
            return L10n.string("viewer.value.custom_range")
        }

        switch selectedDateRangePreset {
        case .today:
            return L10n.string("viewer.preset.today")
        case .yesterday:
            return L10n.string("viewer.preset.yesterday")
        case .last3Days:
            return L10n.string("viewer.preset.last_3_days")
        case .last7Days:
            return L10n.string("viewer.preset.last_7_days")
        case .last30Days:
            return L10n.string("viewer.preset.last_30_days")
        case .allTime:
            return L10n.string("viewer.preset.all_time")
        }
    }

    private func applyDateRangePreset(_ preset: CaptureViewerDateRangePreset) {
        let today = Self.captureViewerDayCalendar.startOfDay(for: Date())

        switch preset {
        case .today:
            setCaptureViewerDateRange(startDate: today, endDate: today, preset: preset)
        case .yesterday:
            let yesterday = Self.captureViewerDayCalendar.date(byAdding: .day, value: -1, to: today) ?? today
            setCaptureViewerDateRange(startDate: yesterday, endDate: yesterday, preset: preset)
        case .last3Days:
            let startDate = Self.captureViewerDayCalendar.date(byAdding: .day, value: -2, to: today) ?? today
            setCaptureViewerDateRange(startDate: startDate, endDate: today, preset: preset)
        case .last7Days:
            let startDate = Self.captureViewerDayCalendar.date(byAdding: .day, value: -6, to: today) ?? today
            setCaptureViewerDateRange(startDate: startDate, endDate: today, preset: preset)
        case .last30Days:
            let startDate = Self.captureViewerDayCalendar.date(byAdding: .day, value: -29, to: today) ?? today
            setCaptureViewerDateRange(startDate: startDate, endDate: today, preset: preset)
        case .allTime:
            Task { @MainActor in
                let oldestRecordDate = await appState.resolveCaptureViewerOldestRecordDate()
                let startDate = oldestRecordDate.map(normalizeCaptureViewerDate) ?? today
                setCaptureViewerDateRange(startDate: startDate, endDate: today, preset: preset)
            }
        }
    }

    private func loadCaptureViewerArtifacts() {
        let startDate = captureViewerStartDate
        let endDate = captureViewerEndDate
        Task { @MainActor in
            await appState.loadCaptureViewerArtifacts(from: startDate, through: endDate)
            synchronizeApplicationFilterIfNeeded()
            refreshDisplayedArtifacts()
        }
    }

    private func refreshDisplayedArtifacts() {
        let refreshedArtifacts = resolveDisplayedArtifacts()
        displayedArtifacts = refreshedArtifacts
        displayedArtifactsByID = Dictionary(
            uniqueKeysWithValues: refreshedArtifacts.map { artifact in
                (artifact.id, artifact)
            }
        )
        buildAppIconCache(for: appState.captureViewerArtifacts)
        displayedSections = buildListSections(from: refreshedArtifacts)
        let didApplyPendingSelection = applyPendingSelectionAfterReloadIfNeeded()
        if didApplyPendingSelection == false {
            synchronizeSelectedCaptureArtifactIfNeeded()
        }
        applyPendingExternalSelectionIfNeeded()
    }

    private func synchronizeApplicationFilterIfNeeded() {
        switch selectedApplicationFilter {
        case .all:
            return
        case let .application(applicationName):
            let isApplicationPresent = availableApplicationNames.contains(applicationName)
            if isApplicationPresent == false {
                selectedApplicationFilter = .all
            }
        }
    }

    private func synchronizeSelectedCaptureArtifactIfNeeded() {
        guard displayedArtifacts.isEmpty == false else {
            selectedCaptureArtifactID = nil
            isOCRSectionExpanded = false
            return
        }

        let hasSelectedArtifact = displayedArtifacts.contains { artifact in
            artifact.id == selectedCaptureArtifactID
        }
        if hasSelectedArtifact {
            return
        }
        selectedCaptureArtifactID = displayedArtifacts.first?.id
    }

    private func applyPendingExternalSelectionIfNeeded() {
        guard let pendingRecordID = pendingExternalSelectionRecordID else {
            return
        }
        guard displayedArtifactsByID[pendingRecordID] != nil else {
            return
        }
        selectedCaptureArtifactID = pendingRecordID
        pendingExternalSelectionRecordID = nil
    }

    @discardableResult
    private func applyPendingSelectionAfterReloadIfNeeded() -> Bool {
        guard let pendingRecordID = pendingSelectionAfterReloadRecordID else {
            return false
        }
        pendingSelectionAfterReloadRecordID = nil
        guard displayedArtifactsByID[pendingRecordID] != nil else {
            return false
        }
        selectedCaptureArtifactID = pendingRecordID
        return true
    }

    @ViewBuilder
    private func captureViewerRowView(artifact: CaptureRecordArtifact) -> some View {
        let windowTitleText = artifact.record.windowTitle?.isEmpty == false
            ? artifact.record.windowTitle ?? ""
            : L10n.string("viewer.value.no_window_title")

        HStack(spacing: 8) {
            Image(nsImage: resolveApplicationIcon(for: artifact.record.applicationName))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(Self.captureViewerTimeFormatter.string(from: artifact.record.capturedAt))
                        .font(.system(.body, design: .monospaced))

                    Image(systemName: resolveCaptureImageLinkStateIconName(artifact.imageLinkState))
                        .foregroundStyle(resolveCaptureImageLinkStateColor(artifact.imageLinkState))
                        .accessibilityLabel(resolveCaptureImageLinkStateText(artifact.imageLinkState))

                    captureViewerManualIndicatorView(for: artifact.record.captureTrigger)

                    Spacer()
                }

                Text(artifact.record.applicationName)
                    .lineLimit(1)

                resolveDisplayText(windowTitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .padding(.trailing, 20)
        .contextMenu {
            Button("viewer.menu.reveal_json") {
                appState.revealCaptureViewerFile(artifact.jsonFileURL)
            }
            Button("viewer.menu.delete_record", role: .destructive) {
                trashCaptureViewerRecord(artifact)
            }
        }
    }

    @ViewBuilder
    private func captureViewerDetailView(artifact: CaptureRecordArtifact) -> some View {
        let windowTitleText = artifact.record.windowTitle?.isEmpty == false
            ? artifact.record.windowTitle ?? ""
            : L10n.string("viewer.value.no_window_title")
        let commentText = artifact.record.comments?.isEmpty == false
            ? artifact.record.comments ?? ""
            : resolveCaptureCommentText(artifact.record.comments)

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Self.captureViewerDateTimeFormatter.string(from: artifact.record.capturedAt))
                        .font(.headline)
                    captureViewerManualIndicatorView(for: artifact.record.captureTrigger)
                    Spacer(minLength: 0)
                }

                captureViewerSectionSeparator

                Group {
                    captureViewerLinkRow(
                        iconName: "desktopcomputer",
                        accessibilityLabel: L10n.string("viewer.field.application_name"),
                        value: artifact.record.applicationName,
                        action: {
                            launchApplication(record: artifact.record)
                        }
                    ) {
                        Button("viewer.menu.launch_application") {
                            launchApplication(record: artifact.record)
                        }
                        Button("viewer.menu.reveal_application") {
                            revealApplicationInFinder(record: artifact.record)
                        }
                    }
                    captureViewerTextRow(
                        iconName: "macwindow",
                        accessibilityLabel: L10n.string("viewer.field.window_title"),
                        value: windowTitleText
                    )
                    captureViewerTextRow(
                        iconName: "text.bubble",
                        accessibilityLabel: L10n.string("viewer.section.comments"),
                        value: commentText
                    )
                    if let browserURL = artifact.record.browserURL, browserURL.isEmpty == false {
                        captureViewerLinkRow(
                            iconName: "link",
                            accessibilityLabel: L10n.string("viewer.field.browser_url"),
                            value: browserURL,
                            action: {
                                appState.openCaptureViewerURL(browserURL)
                            }
                        ) {
                            Button("viewer.menu.open_url") {
                                appState.openCaptureViewerURL(browserURL)
                            }
                            Button("viewer.menu.copy_url") {
                                appState.copyCaptureViewerText(browserURL)
                            }
                        }
                    }
                    if let documentPath = artifact.record.documentPath, documentPath.isEmpty == false {
                        let documentFileURL = URL(fileURLWithPath: documentPath)
                        captureViewerLinkRow(
                            iconName: "folder",
                            accessibilityLabel: L10n.string("viewer.field.document_path"),
                            value: documentPath,
                            action: {
                                appState.openCaptureViewerFile(documentFileURL)
                            }
                        ) {
                            Button("viewer.menu.open_file") {
                                appState.openCaptureViewerFile(documentFileURL)
                            }
                            Button("viewer.menu.reveal_file") {
                                appState.revealCaptureViewerFile(documentFileURL)
                            }
                            Button("viewer.menu.copy_file_path") {
                                appState.copyCaptureViewerText(documentPath)
                            }
                        }
                    }
                }
                .font(.subheadline)

                captureViewerSectionSeparator

                VStack(alignment: .leading, spacing: 8) {
                    Text("viewer.section.image")
                        .font(.headline)
                    captureViewerImagePreview(artifact: artifact)
                }

                captureViewerSectionSeparator

                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isOCRSectionExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isOCRSectionExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                            Text("viewer.section.ocr")
                                .font(.headline)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if isOCRSectionExpanded {
                        if artifact.record.ocrText.isEmpty {
                            Text("viewer.value.empty_text")
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            resolveDisplayText(artifact.record.ocrText)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var captureViewerSectionSeparator: some View {
        Divider()
            .frame(maxWidth: .infinity)
    }

    private func applyCaptureViewerSearchQuery() {
        confirmedSearchQueryText = searchInputText
        refreshDisplayedArtifacts()
    }

    @discardableResult
    private func applyExternalSearchRequestIfNeeded() -> Bool {
        let requestedSequence = appState.captureViewerSearchRequestSequence
        guard requestedSequence != lastAppliedExternalSearchRequestSequence else {
            return false
        }
        lastAppliedExternalSearchRequestSequence = requestedSequence
        searchInputText = appState.captureViewerSearchQuery
        applyCaptureViewerSearchQuery()
        focusedControl = .searchInput
        return true
    }

    @discardableResult
    private func applyExternalSelectionRequestIfNeeded() -> Bool {
        let requestedSequence = appState.captureViewerSelectionRequestSequence
        guard requestedSequence != lastAppliedExternalSelectionRequestSequence else {
            return false
        }
        lastAppliedExternalSelectionRequestSequence = requestedSequence
        guard
            let requestedRecordID = appState.captureViewerSelectionRequestRecordID,
            let requestedCapturedAt = appState.captureViewerSelectionRequestCapturedAt
        else {
            return false
        }

        pendingExternalSelectionRecordID = requestedRecordID
        resetFiltersForExternalSelection()

        let targetDate = Self.captureViewerDayCalendar.startOfDay(for: requestedCapturedAt)
        let isTargetDateInCurrentRange =
            targetDate >= captureViewerStartDate && targetDate <= captureViewerEndDate
        if isTargetDateInCurrentRange {
            loadCaptureViewerArtifacts()
        } else {
            setCaptureViewerDateRange(startDate: targetDate, endDate: targetDate, preset: nil)
        }
        focusCaptureList()
        return true
    }

    private func resetFiltersForExternalSelection() {
        selectedApplicationFilter = .all
        selectedCaptureTriggerFilter = .all
        searchInputText = ""
        confirmedSearchQueryText = ""
    }

    private func focusCaptureList() {
        Task { @MainActor in
            focusedControl = .captureList
        }
    }

    @ViewBuilder
    private func captureViewerManualIndicatorView(for captureTrigger: CaptureTrigger) -> some View {
        if captureTrigger.isUserInitiated {
            Text("viewer.value.trigger_manual")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(Color.orange.opacity(0.16))
                )
        }
    }

    @ViewBuilder
    private func captureViewerImagePreview(artifact: CaptureRecordArtifact) -> some View {
        if artifact.imageLinkState == .notCaptured {
            Text("viewer.message.image_not_captured")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if artifact.imageLinkState == .missingOrExpired {
            Text("viewer.message.image_missing_or_expired")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let imageFileURL = artifact.imageFileURL {
            AsyncImage(url: imageFileURL) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: 160, alignment: .center)
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 360, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contextMenu {
                            Button("viewer.menu.open_image") {
                                appState.openCaptureViewerFile(imageFileURL)
                            }
                            Button("viewer.menu.reveal_image") {
                                appState.revealCaptureViewerFile(imageFileURL)
                            }
                            Button("viewer.menu.delete_image", role: .destructive) {
                                trashCaptureViewerImage(artifact: artifact, imageFileURL: imageFileURL)
                            }
                        }
                case .failure:
                    Text("viewer.message.image_load_failed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                @unknown default:
                    Text("viewer.message.image_load_failed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("viewer.message.image_load_failed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func captureViewerTextRow(
        iconName: String,
        accessibilityLabel: String,
        value: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .offset(y: 2)
                .accessibilityLabel(accessibilityLabel)
            resolveDisplayText(value)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func captureViewerLinkRow<MenuContent: View>(
        iconName: String,
        accessibilityLabel: String,
        value: String,
        action: @escaping () -> Void,
        @ViewBuilder menuContent: () -> MenuContent
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .offset(y: 2)
                .accessibilityLabel(accessibilityLabel)
            Button(action: action) {
                resolveDisplayText(value)
                    .underline()
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .contextMenu(menuItems: menuContent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trashCaptureViewerImage(artifact: CaptureRecordArtifact, imageFileURL: URL) {
        let preferredRecordID = selectedCaptureArtifactID == artifact.id ? artifact.id : selectedCaptureArtifactID
        Task {
            let didTrashImage = await appState.trashCaptureViewerImageFile(imageFileURL)
            guard didTrashImage else {
                return
            }
            pendingSelectionAfterReloadRecordID = preferredRecordID
            loadCaptureViewerArtifacts()
        }
    }

    private func trashCaptureViewerRecord(_ artifact: CaptureRecordArtifact) {
        let preferredRecordID = resolvePreferredRecordIDAfterDeletingArtifact(artifact)
        Task {
            let didTrashRecord = await appState.trashCaptureViewerRecord(artifact)
            guard didTrashRecord else {
                return
            }
            pendingSelectionAfterReloadRecordID = preferredRecordID
            loadCaptureViewerArtifacts()
        }
    }

    private func resolvePreferredRecordIDAfterDeletingArtifact(_ artifact: CaptureRecordArtifact) -> UUID? {
        guard let deletedRecordIndex = displayedArtifacts.firstIndex(where: { displayedArtifact in
            displayedArtifact.id == artifact.id
        }) else {
            return selectedCaptureArtifactID
        }

        if selectedCaptureArtifactID != artifact.id {
            return selectedCaptureArtifactID
        }
        if deletedRecordIndex + 1 < displayedArtifacts.count {
            return displayedArtifacts[deletedRecordIndex + 1].id
        }
        if deletedRecordIndex > 0 {
            return displayedArtifacts[deletedRecordIndex - 1].id
        }
        return nil
    }

    private func resolveCaptureImageLinkStateText(_ imageLinkState: CaptureImageLinkState) -> String {
        switch imageLinkState {
        case .available:
            L10n.string("viewer.value.image_available")
        case .notCaptured:
            L10n.string("viewer.value.image_not_captured")
        case .missingOrExpired:
            L10n.string("viewer.value.image_missing_or_expired")
        }
    }

    private func resolveCaptureImageLinkStateIconName(_ imageLinkState: CaptureImageLinkState) -> String {
        switch imageLinkState {
        case .available:
            "photo"
        case .notCaptured:
            "photo.slash"
        case .missingOrExpired:
            "exclamationmark.triangle"
        }
    }

    private func resolveCaptureImageLinkStateColor(_ imageLinkState: CaptureImageLinkState) -> Color {
        switch imageLinkState {
        case .available:
            .green
        case .notCaptured:
            .secondary
        case .missingOrExpired:
            .orange
        }
    }

    private func resolveCaptureCommentText(_ comment: String?) -> String {
        guard let comment else {
            return L10n.string("viewer.value.no_comment")
        }
        if comment.isEmpty {
            return L10n.string("viewer.value.empty_comment")
        }
        return comment
    }

    private static let captureViewerTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let captureViewerDayCalendar: Calendar = .autoupdatingCurrent

    private static let captureViewerDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let captureViewerSectionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "yyyy/MM/dd (EEE)"
        return formatter
    }()

    private static let captureViewerIndexDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "MM/dd"
        return formatter
    }()

    private static let captureViewerIndexLabelHeight: CGFloat = 12
    private static let captureViewerIndexLabelVerticalMargin: CGFloat = 3
    private static let captureViewerIndexBackgroundCornerRadius: CGFloat = 8

    // MARK: - Application Launch

    private func resolveApplicationURL(for applicationName: String, bundlePath: String? = nil) -> URL? {
        if let bundlePath, FileManager.default.fileExists(atPath: bundlePath) {
            return URL(fileURLWithPath: bundlePath)
        }
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == applicationName }),
           let url = running.bundleURL
        {
            return url
        }
        let searchPaths = [
            "/Applications/\(applicationName).app",
            "/System/Applications/\(applicationName).app",
            "/Applications/Utilities/\(applicationName).app",
            "/System/Applications/Utilities/\(applicationName).app",
        ]
        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private func launchApplication(record: CaptureRecord) {
        guard let appURL = resolveApplicationURL(
            for: record.applicationName,
            bundlePath: record.applicationBundlePath
        ) else { return }
        NSWorkspace.shared.open(appURL)
    }

    private func revealApplicationInFinder(record: CaptureRecord) {
        guard let appURL = resolveApplicationURL(
            for: record.applicationName,
            bundlePath: record.applicationBundlePath
        ) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }

    // MARK: - Index Bar

    @ViewBuilder
    private func captureViewerIndexBar(
        sections: [CaptureViewerListSection],
        scrollProxy: ScrollViewProxy
    ) -> some View {
        if sections.count > 1 {
            GeometryReader { geometry in
                let labelPlacements = resolveIndexLabelPlacements(for: sections)
                ZStack {
                    RoundedRectangle(cornerRadius: Self.captureViewerIndexBackgroundCornerRadius)
                        .fill(Color.gray.opacity(isIndexBarActive ? 0.22 : 0))

                    ForEach(labelPlacements) { placement in
                        Text(placement.text)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .minimumScaleFactor(0.55)
                            .lineLimit(1)
                            .frame(
                                width: geometry.size.width,
                                height: Self.captureViewerIndexLabelHeight
                            )
                            .position(
                                x: geometry.size.width / 2,
                                y: resolveIndexLabelCenterY(
                                    positionRatio: placement.positionRatio,
                                    barHeight: geometry.size.height
                                )
                            )
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onHover { isHovered in
                    isIndexBarHovered = isHovered
                }
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            isIndexBarDragging = true
                            scrollCaptureListFromIndex(
                                locationY: value.location.y,
                                barHeight: geometry.size.height,
                                sections: sections,
                                scrollProxy: scrollProxy
                            )
                        }
                        .onEnded { _ in
                            isIndexBarDragging = false
                            lastIndexScrolledArtifactID = nil
                        }
                )
            }
            .frame(width: isSingleDaySelection ? 28 : 40)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
            .padding(.trailing, 14)
            .animation(.easeInOut(duration: 0.12), value: isIndexBarActive)
        }
    }

    private func scrollCaptureListFromIndex(
        locationY: CGFloat,
        barHeight: CGFloat,
        sections: [CaptureViewerListSection],
        scrollProxy: ScrollViewProxy
    ) {
        guard
            let targetDate = resolveIndexTargetDate(
                locationY: locationY,
                barHeight: barHeight
            ),
            let targetArtifactID = resolveIndexArtifactID(
                for: targetDate,
                sections: sections
            )
        else {
            return
        }
        guard lastIndexScrolledArtifactID != targetArtifactID else {
            return
        }
        lastIndexScrolledArtifactID = targetArtifactID
        selectedCaptureArtifactID = targetArtifactID
        scrollProxy.scrollTo(targetArtifactID, anchor: .center)
    }

    private func resolveIndexTargetDate(
        locationY: CGFloat,
        barHeight: CGFloat
    ) -> Date? {
        guard
            let normalizedProgress = resolveNormalizedIndexProgress(
                locationY: locationY,
                barHeight: barHeight
            ),
            let indexRangeDates = resolveIndexRangeDates()
        else {
            return nil
        }

        let topSeconds = indexRangeDates.topDate.timeIntervalSinceReferenceDate
        let bottomSeconds = indexRangeDates.bottomDate.timeIntervalSinceReferenceDate
        let interpolatedSeconds = topSeconds + ((bottomSeconds - topSeconds) * normalizedProgress)
        return Date(timeIntervalSinceReferenceDate: interpolatedSeconds)
    }

    private func resolveNormalizedIndexProgress(
        locationY: CGFloat,
        barHeight: CGFloat
    ) -> Double? {
        guard let trackMetrics = resolveIndexTrackMetrics(barHeight: barHeight) else {
            return nil
        }
        guard trackMetrics.travelHeight > 0 else {
            return 0
        }

        let rawProgress = (locationY - trackMetrics.minimumCenterY) / trackMetrics.travelHeight
        return Double(min(max(rawProgress, 0), 1))
    }

    private func resolveIndexTrackMetrics(barHeight: CGFloat) -> CaptureViewerIndexTrackMetrics? {
        guard barHeight > 0 else {
            return nil
        }

        let verticalInset = Self.captureViewerIndexLabelVerticalMargin
        let minimumCenterY = verticalInset + (Self.captureViewerIndexLabelHeight / 2)
        let travelHeight = max(
            barHeight - Self.captureViewerIndexLabelHeight - (verticalInset * 2),
            0
        )
        return CaptureViewerIndexTrackMetrics(
            minimumCenterY: minimumCenterY,
            travelHeight: travelHeight
        )
    }

    private func resolveIndexRangeDates() -> (
        rangeStartDate: Date,
        rangeEndExclusiveDate: Date,
        topDate: Date,
        bottomDate: Date
    )? {
        let rangeStartDate = Self.captureViewerDayCalendar.startOfDay(for: captureViewerStartDate)
        guard let rangeEndExclusiveDate = Self.captureViewerDayCalendar.date(
            byAdding: .day,
            value: 1,
            to: Self.captureViewerDayCalendar.startOfDay(for: captureViewerEndDate)
        ) else {
            return nil
        }

        let topDate: Date
        let bottomDate: Date
        switch selectedTimeSortOrder {
        case .ascending:
            topDate = rangeStartDate
            bottomDate = rangeEndExclusiveDate
        case .descending:
            topDate = rangeEndExclusiveDate
            bottomDate = rangeStartDate
        }

        return (rangeStartDate, rangeEndExclusiveDate, topDate, bottomDate)
    }

    private func resolveIndexLabelPlacements(
        for sections: [CaptureViewerListSection]
    ) -> [CaptureViewerIndexLabelPlacement] {
        guard let indexRangeDates = resolveIndexRangeDates() else {
            return []
        }

        let totalRangeSeconds = indexRangeDates.rangeEndExclusiveDate.timeIntervalSince(
            indexRangeDates.rangeStartDate
        )
        guard totalRangeSeconds > 0 else {
            return []
        }

        return sections.map { section in
            let distanceFromTopSeconds: TimeInterval
            switch selectedTimeSortOrder {
            case .ascending:
                distanceFromTopSeconds = section.targetDate.timeIntervalSince(
                    indexRangeDates.rangeStartDate
                )
            case .descending:
                distanceFromTopSeconds = indexRangeDates.rangeEndExclusiveDate.timeIntervalSince(
                    section.targetDate
                )
            }

            let positionRatio = min(max(distanceFromTopSeconds / totalRangeSeconds, 0), 1)
            return CaptureViewerIndexLabelPlacement(
                id: section.id,
                text: section.indexLabel,
                positionRatio: positionRatio
            )
        }
    }

    private func resolveIndexLabelCenterY(
        positionRatio: CGFloat,
        barHeight: CGFloat
    ) -> CGFloat {
        guard let trackMetrics = resolveIndexTrackMetrics(barHeight: barHeight) else {
            return Self.captureViewerIndexLabelHeight / 2
        }
        let clampedPositionRatio = min(max(positionRatio, 0), 1)
        return trackMetrics.minimumCenterY
            + (trackMetrics.travelHeight * clampedPositionRatio)
    }

    private func resolveIndexArtifactID(
        for targetDate: Date,
        sections: [CaptureViewerListSection]
    ) -> UUID? {
        let sectionRanges = resolveIndexSectionRanges(for: sections)
        guard sectionRanges.isEmpty == false else {
            return nil
        }

        if let containingSectionRange = sectionRanges.first(where: { sectionRange in
            targetDate >= sectionRange.startDate && targetDate < sectionRange.endDateExclusive
        }) {
            return resolveArtifactID(
                closestTo: targetDate,
                artifacts: containingSectionRange.section.artifacts
            )
        }

        guard let fallbackSectionRange = resolveFallbackSectionRange(
            for: targetDate,
            sectionRanges: sectionRanges
        ) else {
            return nil
        }
        return resolveArtifactID(
            closestTo: targetDate,
            artifacts: fallbackSectionRange.section.artifacts
        )
    }

    private func resolveIndexSectionRanges(
        for sections: [CaptureViewerListSection]
    ) -> [CaptureViewerIndexSectionRange] {
        let calendar = Self.captureViewerDayCalendar
        return sections.compactMap { section in
            let endDateExclusive: Date?
            switch section.kind {
            case .hour:
                endDateExclusive = calendar.date(byAdding: .hour, value: 1, to: section.targetDate)
            case .day:
                endDateExclusive = calendar.date(byAdding: .day, value: 1, to: section.targetDate)
            }

            guard let endDateExclusive else {
                return nil
            }
            return CaptureViewerIndexSectionRange(
                section: section,
                startDate: section.targetDate,
                endDateExclusive: endDateExclusive
            )
        }
    }

    private func resolveFallbackSectionRange(
        for targetDate: Date,
        sectionRanges: [CaptureViewerIndexSectionRange]
    ) -> CaptureViewerIndexSectionRange? {
        guard sectionRanges.isEmpty == false else {
            return nil
        }

        let preferredIndices: [Int]
        switch selectedTimeSortOrder {
        case .ascending:
            let insertionIndex = sectionRanges.firstIndex(where: { $0.startDate > targetDate })
                ?? sectionRanges.count
            preferredIndices = resolveFallbackSectionIndices(
                preferredIndex: insertionIndex < sectionRanges.count ? insertionIndex : sectionRanges.count - 1,
                secondaryIndex: insertionIndex > 0 ? insertionIndex - 1 : nil,
                count: sectionRanges.count
            )
        case .descending:
            let insertionIndex = sectionRanges.firstIndex(where: { $0.startDate < targetDate })
                ?? sectionRanges.count
            let preferredIndex: Int
            if insertionIndex == 0 {
                preferredIndex = 0
            } else if insertionIndex >= sectionRanges.count {
                preferredIndex = sectionRanges.count - 1
            } else {
                preferredIndex = insertionIndex - 1
            }
            preferredIndices = resolveFallbackSectionIndices(
                preferredIndex: preferredIndex,
                secondaryIndex: insertionIndex < sectionRanges.count ? insertionIndex : nil,
                count: sectionRanges.count
            )
        }

        for sectionIndex in preferredIndices {
            let sectionRange = sectionRanges[sectionIndex]
            if sectionRange.section.artifacts.isEmpty == false {
                return sectionRange
            }
        }
        return nil
    }

    private func resolveFallbackSectionIndices(
        preferredIndex: Int,
        secondaryIndex: Int?,
        count: Int
    ) -> [Int] {
        guard count > 0 else {
            return []
        }

        var indices: [Int] = []
        let clampedPreferredIndex = min(max(preferredIndex, 0), count - 1)
        indices.append(clampedPreferredIndex)

        if let secondaryIndex {
            let clampedSecondaryIndex = min(max(secondaryIndex, 0), count - 1)
            if indices.contains(clampedSecondaryIndex) == false {
                indices.append(clampedSecondaryIndex)
            }
        }
        return indices
    }

    private func resolveArtifactID(
        closestTo targetDate: Date,
        artifacts: [CaptureRecordArtifact]
    ) -> UUID? {
        guard let firstArtifact = artifacts.first else {
            return nil
        }

        var nearestArtifact = firstArtifact
        var smallestTimeDistance = abs(firstArtifact.record.capturedAt.timeIntervalSince(targetDate))
        for artifact in artifacts.dropFirst() {
            let timeDistance = abs(artifact.record.capturedAt.timeIntervalSince(targetDate))
            if timeDistance < smallestTimeDistance {
                nearestArtifact = artifact
                smallestTimeDistance = timeDistance
            }
        }
        return nearestArtifact.id
    }

    // MARK: - List Section

    private func buildListSections(from artifacts: [CaptureRecordArtifact]) -> [CaptureViewerListSection] {
        let calendar = Self.captureViewerDayCalendar

        if isSingleDaySelection {
            let groupedArtifacts = Dictionary(grouping: artifacts) { artifact in
                calendar.component(.hour, from: artifact.record.capturedAt)
            }
            let sortedHours = sortSectionKeys(Array(groupedArtifacts.keys))
            return sortedHours.compactMap { hour in
                guard
                    let sectionArtifacts = groupedArtifacts[hour],
                    let firstArtifact = sectionArtifacts.first,
                    let targetDate = calendar.date(
                        bySettingHour: hour,
                        minute: 0,
                        second: 0,
                        of: firstArtifact.record.capturedAt
                    )
                else {
                    return nil
                }

                return CaptureViewerListSection(
                    kind: .hour(hour),
                    label: L10n.format("viewer.section.hour_format", hour),
                    indexLabel: String(format: "%02d", hour),
                    targetDate: targetDate,
                    scrollTargetID: firstArtifact.id,
                    artifacts: sectionArtifacts
                )
            }
        }

        let groupedArtifacts = Dictionary(grouping: artifacts) { artifact in
            calendar.startOfDay(for: artifact.record.capturedAt)
        }
        let sortedDates = sortSectionKeys(Array(groupedArtifacts.keys))
        return sortedDates.compactMap { date in
            guard
                let sectionArtifacts = groupedArtifacts[date],
                let firstArtifact = sectionArtifacts.first
            else {
                return nil
            }

            return CaptureViewerListSection(
                kind: .day(date),
                label: Self.captureViewerSectionDateFormatter.string(from: date),
                indexLabel: Self.captureViewerIndexDateFormatter.string(from: date),
                targetDate: date,
                scrollTargetID: firstArtifact.id,
                artifacts: sectionArtifacts
            )
        }
    }

    private func sortSectionKeys<Key: Comparable>(_ keys: [Key]) -> [Key] {
        switch selectedTimeSortOrder {
        case .ascending:
            keys.sorted()
        case .descending:
            keys.sorted(by: >)
        }
    }

    // MARK: - App Icon

    private func resolveApplicationIcon(for applicationName: String) -> NSImage {
        if let cachedIcon = appIconCache[applicationName] {
            return cachedIcon
        }
        return NSWorkspace.shared.icon(for: .application)
    }

    private func resolveApplicationIconForMenu(for applicationName: String) -> NSImage {
        let icon = resolveApplicationIcon(for: applicationName)
        let menuIcon = icon.copy() as! NSImage
        menuIcon.size = NSSize(width: 16, height: 16)
        return menuIcon
    }

    private func buildAppIconCache(for artifacts: [CaptureRecordArtifact]) {
        var bundlePathByAppName: [String: String] = [:]
        for artifact in artifacts {
            let appName = artifact.record.applicationName
            if bundlePathByAppName[appName] == nil, let path = artifact.record.applicationBundlePath {
                bundlePathByAppName[appName] = path
            }
        }
        let uniqueAppNames = Set(artifacts.map(\.record.applicationName))
        var newCache: [String: NSImage] = [:]
        for appName in uniqueAppNames {
            if let existing = appIconCache[appName] {
                newCache[appName] = existing
            } else {
                newCache[appName] = findApplicationIcon(
                    for: appName,
                    bundlePath: bundlePathByAppName[appName]
                )
            }
        }
        appIconCache = newCache
    }

    private func findApplicationIcon(for applicationName: String, bundlePath: String? = nil) -> NSImage {
        // 1. 記録済みバンドルパスから取得
        if let bundlePath, FileManager.default.fileExists(atPath: bundlePath) {
            return NSWorkspace.shared.icon(forFile: bundlePath)
        }

        // 2. 実行中のアプリから localizedName でマッチ
        let runningApps = NSWorkspace.shared.runningApplications
        if let matchedApp = runningApps.first(where: { $0.localizedName == applicationName }),
           let bundleURL = matchedApp.bundleURL
        {
            return NSWorkspace.shared.icon(forFile: bundleURL.path)
        }

        // 3. パスベースで検索
        let searchPaths = [
            "/Applications/\(applicationName).app",
            "/System/Applications/\(applicationName).app",
            "/Applications/Utilities/\(applicationName).app",
            "/System/Applications/Utilities/\(applicationName).app",
        ]
        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) {
                return NSWorkspace.shared.icon(forFile: path)
            }
        }

        // 4. フォールバック: 汎用アプリアイコン
        return NSWorkspace.shared.icon(for: .application)
    }
}
