import AppKit
import Dispatch
import Foundation
import PDFKit
import XCTest
@testable import YoPDFCore

@MainActor
final class AutoSaveTests: XCTestCase {
    nonisolated(unsafe) private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
            let directory = url.deletingLastPathComponent()
            if directory.lastPathComponent.hasPrefix("YoPDFTests-") {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        temporaryFiles.removeAll()
        super.tearDown()
    }

    func testProductionDebounceIs750Milliseconds() {
        XCTAssertEqual(PDFDocumentModel(access: SecurityScopeSpy()).autoSaveDebounceNanoseconds, 750_000_000)
    }

    func testRepeatedEditsResetTheDebounceAndProduceOneWrite() async throws {
        let url = try makeFixture()
        let io = ScriptedDocumentStoreIO()
        let model = makeModel(io: io, debounce: 500_000_000)
        XCTAssertTrue(model.open(url: url))

        try addHighlight(to: model, from: 0, to: 10)
        let firstTask = try XCTUnwrap(model.autoSaveTask)
        XCTAssertEqual(model.autoSaveStatus, .pending)

        try await Task.sleep(nanoseconds: 100_000_000)
        try addHighlight(to: model, from: 12, to: 28)
        XCTAssertTrue(firstTask.isCancelled, "a new edit cancels the old debounce task")
        XCTAssertEqual(io.replacementCount, 0, "the first interval must not write")

        await assertSaved(model)
        XCTAssertEqual(io.replacementCount, 1, "both edits are committed in one automatic write")
        XCTAssertEqual(annotationCount(inFileAt: url), 2)
    }

    func testAutomaticSaveUndoAndRedoPersistAcrossReopens() async throws {
        let url = try makeFixture()
        let model = makeModel(debounce: 30_000_000)
        XCTAssertTrue(model.open(url: url))
        let liveDocument = try XCTUnwrap(model.document)

        try addHighlight(to: model)
        await assertSaved(model)
        XCTAssertTrue(model.document === liveDocument, "auto-save keeps the live PDFDocument")
        XCTAssertTrue(model.canUndoMarkup, "auto-save keeps the undo stack")
        XCTAssertEqual(annotationCount(inFileAt: url), 1)

        XCTAssertTrue(model.undoMarkup())
        XCTAssertTrue(model.canRedoMarkup)
        await assertSaved(model)
        XCTAssertEqual(annotationCount(inFileAt: url), 0, "the undone snapshot is written")
        XCTAssertTrue(model.canRedoMarkup, "the next save also preserves redo")

        XCTAssertTrue(model.redoMarkup())
        await assertSaved(model)
        XCTAssertEqual(annotationCount(inFileAt: url), 1)
        XCTAssertTrue(model.canUndoMarkup)
    }

    func testHighlightUnderlineAndNoteAreAutomaticallySaved() async throws {
        let url = try makeFixture()
        let model = makeModel(debounce: 30_000_000)
        XCTAssertTrue(model.open(url: url))

        try addHighlight(to: model, from: 0, to: 12)
        await assertSaved(model)

        try addUnderline(to: model, from: 15, to: 32)
        await assertSaved(model)

        let page = try XCTUnwrap(model.document?.page(at: 0))
        let draft = try XCTUnwrap(model.pageNoteDraft(at: CGPoint(x: 300, y: 420), on: page))
        guard case .success = model.addNote(draft, contents: "Autosaved note", paperColor: .rose) else {
            return XCTFail("the note should be accepted")
        }
        await assertSaved(model)

        let reopened = try XCTUnwrap(PDFDocument(url: url))
        let annotations = try XCTUnwrap(reopened.page(at: 0)).annotations
        XCTAssertTrue(annotations.contains(where: \.isHighlightMarkup))
        XCTAssertTrue(annotations.contains { $0.isType("Underline") })
        XCTAssertTrue(annotations.contains { $0.type == "Text" && $0.contents == "Autosaved note" })
    }

    func testAutomaticSaveConflictLeavesExternalBytesAndUndoAvailable() async throws {
        let url = try makeFixture()
        let model = makeModel(debounce: 30_000_000)
        XCTAssertTrue(model.open(url: url))
        try addHighlight(to: model)

        let externalBytes = try PDFFixtureFactory.makeParagraphData(pageCount: 3, linesPerPage: 2)
        try externalBytes.write(to: url, options: .atomic)

        let result = await waitForAutoSave(model)
        let outcome = try XCTUnwrap(result)
        guard case .conflict = outcome else {
            return XCTFail("expected a conflict, got \(outcome)")
        }
        XCTAssertEqual(try Data(contentsOf: url), externalBytes)
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertTrue(model.canUndoMarkup)
    }

    func testAutomaticSaveFailureKeepsDirtyStateAndUndoHistory() async throws {
        let url = try makeFixture()
        let io = ScriptedDocumentStoreIO()
        io.failAt = .staging
        let model = makeModel(io: io, debounce: 30_000_000)
        XCTAssertTrue(model.open(url: url))
        try addHighlight(to: model)

        let result = await waitForAutoSave(model)
        let outcome = try XCTUnwrap(result)
        guard case let .failed(.store(.stagingFailed(reason))) = outcome else {
            return XCTFail("expected an injected staging failure, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("injected"))
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertTrue(model.canUndoMarkup)
        XCTAssertEqual(annotationCount(inFileAt: url), 0)
    }

    func testSaveAsDuringDebounceWritesOnlyTheCopy() async throws {
        let original = try makeFixture(named: "original")
        let originalBytes = try Data(contentsOf: original)
        let copy = original.deletingLastPathComponent().appendingPathComponent("copy.pdf")
        temporaryFiles.append(copy)
        let model = makeModel(debounce: 300_000_000)
        XCTAssertTrue(model.open(url: original))
        try addHighlight(to: model)

        XCTAssertEqual(model.saveAs(to: copy), .saved)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        XCTAssertEqual(annotationCount(inFileAt: original), 0)
        XCTAssertEqual(annotationCount(inFileAt: copy), 1)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(annotationCount(inFileAt: original), 0, "the cancelled debounce cannot write the source")
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        XCTAssertEqual(model.fileURL, copy)
    }

    func testSaveAsPanelPausesPendingAutomaticSaveUntilDismissed() async throws {
        let url = try makeFixture()
        let io = ScriptedDocumentStoreIO()
        let model = makeModel(io: io, debounce: 30_000_000)
        XCTAssertTrue(model.open(url: url))
        try addHighlight(to: model)

        let response = model.withAutoSavePaused {
            let deadline = Date().addingTimeInterval(0.2)
            while Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            return NSApplication.ModalResponse.cancel
        }

        XCTAssertEqual(response, .cancel)
        XCTAssertEqual(io.replacementCount, 0, "the panel's nested event loop must not write the source")
        XCTAssertTrue(model.hasUnsavedChanges)
        await assertSaved(model)
        XCTAssertEqual(io.replacementCount, 1, "cancelling the panel resumes the pending debounce")
    }

    func testSaveAsPanelCancelsSerializationBeforeItCanWriteTheSource() async throws {
        let url = try makeFixture()
        let serializerGate = AutoSaveGate()
        let io = ScriptedDocumentStoreIO()
        let model = makeModel(io: io, debounce: 30_000_000)
        model.autoSaveSerializer = { snapshot in
            serializerGate.pause()
            return PDFDocumentSaveSerializer.dataRepresentationPreservingShuaGroups(in: snapshot.document)
        }
        XCTAssertTrue(model.open(url: url))
        try addHighlight(to: model)
        await waitUntilEntered(serializerGate)

        let serializerReleaser = Task.detached {
            try? await Task.sleep(nanoseconds: 80_000_000)
            serializerGate.release()
        }
        let response = model.withAutoSavePaused {
            let deadline = Date().addingTimeInterval(0.25)
            while Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            XCTAssertEqual(io.replacementCount, 0, "a cancelled serializer must not write during the panel")
            return NSApplication.ModalResponse.cancel
        }
        await serializerReleaser.value

        XCTAssertEqual(response, .cancel)
        XCTAssertEqual(io.replacementCount, 0, "the worker was cancelled before DocumentSession.save")
        XCTAssertTrue(model.hasUnsavedChanges)
        await assertSaved(model)
        XCTAssertEqual(io.replacementCount, 1, "cancelling the panel schedules a fresh checkpoint")
    }

    func testReopeningSameFileAfterInFlightAutosaveRefreshesSessionVersion() async throws {
        let url = try makeFixture()
        let gate = AutoSaveGate()
        let model = makeModel(io: AutoSaveBlockingIO(gate: gate), debounce: 30_000_000)
        XCTAssertTrue(model.open(url: url))
        try addHighlight(to: model)
        await waitUntilEntered(gate)

        let releaser = Task.detached {
            try? await Task.sleep(nanoseconds: 150_000_000)
            gate.release()
        }
        XCTAssertTrue(model.open(url: url, discardingUnsavedChanges: true))
        await releaser.value

        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(annotationCount(inFileAt: url), 1, "reopen installs the bytes committed by the old worker")
        try addUnderline(to: model, from: 20, to: 36)
        await assertSaved(model)
        XCTAssertEqual(annotationCount(inFileAt: url), 2, "the refreshed session accepts a later save")
    }

    func testSaveAsWaitsForSlowInFlightAutosaveBeforeCopying() async throws {
        let original = try makeFixture(named: "slow-original")
        let copy = original.deletingLastPathComponent().appendingPathComponent("slow-copy.pdf")
        temporaryFiles.append(copy)
        let gate = AutoSaveGate()
        let model = makeModel(io: AutoSaveBlockingIO(gate: gate), debounce: 30_000_000)
        XCTAssertTrue(model.open(url: original))
        try addHighlight(to: model)
        await waitUntilEntered(gate)

        let releaser = Task.detached {
            try? await Task.sleep(nanoseconds: 200_000_000)
            gate.release()
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let outcome = model.saveAs(to: copy)
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        await releaser.value

        XCTAssertEqual(outcome, .saved)
        print(String(format: "[autosave-slow-io] Save As waited %.3fs for the in-flight write", elapsed))
        XCTAssertGreaterThanOrEqual(elapsed, 0.15, "Save As waits for the blocked coordinated write")
        XCTAssertEqual(annotationCount(inFileAt: original), 1)
        XCTAssertEqual(annotationCount(inFileAt: copy), 1)
    }

    func testSwitchAndCloseCancelPendingDebounce() async throws {
        let first = try makeFixture(named: "first")
        let second = try makeFixture(named: "second")
        let model = makeModel(debounce: 300_000_000)
        XCTAssertTrue(model.open(url: first))
        try addHighlight(to: model)

        XCTAssertTrue(model.open(url: second, discardingUnsavedChanges: true))
        XCTAssertNil(model.autoSaveTask, "a successful switch does not restore the old document's debounce")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(annotationCount(inFileAt: first), 0)
        XCTAssertEqual(annotationCount(inFileAt: second), 0)

        try addHighlight(to: model)
        model.close()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(annotationCount(inFileAt: second), 0, "closing cancels the pending save")
    }

    func testFailedRelinkRestoresPendingAutoSaveForStillOpenDocument() async throws {
        let original = try makeFixture(named: "relink-autosave-original")
        let target = try makeFixture(named: "relink-autosave-target")
        let suiteName = "YoPDFAutoSaveRelinkTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = makeRelinkStore(defaults: defaults, original: original)
        let io = ScriptedDocumentStoreIO()
        let model = PDFDocumentModel(
            access: SecurityScopeSpy(),
            io: io,
            recentDocuments: store
        )
        model.autoSaveDebounceNanoseconds = 500_000_000
        XCTAssertTrue(model.open(url: original))
        let recentItem = try XCTUnwrap(store.items.first)

        try addHighlight(to: model)
        let canceledTask = try XCTUnwrap(model.autoSaveTask)
        XCTAssertEqual(model.autoSaveStatus, .pending)
        XCTAssertTrue(model.hasUnsavedChanges)

        XCTAssertFalse(model.open(
            url: target,
            discardingUnsavedChanges: true,
            relinking: recentItem
        ))

        XCTAssertEqual(model.lastError, .couldNotRelinkRecentDocument)
        XCTAssertEqual(model.fileURL?.standardizedFileURL, original.standardizedFileURL)
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertTrue(canceledTask.isCancelled)
        XCTAssertEqual(model.autoSaveStatus, .pending)
        XCTAssertNotNil(model.autoSaveTask, "the failed Relink schedules the original document's save again")

        await assertSaved(model)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(io.replacementCount, 1)
        XCTAssertEqual(annotationCount(inFileAt: original), 1)
        XCTAssertEqual(store.items.first?.id, recentItem.id)
        model.close()
    }

    func testFailedRelinkDuringSerializationRestoresAutoSave() async throws {
        let original = try makeFixture(named: "relink-serialization-original")
        let target = try makeFixture(named: "relink-serialization-target")
        let suiteName = "YoPDFAutoSaveRelinkSerializationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = makeRelinkStore(defaults: defaults, original: original)
        let serializerGate = AutoSaveGate()
        let io = ScriptedDocumentStoreIO()
        let model = PDFDocumentModel(
            access: SecurityScopeSpy(),
            io: io,
            recentDocuments: store
        )
        model.autoSaveDebounceNanoseconds = 30_000_000
        model.autoSaveSerializer = { snapshot in
            serializerGate.pause()
            return PDFDocumentSaveSerializer.dataRepresentationPreservingShuaGroups(in: snapshot.document)
        }
        XCTAssertTrue(model.open(url: original))
        let recentItem = try XCTUnwrap(store.items.first)
        try addHighlight(to: model)
        await waitUntilEntered(serializerGate)
        XCTAssertEqual(model.autoSaveStatus, .saving)

        let serializerReleaser = Task.detached {
            try? await Task.sleep(nanoseconds: 150_000_000)
            serializerGate.release()
        }
        XCTAssertFalse(model.open(
            url: target,
            discardingUnsavedChanges: true,
            relinking: recentItem
        ))
        await serializerReleaser.value

        XCTAssertEqual(model.lastError, .couldNotRelinkRecentDocument)
        XCTAssertEqual(model.fileURL?.standardizedFileURL, original.standardizedFileURL)
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertEqual(model.autoSaveStatus, .pending)
        XCTAssertNotNil(model.autoSaveTask)
        await assertSaved(model)
        XCTAssertEqual(io.replacementCount, 1, "only the resumed automatic save writes the source")
        XCTAssertEqual(annotationCount(inFileAt: original), 1)
        model.close()
    }

    func testFailedRelinkUsesCompletedInFlightAutoSaveOutcome() async throws {
        let original = try makeFixture(named: "relink-completed-save-original")
        let target = try makeFixture(named: "relink-completed-save-target")
        let suiteName = "YoPDFAutoSaveRelinkCompletedTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = makeRelinkStore(defaults: defaults, original: original)
        let writeGate = AutoSaveGate()
        let model = PDFDocumentModel(
            access: SecurityScopeSpy(),
            io: AutoSaveBlockingIO(gate: writeGate),
            recentDocuments: store
        )
        model.autoSaveDebounceNanoseconds = 30_000_000
        XCTAssertTrue(model.open(url: original))
        let recentItem = try XCTUnwrap(store.items.first)
        try addHighlight(to: model)
        await waitUntilEntered(writeGate)
        XCTAssertEqual(model.autoSaveStatus, .saving)

        let writeReleaser = Task.detached {
            try? await Task.sleep(nanoseconds: 150_000_000)
            writeGate.release()
        }
        XCTAssertFalse(model.open(
            url: target,
            discardingUnsavedChanges: true,
            relinking: recentItem
        ))
        await writeReleaser.value

        XCTAssertEqual(model.lastError, .couldNotRelinkRecentDocument)
        XCTAssertEqual(model.fileURL?.standardizedFileURL, original.standardizedFileURL)
        XCTAssertFalse(model.hasUnsavedChanges, "the completed save's result clears the dirty state")
        XCTAssertEqual(model.autoSaveStatus, .saved)
        XCTAssertNil(model.autoSaveTask, "a completed write does not schedule a duplicate save")
        XCTAssertEqual(annotationCount(inFileAt: original), 1)
        model.close()
    }

    func testAutomaticSerializationAndFileIODoNotBlockMainActor() async throws {
        let url = try makeFixture()
        let serializerGate = AutoSaveGate()
        let fileGate = AutoSaveGate()
        let io = AutoSaveBlockingIO(gate: fileGate)
        let model = makeModel(io: io, debounce: 30_000_000)
        model.autoSaveSerializer = { snapshot in
            serializerGate.pause()
            return PDFDocumentSaveSerializer.dataRepresentationPreservingShuaGroups(in: snapshot.document)
        }
        XCTAssertTrue(model.open(url: url))
        try addHighlight(to: model)

        let serializerReleaser = Task.detached {
            serializerGate.waitUntilEntered()
            try? await Task.sleep(nanoseconds: 200_000_000)
            serializerGate.release()
        }
        let fileReleaser = Task.detached {
            fileGate.waitUntilEntered()
            try? await Task.sleep(nanoseconds: 200_000_000)
            fileGate.release()
        }
        let heartbeat = Task { @MainActor in
            while model.autoSaveStatus != .saving {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }

            var serializationPulses = 0
            while !serializerGate.isReleased {
                serializationPulses += 1
                try? await Task.sleep(nanoseconds: 10_000_000)
            }

            var fileIOPulses = 0
            while !fileGate.isReleased {
                fileIOPulses += 1
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return (serializationPulses, fileIOPulses)
        }

        let outcome = await waitForAutoSave(model)
        XCTAssertEqual(outcome, .saved)
        let pulses = await heartbeat.value
        await serializerReleaser.value
        await fileReleaser.value
        XCTAssertGreaterThan(pulses.0, 0, "the main actor runs while snapshot serialization is paused")
        XCTAssertGreaterThan(pulses.1, 0, "the main actor runs while file I/O is paused")
    }

    func testLargePDFAutosaveKeepsMainActorResponsive() async throws {
        let url = try PDFFixtureFactory.writeTemporaryImagePDF(pixelDimension: 3_072)
        temporaryFiles.append(url)
        let fileSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        )
        XCTAssertGreaterThan(fileSize, 20 * 1_024 * 1_024, "exercise a genuinely large PDF")

        let model = makeModel(debounce: 30_000_000)
        XCTAssertTrue(model.open(url: url))
        let page = try XCTUnwrap(model.document?.page(at: 0))
        let draft = try XCTUnwrap(model.pageNoteDraft(at: CGPoint(x: 300, y: 420), on: page))

        var largestHeartbeatGap: TimeInterval = 0
        let heartbeat = Task { @MainActor in
            var previous = ProcessInfo.processInfo.systemUptime
            while true {
                if case .saved = model.autoSaveStatus { break }
                if case .failed = model.autoSaveStatus { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
                let now = ProcessInfo.processInfo.systemUptime
                largestHeartbeatGap = max(largestHeartbeatGap, now - previous)
                previous = now
            }
            return largestHeartbeatGap
        }

        guard case .success = model.addNote(draft, contents: "Large PDF autosave", paperColor: .sky) else {
            return XCTFail("the page note should be accepted")
        }
        await assertSaved(model)
        let maxGap = await heartbeat.value
        print(
            "[autosave-scale] PDF \(fileSize / 1_024 / 1_024) MB, "
                + "largest main-actor heartbeat gap \(String(format: "%.3f", maxGap))s"
        )
        XCTAssertLessThan(maxGap, 0.5, "the main actor should not stall during a large automatic save")
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(
            reopened.page(at: 0)?.annotations.filter {
                $0.type?.hasSuffix("Text") == true && $0.contents == "Large PDF autosave"
            }.count,
            1
        )
    }

    // MARK: - Helpers

    private func makeModel(
        io: any DocumentStoreIO = SystemDocumentStoreIO(),
        debounce: UInt64
    ) -> PDFDocumentModel {
        let model = PDFDocumentModel(access: SecurityScopeSpy(), io: io)
        model.autoSaveDebounceNanoseconds = debounce
        return model
    }

    private func makeFixture(named name: String = "autosave") throws -> URL {
        let url = try PDFFixtureFactory.writeTemporaryParagraphPDF(named: name)
        temporaryFiles.append(url)
        return url
    }

    private func makeRelinkStore(defaults: UserDefaults, original: URL) -> RecentDocumentsStore {
        RecentDocumentsStore(defaults: defaults) { url in
            guard url.standardizedFileURL == original.standardizedFileURL else {
                throw RecentDocumentsError.bookmarkCouldNotBeCreated
            }
            return Data([0x01, 0x02, 0x03])
        }
    }

    private func addHighlight(
        to model: PDFDocumentModel,
        from start: Int = 0,
        to end: Int = 16
    ) throws {
        let document = try XCTUnwrap(model.document)
        let page = try XCTUnwrap(document.page(at: 0))
        let length = (page.string ?? "").count
        let selection = try XCTUnwrap(
            document.selection(
                from: page,
                atCharacterIndex: start,
                to: page,
                atCharacterIndex: min(end, length)
            )
        )
        model.updateSelection(selection)
        XCTAssertNotNil(model.addHighlightToSelection())
    }

    private func addUnderline(
        to model: PDFDocumentModel,
        from start: Int,
        to end: Int
    ) throws {
        let document = try XCTUnwrap(model.document)
        let page = try XCTUnwrap(document.page(at: 0))
        let length = (page.string ?? "").count
        let selection = try XCTUnwrap(
            document.selection(
                from: page,
                atCharacterIndex: start,
                to: page,
                atCharacterIndex: min(end, length)
            )
        )
        model.updateSelection(selection)
        XCTAssertNotNil(model.addUnderlineToSelection())
    }

    private func waitForAutoSave(
        _ model: PDFDocumentModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> SaveOutcome? {
        for _ in 0..<500 {
            switch model.autoSaveStatus {
            case .saved:
                return model.lastAutoSaveOutcome
            case let .failed(outcome):
                return outcome
            case .idle, .pending, .saving:
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        XCTFail("automatic save did not finish", file: file, line: line)
        return nil
    }

    private func assertSaved(
        _ model: PDFDocumentModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let outcome = await waitForAutoSave(model, file: file, line: line)
        XCTAssertEqual(outcome, .saved, file: file, line: line)
    }

    private func waitUntilEntered(
        _ gate: AutoSaveGate,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<500 {
            if gate.isEntered { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("the automatic save did not enter its blocked I/O operation", file: file, line: line)
    }

    private func annotationCount(inFileAt url: URL) -> Int {
        PDFDocument(url: url)?.page(at: 0)?.annotations.count ?? -1
    }
}

private final class AutoSaveGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let releaseSignal = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hasEntered = false
    private var hasReleased = false
    private var hasBlocked = false

    var isEntered: Bool { lock.withLock { hasEntered } }
    var isReleased: Bool { lock.withLock { hasReleased } }

    func pause() {
        let shouldBlock = lock.withLock {
            hasEntered = true
            guard !hasBlocked, !hasReleased else { return false }
            hasBlocked = true
            return true
        }
        guard shouldBlock else { return }
        entered.signal()
        releaseSignal.wait()
    }

    func waitUntilEntered() {
        entered.wait()
    }

    func release() {
        let shouldSignal = lock.withLock {
            guard !hasReleased else { return false }
            hasReleased = true
            return true
        }
        if shouldSignal { releaseSignal.signal() }
    }
}

private final class AutoSaveBlockingIO: DocumentStoreIO, @unchecked Sendable {
    private let base = SystemDocumentStoreIO()
    private let gate: AutoSaveGate

    init(gate: AutoSaveGate) { self.gate = gate }

    func status(of url: URL) throws -> FileStatus { try base.status(of: url) }
    func version(of url: URL) throws -> DocumentVersion { try base.version(of: url) }
    func readContents(of url: URL) throws -> Data { try base.readContents(of: url) }

    func createStagingFile(nextTo url: URL, contents: Data) throws -> StagedFile {
        gate.pause()
        return try base.createStagingFile(nextTo: url, contents: contents)
    }

    func withCoordinatedWrite(at url: URL, _ body: (URL) throws -> URL) throws -> URL {
        try base.withCoordinatedWrite(at: url, body)
    }

    func replaceItem(at url: URL, with staged: StagedFile, expecting expected: DocumentVersion) throws -> URL {
        try base.replaceItem(at: url, with: staged, expecting: expected)
    }

    func moveItem(at url: URL, to destination: URL) throws {
        try base.moveItem(at: url, to: destination)
    }

    func setPermissions(_ mode: Int, at url: URL) throws {
        try base.setPermissions(mode, at: url)
    }

    func removeItemIfExists(at url: URL) throws {
        try base.removeItemIfExists(at: url)
    }
}
