//
//  TextreamService.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

class TextreamService: NSObject, ObservableObject {
    static let shared = TextreamService()
    private static let lastDocumentURLDefaultsKey = "lastDocumentURL"
    let overlayController = NotchOverlayController()
    let externalDisplayController = ExternalDisplayController()
    let browserServer = BrowserServer()
    let directorServer = DirectorServer()
    var onOverlayDismissed: (() -> Void)?
    var launchedExternally = false
    @Published var directorIsReading = false

    @Published var pages: [String] = [""]
    @Published var currentPageIndex: Int = 0
    @Published var readPages: Set<Int> = []

    // MARK: - Take Mode (CNL)
    //
    // When Take Mode is on, starting the prompter splits the script into
    // takes and plays those instead of the editor's pages. The editor's
    // pages and selected page are left untouched, so saving and editing
    // behave exactly as before.

    private struct TakeSession {
        var takes: [String]
        var index: Int
    }

    private var takeSession: TakeSession?

    var isTakeSessionActive: Bool { takeSession != nil }

    /// What the prompter steps through: takes during a take session, pages otherwise.
    private var playbackPages: [String] { takeSession?.takes ?? pages }

    private var playbackIndex: Int {
        get { takeSession?.index ?? currentPageIndex }
        set {
            if takeSession != nil {
                takeSession?.index = newValue
            } else {
                currentPageIndex = newValue
            }
        }
    }

    private var currentPlaybackText: String {
        let source = playbackPages
        guard playbackIndex < source.count else { return "" }
        return source[playbackIndex]
    }

    /// Splits one page of script into takes.
    static func splitIntoTakes(_ text: String, mode: TakeSplit) -> [String] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }

        switch mode {
        case .everyLine:
            return lines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        case .blankLine:
            var takes: [String] = []
            var block: [String] = []
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    if !block.isEmpty { takes.append(block.joined(separator: "\n")) }
                    block = []
                } else {
                    block.append(trimmed)
                }
            }
            if !block.isEmpty { takes.append(block.joined(separator: "\n")) }
            return takes
        }
    }

    /// Builds a take session from every page, starting at the first take of
    /// the editor's selected page. Clears the session when Take Mode is off.
    private func refreshTakeSession() {
        let settings = NotchSettings.shared
        guard settings.takeMode else {
            takeSession = nil
            return
        }
        var takes: [String] = []
        var startIndex = 0
        for (i, page) in pages.enumerated() {
            if i == currentPageIndex { startIndex = takes.count }
            takes.append(contentsOf: Self.splitIntoTakes(page, mode: settings.takeSplit))
        }
        guard !takes.isEmpty else {
            takeSession = nil
            return
        }
        takeSession = TakeSession(takes: takes, index: min(startIndex, takes.count - 1))
    }

    private func setTakeFlag(_ isTake: Bool) {
        overlayController.overlayContent.isTake = isTake
        externalDisplayController.overlayContent.isTake = isTake
    }

    var hasNextPage: Bool {
        let source = playbackPages
        let start = playbackIndex + 1
        guard start < source.count else { return false }
        for i in start..<source.count {
            if !source[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    var currentPageText: String {
        guard currentPageIndex < pages.count else { return "" }
        return pages[currentPageIndex]
    }

    /// Entry point for text from outside the editor (Services menu, URL scheme).
    /// Never runs as a take session.
    func readText(_ text: String) {
        takeSession = nil
        presentText(text)
    }

    /// Takes sent by CNL's video engine (textream-cnl://read?mode=takes): played
    /// one at a time as a take session, whatever the Take Mode setting, without
    /// touching the editor's pages.
    func readTakes(_ takes: [String]) {
        let clean = takes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = clean.first else { return }
        takeSession = TakeSession(takes: clean, index: 0)
        presentText(first)
    }

    private func presentText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        launchedExternally = true
        hideMainWindow()

        setTakeFlag(takeSession != nil)
        overlayController.show(text: trimmed, hasNextPage: hasNextPage) { [weak self] in
            self?.takeSession = nil
            self?.setTakeFlag(false)
            self?.externalDisplayController.dismiss()
            self?.browserServer.hideContent()
            self?.onOverlayDismissed?()
        }
        updatePageInfo()

        // Also show on external display if configured (same parsing as overlay)
        let words = splitTextIntoWords(trimmed)
        let totalCharCount = words.joined(separator: " ").count
        let paragraphBreaks = paragraphBreakWordIndices(in: trimmed)
        externalDisplayController.show(
            speechRecognizer: overlayController.speechRecognizer,
            words: words,
            totalCharCount: totalCharCount,
            paragraphBreakBeforeWordIndices: paragraphBreaks,
            hasNextPage: hasNextPage
        )

        if browserServer.isRunning {
            browserServer.showContent(
                speechRecognizer: overlayController.speechRecognizer,
                words: words,
                totalCharCount: totalCharCount,
                hasNextPage: hasNextPage
            )
        }
    }

    func readCurrentPage() {
        refreshTakeSession()
        let trimmed = currentPlaybackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            takeSession = nil
            return
        }
        if takeSession == nil {
            readPages.insert(currentPageIndex)
        }
        presentText(trimmed)
    }

    func advanceToNextPage() {
        // Skip empty pages
        let source = playbackPages
        var nextIndex = playbackIndex + 1
        while nextIndex < source.count {
            let text = source[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { break }
            nextIndex += 1
        }
        guard nextIndex < source.count else { return }
        jumpToPage(index: nextIndex)
    }

    /// Take Mode: step back one take (re-do the previous take).
    func goToPreviousPage() {
        let source = playbackPages
        var prevIndex = playbackIndex - 1
        while prevIndex >= 0 {
            let text = source[prevIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { break }
            prevIndex -= 1
        }
        guard prevIndex >= 0 else { return }
        jumpToPage(index: prevIndex)
    }

    /// Take Mode: start the current take over from the first word.
    func restartCurrentPage() {
        jumpToPage(index: playbackIndex)
    }

    func jumpToPage(index: Int) {
        let source = playbackPages
        guard index >= 0 && index < source.count else { return }
        let text = source[index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Mute mic before switching page content
        let wasListening = overlayController.speechRecognizer.isListening
        if wasListening {
            overlayController.speechRecognizer.stop()
        }

        playbackIndex = index
        overlayController.overlayContent.pageGeneration += 1
        externalDisplayController.overlayContent.pageGeneration += 1
        if takeSession == nil {
            readPages.insert(currentPageIndex)
        }

        let trimmed = currentPlaybackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Update content in-place without recreating the panel
        overlayController.updateContent(text: trimmed, hasNextPage: hasNextPage)
        updatePageInfo()

        // Also update external display content in-place
        let words = splitTextIntoWords(trimmed)
        externalDisplayController.overlayContent.words = words
        externalDisplayController.overlayContent.paragraphBreakBeforeWordIndices = paragraphBreakWordIndices(in: trimmed)
        externalDisplayController.overlayContent.totalCharCount = words.joined(separator: " ").count
        externalDisplayController.overlayContent.hasNextPage = hasNextPage

        if browserServer.isRunning {
            browserServer.updateContent(
                words: words,
                totalCharCount: words.joined(separator: " ").count,
                hasNextPage: hasNextPage
            )
        }

        // Unmute after new page content is loaded
        if wasListening {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let recognizer = self?.overlayController.speechRecognizer,
                      !recognizer.isListening,
                      !recognizer.isStarting else { return }
                recognizer.resume()
            }
        }
    }

    func updatePageInfo() {
        let source = playbackPages
        let pagePreviews = source.enumerated().map { (i, text) in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "" }
            let preview = String(trimmed.prefix(40))
            return preview + (trimmed.count > 40 ? "…" : "")
        }
        for content in [overlayController.overlayContent, externalDisplayController.overlayContent] {
            content.pageCount = source.count
            content.currentPageIndex = playbackIndex
            content.pagePreviews = pagePreviews
        }
    }

    func startAllPages() {
        readPages.removeAll()
        currentPageIndex = 0
        readCurrentPage()
    }

    func hideMainWindow() {
        DispatchQueue.main.async {
            for window in NSApp.windows where !(window is NSPanel) {
                window.makeFirstResponder(nil)
                window.orderOut(nil)
            }
        }
    }

    @Published var currentFileURL: URL?
    @Published var savedPages: [String] = [""]

    // MARK: - File Operations

    private var lastDocumentDirectoryURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: Self.lastDocumentURLDefaultsKey),
              !path.isEmpty else { return nil }

        let directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return nil }
        return directoryURL
    }

    func rememberDocumentURL(_ url: URL) {
        guard url.isFileURL else { return }
        UserDefaults.standard.set(
            url.standardizedFileURL.path,
            forKey: Self.lastDocumentURLDefaultsKey
        )
    }

    func saveFile() {
        if let url = currentFileURL {
            saveToURL(url)
        } else {
            saveFileAs()
        }
    }

    func saveFileAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "textream")!]
        panel.nameFieldStringValue = "Untitled.textream"
        panel.canCreateDirectories = true
        panel.directoryURL = currentFileURL?.deletingLastPathComponent()
            ?? lastDocumentDirectoryURL

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.saveToURL(url)
        }
    }

    private func saveToURL(_ url: URL) {
        do {
            let data = try JSONEncoder().encode(pages)
            try data.write(to: url, options: .atomic)
            currentFileURL = url
            savedPages = pages
            rememberDocumentURL(url)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to save file"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    var hasUnsavedChanges: Bool {
        pages != savedPages
    }

    func openFile() {
        guard confirmDiscardIfNeeded() else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "textream")!,
            .init(filenameExtension: "key")!,
            .init(filenameExtension: "pptx")!,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = currentFileURL?.deletingLastPathComponent()
            ?? lastDocumentDirectoryURL

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let ext = url.pathExtension.lowercased()
            if ext == "key" {
                let alert = NSAlert()
                alert.messageText = "Keynote files can't be imported directly"
                alert.informativeText = "Please export your Keynote presentation as PowerPoint (.pptx) first:\n\nIn Keynote: File → Export To → PowerPoint"
                alert.alertStyle = .informational
                alert.runModal()
            } else if ext == "pptx" {
                self?.importPresentation(from: url)
            } else {
                self?.openFileAtURL(url)
            }
        }
    }

    func importPresentation(from url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let notes = try PresentationNotesExtractor.extractNotes(from: url)
                DispatchQueue.main.async {
                    self?.pages = notes
                    self?.savedPages = notes
                    self?.currentPageIndex = 0
                    self?.readPages.removeAll()
                    self?.currentFileURL = nil
                    self?.rememberDocumentURL(url)
                }
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Import Error"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    /// Returns true if it's safe to proceed (saved, discarded, or no changes).
    /// Returns false if the user cancelled.
    func confirmDiscardIfNeeded() -> Bool {
        guard hasUnsavedChanges else { return true }

        let alert = NSAlert()
        alert.messageText = "You have unsaved changes"
        alert.informativeText = "Do you want to save your changes before opening another file?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            saveFile()
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func openFileAtURL(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let loadedPages = try JSONDecoder().decode([String].self, from: data)
            guard !loadedPages.isEmpty else { return }
            pages = loadedPages
            savedPages = loadedPages
            currentPageIndex = 0
            readPages.removeAll()
            currentFileURL = url
            rememberDocumentURL(url)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to open file"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - Browser Server

    func updateBrowserServer() {
        if NotchSettings.shared.browserServerEnabled {
            if !browserServer.isRunning {
                browserServer.start()
            }
        } else {
            browserServer.stop()
        }
    }

    // MARK: - Director Server

    func updateDirectorServer() {
        if NotchSettings.shared.directorModeEnabled {
            if !directorServer.isRunning {
                directorServer.start()
                wireDirectorCallbacks()
            }
        } else {
            directorServer.stop()
            if directorIsReading {
                overlayController.dismiss()
                directorIsReading = false
            }
        }
    }

    private func wireDirectorCallbacks() {
        directorServer.onSetText = { [weak self] text in
            self?.setTextFromDirector(text)
        }
        directorServer.onUpdateText = { [weak self] text, readCharCount in
            self?.updateTextFromDirector(text, readCharCount: readCharCount)
        }
        directorServer.onStop = { [weak self] in
            self?.stopDirectorReading()
        }
    }

    func setTextFromDirector(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Director mode is single page and never runs as a take session
        takeSession = nil
        setTakeFlag(false)
        pages = [trimmed]
        currentPageIndex = 0
        readPages.removeAll()

        // Force word tracking mode for director
        let savedMode = NotchSettings.shared.listeningMode
        NotchSettings.shared.listeningMode = .wordTracking

        directorIsReading = true

        overlayController.show(text: trimmed, hasNextPage: false) { [weak self] in
            self?.directorIsReading = false
            self?.directorServer.hideContent()
            self?.externalDisplayController.dismiss()
            self?.browserServer.hideContent()
            // Restore listening mode
            NotchSettings.shared.listeningMode = savedMode
        }

        // Feed director server with speech recognizer
        let words = splitTextIntoWords(trimmed)
        let totalCharCount = words.joined(separator: " ").count
        directorServer.showContent(
            speechRecognizer: overlayController.speechRecognizer,
            words: words,
            totalCharCount: totalCharCount
        )

        // Also show on external display & browser if configured
        let paragraphBreaks = paragraphBreakWordIndices(in: trimmed)
        externalDisplayController.show(
            speechRecognizer: overlayController.speechRecognizer,
            words: words,
            totalCharCount: totalCharCount,
            paragraphBreakBeforeWordIndices: paragraphBreaks,
            hasNextPage: false
        )
        if browserServer.isRunning {
            browserServer.showContent(
                speechRecognizer: overlayController.speechRecognizer,
                words: words,
                totalCharCount: totalCharCount,
                hasNextPage: false
            )
        }
    }

    func updateTextFromDirector(_ text: String, readCharCount: Int) {
        guard directorIsReading else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        pages = [trimmed]

        let words = splitTextIntoWords(trimmed)
        let totalCharCount = words.joined(separator: " ").count

        // Preserve only the prefix that was both recognized by the Mac and
        // locked in the director's edit snapshot. Recognition can advance
        // while an update is in flight, so trusting either count alone could
        // make newly read text unexpectedly editable or overwriteable.
        let recognizedCharCount = overlayController.speechRecognizer.recognizedCharCount
        let preservedCharCount = min(
            totalCharCount,
            min(recognizedCharCount, max(0, readCharCount))
        )

        // Update overlay content without resetting speech progress
        overlayController.overlayContent.words = words
        overlayController.overlayContent.paragraphBreakBeforeWordIndices = paragraphBreakWordIndices(in: trimmed)
        overlayController.overlayContent.totalCharCount = totalCharCount
        overlayController.overlayContent.hasNextPage = false

        // Update the speech recognizer with new full text but keep char count
        overlayController.speechRecognizer.updateText(trimmed, preservingCharCount: preservedCharCount)

        // Update director server
        directorServer.updateContent(words: words, totalCharCount: totalCharCount)

        // Update external display & browser
        externalDisplayController.overlayContent.words = words
        externalDisplayController.overlayContent.paragraphBreakBeforeWordIndices = paragraphBreakWordIndices(in: trimmed)
        externalDisplayController.overlayContent.totalCharCount = totalCharCount
        if browserServer.isRunning {
            browserServer.updateContent(
                words: words,
                totalCharCount: totalCharCount,
                hasNextPage: false
            )
        }
    }

    func stopDirectorReading() {
        guard directorIsReading else { return }
        overlayController.dismiss()
        directorIsReading = false
    }

    func updateKeepAwakeActivity(enabled: Bool) {
        overlayController.updateKeepAwakeActivity(enabled: enabled)
    }

    // macOS Services handler
    @objc func readInTextream(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pboard.string(forType: .string) else {
            error.pointee = "No text found on pasteboard" as NSString
            return
        }
        readText(text)
    }

    // URL scheme handler: textream://read?text=Hello%20World
    // CNL's video engine sends textream-cnl://read?text=…&mode=takes: its own
    // scheme, so the link can't open the stock Textream, and the script as takes
    // with a blank line between them.
    func handleURL(_ url: URL) {
        guard url.scheme == "textream" || url.scheme == "textream-cnl" else { return }

        if url.host == "read" || url.path == "/read" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let textParam = components.queryItems?.first(where: { $0.name == "text" })?.value {
                let mode = components.queryItems?.first(where: { $0.name == "mode" })?.value
                if mode == "takes" {
                    readTakes(TextreamService.splitIntoTakes(textParam, mode: .blankLine))
                } else {
                    readText(textParam)
                }
            }
        }
    }
}
