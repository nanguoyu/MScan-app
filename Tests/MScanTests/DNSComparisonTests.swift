import Combine
import XCTest
import MScanCore
@testable import MScan

final class DNSComparisonTests: XCTestCase {
    /// A provider may finish an external DNS transaction even after the enclosing comparison stopped.
    private actor ReplyGate {
        private var continuation: CheckedContinuation<String, Never>?
        private let entered: XCTestExpectation

        init(entered: XCTestExpectation) { self.entered = entered }

        func wait() async -> String {
            await withCheckedContinuation {
                continuation = $0
                entered.fulfill()
            }
        }

        func reply(_ value: String) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    func testTargetsNormalizeBeforeApplyingLimitAndPlanForwardAndReverseQuestions() throws {
        let targets = try DNSLookupTarget.parse(
            "Example.COM., example.com，2001:0db8::1 2001:db8::1\n1.0.0.127.in-addr.arpa.", kind: nil
        )
        XCTAssertEqual(targets.map(\.name), ["example.com", "2001:db8::1", "1.0.0.127.in-addr.arpa"])
        XCTAssertEqual(targets[0].kinds, [.a, .aaaa, .mx, .cname, .ns, .txt])
        XCTAssertEqual(targets[1].kinds, [.ptr])
        XCTAssertEqual(targets[2].kinds, [.ptr])
        let questions = targets.flatMap(\.questions)
        XCTAssertEqual(questions.count, 24)
        XCTAssertEqual(Set(questions).count, questions.count)
        XCTAssertEqual(try DNSLookupTarget.parse("host.test", kind: .mx).first?.questions.count, 3)
        XCTAssertThrowsError(try DNSLookupTarget.parse("a b c d e", kind: .a))
        XCTAssertThrowsError(try DNSLookupTarget.parse("one.example https://two.example", kind: nil))
        XCTAssertThrowsError(try DNSLookupTarget.parse("2001:db8::1", kind: .a))
    }

    @MainActor
    func testQueuedQuestionsStayWithinLimitAndCancelBeforeStarting() async {
        let lookup = DNSComparison<Int, String>(concurrency: 1)
        let entered = expectation(description: "First DNS query holds the slot")
        let unrequested = expectation(description: "A cancelled queued query never starts")
        unrequested.isInverted = true
        let gate = ReplyGate(entered: entered)
        lookup.run([0, 1]) { source in
            if source == 0 { return await gate.wait() }
            unrequested.fulfill()
            return ""
        }
        await fulfillment(of: [entered], timeout: 2)
        guard case .queued = lookup.rows[1] else { return XCTFail("No slot available for the second query") }
        lookup.cancel()
        guard case .stopped = lookup.rows[1] else { return XCTFail("Queued queries must also stop") }
        await gate.reply("late")
        await fulfillment(of: [unrequested], timeout: 0.1)
    }

    @MainActor
    func testStoppedComparisonPreservesAnswersAndIgnoresLateRepliesAfterRetry() async {
        let lookup = DNSComparison<Int, String>()
        let leak = DNSComparison<Int, String>()
        let lookupPending = expectation(description: "The second resolver is waiting")
        let leakPending = expectation(description: "An observer is waiting independently")
        let firstAnswer = expectation(description: "The first resolver has already answered")
        let staleAnswer = expectation(description: "Cancelled resolver cannot overwrite the new answer")
        staleAnswer.isInverted = true
        let oldLookup = ReplyGate(entered: lookupPending)
        let observer = ReplyGate(entered: leakPending)

        let first = lookup.$rows.first {
            if case .result("cached") = $0[0] { true } else { false }
        }.sink { _ in firstAnswer.fulfill() }
        let stale = lookup.$rows.sink {
            if case .result("obsolete") = $0[1] { staleAnswer.fulfill() }
        }
        lookup.run([0, 1]) { source in
            if source == 0 { return "cached" }
            return await oldLookup.wait()
        }
        leak.run([0]) { _ in await observer.wait() }
        await fulfillment(of: [firstAnswer, lookupPending, leakPending], timeout: 2)

        lookup.cancel()
        guard case .result("cached") = lookup.rows[0], case .stopped = lookup.rows[1] else {
            return XCTFail("Stopping should affect only the outstanding resolver")
        }
        XCTAssertTrue(leak.running)

        let refreshed = expectation(description: "The replacement comparison returned")
        let refreshedSink = lookup.$rows.first {
            if case .result("current") = $0[1] { true } else { false }
        }.sink { _ in refreshed.fulfill() }
        lookup.run([0, 1]) { _ in "current" }
        await fulfillment(of: [refreshed], timeout: 2)
        await oldLookup.reply("obsolete")
        await observer.reply("independent")
        await fulfillment(of: [staleAnswer], timeout: 0.1)
        guard case .result("current") = lookup.rows[1], case .result("independent") = leak.rows[0] else {
            return XCTFail("Replies must stay with their original comparison")
        }
        withExtendedLifetime((first, stale, refreshedSink)) {}
    }

    @MainActor
    func testSingleSourceRetryKeepsSuccessfulSiblings() async {
        actor Attempts {
            var count = [Int: Int]()
            func answer(_ source: Int) throws -> String {
                count[source, default: 0] += 1
                if source == 1, count[source] == 1 { throw URLError(.timedOut) }
                return "response"
            }
        }
        let lookup = DNSComparison<Int, String>()
        let attempts = Attempts()
        let partial = expectation(description: "One resolver failed and one succeeded")
        let recovered = expectation(description: "Failed resolver was retried")
        let partialSink = lookup.$rows.first {
            if case .result = $0[0], case .failure = $0[1] { true } else { false }
        }.sink { _ in partial.fulfill() }
        let recoveredSink = lookup.$rows.first {
            if case .result = $0[0], case .result = $0[1] { true } else { false }
        }.sink { _ in recovered.fulfill() }
        lookup.run([0, 1]) { try await attempts.answer($0) }
        await fulfillment(of: [partial], timeout: 2)
        lookup.retry(1)
        lookup.retry(1)
        await fulfillment(of: [recovered], timeout: 2)
        let count = await attempts.count
        XCTAssertEqual(count, [0: 1, 1: 2])
        withExtendedLifetime((partialSink, recoveredSink)) {}
    }
}
