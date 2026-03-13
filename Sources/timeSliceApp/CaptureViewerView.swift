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

private enum CaptureViewerFocusTarget: Hashable {
    case searchInput
    case captureList
}

private struct CaptureViewerHourSection: Identifiable {
    let hour: Int
    let label: String
    let artifacts: [CaptureRecordArtifact]

    var id: Int { hour }
}

struct CaptureViewerView: View {
    @Bindable var appState: AppState

    @AppStorage(AppSettingsKey.captureViewerTimeSortOrder)
    private var selectedTimeSortOrderRawValue = CaptureViewerTimeSortOrder.ascending.rawValue
    @State private var captureViewerDate = Date()
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
    @State private var displayedHourSections: [CaptureViewerHourSection] = []
    @FocusState private var focusedControl: CaptureViewerFocusTarget?

    private var normalizedSearchQueryText: String {
        confirmedSearchQueryText.trimmingCharacters(in: .whitespacesAndNewlines)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                DatePicker(
                    L10n.string("viewer.label.target_date"),
                    selection: $captureViewerDate,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .onChange(of: captureViewerDate) { _, _ in
                    loadCaptureViewerArtifacts()
                }

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
                    .frame(minWidth: 220, idealWidth: 300, maxWidth: 360)
                    .focused($focusedControl, equals: .searchInput)
                    .onSubmit {
                        applyCaptureViewerSearchQuery()
                    }

                Button("viewer.button.reload") {
                    loadCaptureViewerArtifacts()
                }
                .disabled(appState.isLoadingCaptureViewerArtifacts)

                if appState.isLoadingCaptureViewerArtifacts {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Text(L10n.format("viewer.label.record_count", displayedArtifacts.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        ForEach(displayedHourSections) { section in
                            Section {
                                ForEach(section.artifacts) { artifact in
                                    captureViewerRowView(artifact: artifact)
                                        .tag(artifact.id)
                                }
                            } header: {
                                Text(section.label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .id(section.hour)
                        }
                    }
                    .focused($focusedControl, equals: .captureList)
                    .listStyle(.inset)
                    .overlay(alignment: .trailing) {
                        captureViewerHourIndexBar(sections: displayedHourSections, scrollProxy: scrollProxy)
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
            let didApplyExternalSearchRequest = applyExternalSearchRequestIfNeeded()
            guard appState.captureViewerArtifacts.isEmpty else {
                synchronizeApplicationFilterIfNeeded()
                refreshDisplayedArtifacts()
                if didApplyExternalSelectionRequest == false && didApplyExternalSearchRequest == false {
                    focusCaptureList()
                }
                return
            }
            loadCaptureViewerArtifacts()
            if didApplyExternalSelectionRequest == false && didApplyExternalSearchRequest == false {
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

    private func loadCaptureViewerArtifacts() {
        let targetDate = captureViewerDate
        Task { @MainActor in
            await appState.loadCaptureViewerArtifacts(on: targetDate)
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
        displayedHourSections = buildHourSections(from: refreshedArtifacts)
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

                    captureViewerManualIndicatorView(for: artifact.record.captureTrigger)

                    Spacer()

                    Label(
                        resolveCaptureImageLinkStateText(artifact.imageLinkState),
                        systemImage: resolveCaptureImageLinkStateIconName(artifact.imageLinkState)
                    )
                    .labelStyle(.iconOnly)
                    .foregroundStyle(resolveCaptureImageLinkStateColor(artifact.imageLinkState))
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
                        fieldName: L10n.string("viewer.field.application_name"),
                        value: artifact.record.applicationName,
                        action: {
                            launchApplication(named: artifact.record.applicationName)
                        }
                    ) {
                        Button("viewer.menu.launch_application") {
                            launchApplication(named: artifact.record.applicationName)
                        }
                        Button("viewer.menu.reveal_application") {
                            revealApplicationInFinder(named: artifact.record.applicationName)
                        }
                    }
                    captureViewerTextRow(
                        fieldName: L10n.string("viewer.field.window_title"),
                        value: windowTitleText
                    )
                    if let browserURL = artifact.record.browserURL, browserURL.isEmpty == false {
                        captureViewerLinkRow(
                            fieldName: L10n.string("viewer.field.browser_url"),
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
                            fieldName: L10n.string("viewer.field.document_path"),
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
                    Text("viewer.section.comments")
                        .font(.headline)
                    captureViewerCommentTextView(comment: artifact.record.comments)
                        .font(.body)
                        .textSelection(.enabled)
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
        let currentDate = Self.captureViewerDayCalendar.startOfDay(for: captureViewerDate)
        if targetDate != currentDate {
            captureViewerDate = targetDate
        } else {
            loadCaptureViewerArtifacts()
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
    private func captureViewerCommentTextView(comment: String?) -> some View {
        if let comment, comment.isEmpty == false {
            resolveDisplayText(comment)
        } else {
            Text(resolveCaptureCommentText(comment))
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

    private func captureViewerTextRow(fieldName: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(fieldName):")
            resolveDisplayText(value)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func captureViewerLinkRow<MenuContent: View>(
        fieldName: String,
        value: String,
        action: @escaping () -> Void,
        @ViewBuilder menuContent: () -> MenuContent
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(fieldName):")
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

    // MARK: - Application Launch

    private func resolveApplicationURL(for applicationName: String) -> URL? {
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

    private func launchApplication(named applicationName: String) {
        guard let appURL = resolveApplicationURL(for: applicationName) else { return }
        NSWorkspace.shared.open(appURL)
    }

    private func revealApplicationInFinder(named applicationName: String) {
        guard let appURL = resolveApplicationURL(for: applicationName) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }

    // MARK: - Hour Index Bar

    @ViewBuilder
    private func captureViewerHourIndexBar(
        sections: [CaptureViewerHourSection],
        scrollProxy: ScrollViewProxy
    ) -> some View {
        if sections.count > 1 {
            VStack(spacing: 1) {
                ForEach(sections) { section in
                    Text(String(format: "%02d", section.hour))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation {
                                scrollProxy.scrollTo(section.hour, anchor: .top)
                            }
                        }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
            .background(.clear)
            .padding(.trailing, 14)
        }
    }

    // MARK: - Hour Section

    private func buildHourSections(from artifacts: [CaptureRecordArtifact]) -> [CaptureViewerHourSection] {
        let calendar = Self.captureViewerDayCalendar
        let grouped = Dictionary(grouping: artifacts) { artifact in
            calendar.component(.hour, from: artifact.record.capturedAt)
        }
        let sortedHours: [Int]
        switch selectedTimeSortOrder {
        case .ascending:
            sortedHours = grouped.keys.sorted()
        case .descending:
            sortedHours = grouped.keys.sorted(by: >)
        }
        return sortedHours.map { hour in
            CaptureViewerHourSection(
                hour: hour,
                label: L10n.format("viewer.section.hour_format", hour),
                artifacts: grouped[hour] ?? []
            )
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
        let uniqueAppNames = Set(artifacts.map(\.record.applicationName))
        var newCache: [String: NSImage] = [:]
        for appName in uniqueAppNames {
            if let existing = appIconCache[appName] {
                newCache[appName] = existing
            } else {
                newCache[appName] = findApplicationIcon(for: appName)
            }
        }
        appIconCache = newCache
    }

    private func findApplicationIcon(for applicationName: String) -> NSImage {
        // 1. 実行中のアプリから localizedName でマッチ
        let runningApps = NSWorkspace.shared.runningApplications
        if let matchedApp = runningApps.first(where: { $0.localizedName == applicationName }),
           let bundleURL = matchedApp.bundleURL
        {
            return NSWorkspace.shared.icon(forFile: bundleURL.path)
        }

        // 2. パスベースで検索
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

        // 3. フォールバック: 汎用アプリアイコン
        return NSWorkspace.shared.icon(for: .application)
    }
}
