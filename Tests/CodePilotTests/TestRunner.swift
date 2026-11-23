import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case expectationFailed(String, file: String, line: Int)

    var description: String {
        switch self {
        case .expectationFailed(let msg, let file, let line):
            return "\(URL(fileURLWithPath: file).lastPathComponent):\(line) - \(msg)"
        }
    }
}

func expect(_ condition: Bool, _ message: String = "Expectation failed", file: String = #file, line: Int = #line) throws {
    if !condition {
        throw TestFailure.expectationFailed(message, file: file, line: line)
    }
}

@main
struct CodePilotTestMain {
    static func main() async {
        let suites: [(String, () async throws -> Void)] = [
            ("TaskStore.epochAndSequenceOrdering", TaskStoreTests.epochAndSequenceOrdering),
            ("TaskStore.zombieSweepPidExitedAndReused", TaskStoreTests.zombieSweepPidExitedAndReused),
            ("TaskStore.permissionDeniedFallsBackToHeartbeatTimeout", TaskStoreTests.permissionDeniedFallsBackToHeartbeatTimeout),
            ("TaskStore.clearFinishedTasks", TaskStoreTests.clearFinishedTasks),
            ("TaskStore.seqZeroCannotResetPositiveSeq", TaskStoreTests.seqZeroCannotResetPositiveSeq),
            ("TaskStore.waitingUserArchivedWhenProcessExits", TaskStoreTests.waitingUserArchivedWhenProcessExits),
            ("TaskStore.debouncedAlertCancelsWhenTaskResumesRunning", TaskStoreTests.debouncedAlertCancelsWhenTaskResumesRunning),
            ("TaskStore.primingThreeWayAndTieredReadAck", TaskStoreTests.primingThreeWayAndTieredReadAck),
            ("PowerAssertionManager.aiAutoKeepAwakeAndGracePeriod", PowerAssertionManagerTests.aiAutoKeepAwakeAndGracePeriod),
            ("PowerAssertionManager.newTaskCancelsGracePeriod", PowerAssertionManagerTests.newTaskCancelsGracePeriod),
            ("PowerAssertionManager.multipleLeasesAndMakeBeforeBreak", PowerAssertionManagerTests.multipleLeasesAndMakeBeforeBreak),
            ("PowerAssertionManager.lowBatteryCutoffAndHysteresis", PowerAssertionManagerTests.lowBatteryCutoffAndHysteresis),
            ("PowerAssertionManager.systemWakeRebuildsAssertionHandle", PowerAssertionManagerTests.systemWakeRebuildsAssertionHandle),
            ("PowerAssertionManager.policyNormalizationAndReasonTruncation", PowerAssertionManagerTests.policyNormalizationAndReasonTruncation),
            ("PowerAssertionManager.listenerReceivesOrderedVersions", PowerAssertionManagerTests.listenerReceivesOrderedVersions),
            ("Ingestion.eventEnvelopeValidation", IngestionTests.eventEnvelopeValidation),
            ("Ingestion.jsonlTailerOversizedLineDiscardsUntilNewline", IngestionTests.jsonlTailerOversizedLineDiscardsUntilNewline),
            ("Ingestion.jsonlTailerIncrementalAndPartialLine", IngestionTests.jsonlTailerIncrementalAndPartialLine),
            ("Ingestion.jsonlTailerRotationAndColdStartWindow", IngestionTests.jsonlTailerRotationAndColdStartWindow),
            ("Ingestion.unixSocketServerEndToEndAndUnsafePathGuard", IngestionTests.unixSocketServerEndToEndAndUnsafePathGuard),
            ("Ingestion.antigravityAdapterTranscriptParsing", IngestionTests.antigravityAdapterTranscriptParsing),
            ("Ingestion.deepseekHarnessAdapterProjCacheParsing", IngestionTests.deepseekHarnessAdapterProjCacheParsing),
            ("S2.deepLinkValidatorWhitelist", S2AdapterTests.deepLinkValidatorWhitelist),
            ("S2.kimiCodeAdapterParsing", S2AdapterTests.kimiCodeAdapterParsing),
            ("S2.workBuddyAdapterSQLiteQuery", S2AdapterTests.workBuddyAdapterSQLiteQuery),
            ("S2.codexAdapterRolloutParsing", S2AdapterTests.codexAdapterRolloutParsing),
            ("S2.claudeCodeAdapterParsing", S2AdapterTests.claudeCodeAdapterParsing),
            ("S3.notchStateControllerTransitions", S2AdapterTests.notchStateControllerTransitions),
            ("v0.3.titleSanitizerCleaningAndFiltering", S2AdapterTests.titleSanitizerCleaningAndFiltering),
            ("v0.3.deepSeekBalanceAndCodexQuotaParsing", S2AdapterTests.deepSeekBalanceAndCodexQuotaParsing),
            ("v0.4.titleSanitizerBoundsAndMetadata", S2AdapterTests.titleSanitizerBoundsAndMetadata),
            ("v0.4.antigravityApprovalTriggersWaitingUser", S2AdapterTests.antigravityApprovalTriggersWaitingUser),
            ("v0.4.processRuleKeepAwakeAndLowBattery", S2AdapterTests.processRuleKeepAwakeAndLowBattery),
            ("v0.4.githubUpdateParsingAndSemver", S2AdapterTests.githubUpdateParsingAndSemver),
            ("v0.4.windowMatchScorerAndLargeJSONLLine", S2AdapterTests.windowMatchScorerAndLargeJSONLLine)
        ]

        var passed = 0
        var failed = 0

        for (name, body) in suites {
            do {
                try await body()
                print("  ✅ \(name)")
                passed += 1
            } catch {
                print("  ❌ \(name): \(error)")
                failed += 1
            }
        }

        print("\nTest Summary: \(passed) passed, \(failed) failed (\(suites.count) total)")
        if failed > 0 {
            exit(1)
        }
    }
}
