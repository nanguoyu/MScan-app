import XCTest
import JavaScriptCore
import MScanCore
@testable import MScan

final class WebRTCDiagnosticsTests: XCTestCase {
    @MainActor func testGatheringScriptUsesConfiguredSTUNAndClosesPeer() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
            const window = globalThis;
            window.isSecureContext = true;
            const setTimeout = () => 1, clearTimeout = () => {};
            var server = '', closed = 0, result = null;
            class RTCPeerConnection {
                constructor(config) { server = config.iceServers[0]?.urls || ''; }
                createDataChannel() {}
                createOffer() { return Promise.resolve({type:'offer'}); }
                setLocalDescription() {
                    this.onicecandidate({candidate:{candidate:'candidate:1 1 udp 1 192.0.2.8 1234 typ srflx'}});
                    this.onicecandidate({candidate:null});
                    return Promise.resolve();
                }
                close() { closed++; }
            }
            """)
        context.evaluateScript("async function gather(stunURL) { " + WebRTCProbe.script + " };" +
                               "gather('stun:fixture.invalid').then(value => result = value);")
        let reply = try XCTUnwrap(context.objectForKeyedSubscript("result")?.toString())
        let report = try JSONDecoder().decode(WebRTCProbe.Report.self, from: Data(reply.utf8))
        XCTAssertEqual(report.status, "complete")
        XCTAssertEqual(report.events.compactMap(ICEObservation.init).first?.address, "192.0.2.8")
        XCTAssertEqual(context.objectForKeyedSubscript("server")?.toString(), "stun:fixture.invalid")
        XCTAssertEqual(context.objectForKeyedSubscript("closed")?.toInt32(), 1)
    }

    @MainActor func testSimultaneousPeersRemainIsolatedAndStopClosesOnlyPendingPeers() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
            const window = globalThis;
            window.isSecureContext = true;
            const setTimeout = () => 1, clearTimeout = () => {};
            const peers = [];
            var reports = {};
            class RTCPeerConnection {
                constructor(config) {
                    this.destinations = config.iceServers.map(server => server.urls);
                    this.closed = 0;
                    peers.push(this);
                }
                createDataChannel() {}
                createOffer() { return Promise.resolve({type:'offer'}); }
                setLocalDescription() { return Promise.resolve(); }
                close() { this.closed++; }
            }
            """)
        context.evaluateScript("async function gather(stunURL) { " + WebRTCProbe.script + " }")
        let urls = ICESource.allCases.map { $0.endpoint.map { "stun:" + $0 } ?? "" }
        let arguments = String(decoding: try JSONEncoder().encode(urls), as: UTF8.self)
        context.evaluateScript(arguments + ".forEach((url, i) => gather(url).then(r => reports[i] = JSON.parse(r)))")
        XCTAssertEqual(context.evaluateScript("peers.length")?.toInt32(), Int32(urls.count))
        XCTAssertEqual(context.evaluateScript("peers.map(p => p.destinations).join('|')")?.toString(), urls.joined(separator: "|"))

        context.evaluateScript("""
            peers[1].onicecandidate({candidate:{candidate:'candidate:1 1 UDP 1 198.51.100.8 5000 typ srflx'}});
            peers[1].onicecandidate({candidate:null});
            window.mscanPeers.forEach(closePeer => closePeer());
            """)
        XCTAssertEqual(context.evaluateScript("reports[1].status")?.toString(), "complete")
        XCTAssertEqual(context.evaluateScript("reports[1].events.length")?.toInt32(), 1)
        XCTAssertEqual(context.evaluateScript("reports[0].status")?.toString(), "cancelled")
        XCTAssertEqual(context.evaluateScript("reports[2].events.length")?.toInt32(), 0)
        XCTAssertEqual(context.evaluateScript("peers.every(peer => peer.closed === 1)")?.toBool(), true)
        XCTAssertEqual(context.evaluateScript("window.mscanPeers.size")?.toInt32(), 0)
    }

    func testRouteStatusDistinguishesLocalEvidenceFromSTUNMappingAndTimeout() {
        let host = ICEObservation.Event(candidate: "candidate:1 1 UDP 1 hidden.local 5000 typ host",
                                        address: nil, port: nil, type: nil, protocolName: nil, relatedAddress: nil)
        let report = WebRTCProbe.Report(status: "complete", events: [host, host], errors: [701, 701])
        XCTAssertEqual(ICECollection(source: .local, report: report).phase, .complete)
        let remote = ICECollection(source: .google, report: report)
        XCTAssertEqual(remote.phase, .noMapping)
        XCTAssertTrue(remote.candidates.isEmpty)
        XCTAssertEqual(remote.errors, [701])
        let mapped = ICEObservation.Event(candidate: "candidate:2 1 UDP 1 198.51.100.8 5000 typ srflx",
                                          address: nil, port: nil, type: nil, protocolName: nil, relatedAddress: nil)
        let partial = ICECollection(source: .twilio, report: .init(status: "timeout", events: [host, mapped, mapped], errors: []))
        XCTAssertEqual(partial.phase, .timeout)
        XCTAssertEqual(partial.candidates.count, 1)
        XCTAssertEqual(ICECollection(source: .google, report: .init(status: "complete", events: [], errors: [])).phase, .noCandidates)
        XCTAssertEqual(ICECollection(source: .google, report: .init(status: "unavailable", events: [], errors: [])).phase, .unavailable)
    }

    func testMaskedHostDoesNotProduceFalsePublicIPMismatch() throws {
        let event = ICEObservation.Event(candidate: "candidate:1 1 UDP 2122260223 aabbcc.local 55555 typ host",
                                         address: nil, port: nil, type: nil, protocolName: nil, relatedAddress: nil)
        let candidate = try XCTUnwrap(ICEObservation(event))
        XCTAssertEqual(candidate.address, "aabbcc.local")
        XCTAssertEqual(candidate.family, "mDNS")
        XCTAssertEqual(candidate.kind, "host")
        XCTAssertEqual(candidate.port, 55555)
        XCTAssertNil(candidate.agrees(with: DiagnosticIP("192.0.2.11")))
    }

    func testReflexiveIPEvidenceUsesTheSameAddressFamilyAndPreservesRelatedAddress() throws {
        let event = ICEObservation.Event(candidate: "candidate:2 1 udp 123 2001:db8::4 45678 typ srflx raddr fd00::10 rport 2345",
                                         address: nil, port: nil, type: nil, protocolName: nil, relatedAddress: nil)
        let candidate = try XCTUnwrap(ICEObservation(event))
        XCTAssertEqual(candidate.address, "2001:db8::4")
        XCTAssertEqual(candidate.related, "fd00::10")
        XCTAssertEqual(candidate.agrees(with: DiagnosticIP("2001:db8:0:0:0:0:0:4")), true)
        XCTAssertEqual(candidate.agrees(with: DiagnosticIP("2001:db8::5")), false)
        XCTAssertNil(candidate.agrees(with: DiagnosticIP("192.0.2.4")))
        XCTAssertNil(ICEObservation(.init(candidate: "", address: nil, port: nil, type: nil, protocolName: nil, relatedAddress: nil)))
    }
}
