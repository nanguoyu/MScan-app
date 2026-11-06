import MScanCore
import SwiftUI
import WebKit

struct ICEObservation: Hashable {
    let kind: String
    let address: String?
    let port: UInt16?
    let transport: String
    let related: String?

    struct Event: Decodable {
        let candidate: String
        let address: String?
        let port: UInt16?
        let type: String?
        let protocolName: String?
        let relatedAddress: String?
    }

    init?(_ event: Event) {
        let fields = event.candidate.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count >= 8, fields[0].hasPrefix("candidate:"), fields[6] == "typ" else { return nil }
        kind = event.type ?? fields[7]
        let raw = [event.address, fields[4]].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        address = raw.isEmpty ? nil : DiagnosticIP(raw)?.text ?? raw
        port = event.port ?? UInt16(fields[5])
        transport = (event.protocolName ?? fields[2]).uppercased()
        if let value = event.relatedAddress, !value.isEmpty { related = value }
        else if let index = fields.firstIndex(of: "raddr"), index + 1 < fields.count { related = fields[index + 1] }
        else { related = nil }
    }

    var family: String {
        guard let address else { return leakText("rtc.hidden") }
        if let ip = DiagnosticIP(address) { return ip.isIPv6 ? "IPv6" : "IPv4" }
        return address.lowercased().hasSuffix(".local") ? "mDNS" : leakText("rtc.hostname")
    }

    var typeLabel: String {
        switch kind {
        case "host": return leakText("rtc.host")
        case "srflx": return leakText("rtc.srflx")
        case "prflx": return leakText("rtc.prflx")
        case "relay": return leakText("rtc.relay")
        default: return kind
        }
    }

    func agrees(with expected: DiagnosticIP?) -> Bool? {
        guard kind == "srflx", let expected, let address, let ip = DiagnosticIP(address), ip.isIPv6 == expected.isIPv6 else { return nil }
        return ip == expected
    }
}

private func rtcText(_ key: String) -> String { L10n.text(key, table: "RTCPerspectives") }

enum ICESource: CaseIterable, Hashable {
    case local, cloudflare, google, twilio

    var title: String {
        switch self {
        case .local: return rtcText("source.local")
        case .cloudflare: return "Cloudflare"
        case .google: return "Google"
        case .twilio: return "Twilio"
        }
    }

    var endpoint: String? {
        switch self {
        case .local: return nil
        case .cloudflare: return "stun.cloudflare.com:3478"
        case .google: return "stun.l.google.com:19302"
        case .twilio: return "global.stun.twilio.com:3478"
        }
    }
}

struct ICECollection {
    enum Phase: String {
        case idle, gathering, noCandidates, complete, noMapping, timeout, unavailable, stopped
    }

    var phase: Phase
    var candidates: [ICEObservation] = []
    var errors: [Int] = []

    init(_ phase: Phase) { self.phase = phase }

    init(source: ICESource, report: WebRTCProbe.Report) {
        var seen = Set<ICEObservation>()
        let gathered = report.events.compactMap(ICEObservation.init).filter { seen.insert($0).inserted }
        // Host candidates are WebKit observations, not addresses reported by a STUN server.
        candidates = source == .local ? gathered : gathered.filter { $0.kind != "host" }
        errors = Array(Set(report.errors)).sorted()
        switch report.status {
        case "complete" where gathered.isEmpty: phase = .noCandidates
        case "complete" where source != .local && !candidates.contains(where: { $0.kind == "srflx" }): phase = .noMapping
        case "complete": phase = .complete
        case "timeout": phase = .timeout
        case "cancelled": phase = .stopped
        default: phase = .unavailable
        }
    }
}

@MainActor
final class WebRTCProbe: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var results: [ICESource: ICECollection] = [:]
    @Published private(set) var view: WKWebView?
    var running: Bool { view != nil }
    private var watchdog: Task<Void, Never>?

    func run(sources: Set<ICESource>) {
        guard !running, !sources.isEmpty else { return }
        results = Dictionary(uniqueKeysWithValues: sources.map { ($0, ICECollection(.gathering)) })
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        view = web
        web.navigationDelegate = self
        // A secure origin for the ICE API, without loading any remote page or media.
        web.loadHTMLString("<!doctype html><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'\"><title>MScan</title>",
                           baseURL: URL(string: "https://mscan.invalid/"))
        watchdog = Task { [weak self, weak web] in
            try? await Task.sleep(for: .seconds(14))
            guard !Task.isCancelled, let self, let web, view === web else { return }
            finishPending(.timeout)
        }
    }

    func cancel() { if running { finishPending(.stopped) } }

    func clear(_ source: ICESource) {
        if !running { results.removeValue(forKey: source) }
    }

    private func finishPending(_ phase: ICECollection.Phase) {
        for (source, row) in results where row.phase == .gathering {
            results[source] = ICECollection(phase)
        }
        closePage()
    }

    private func closePage() {
        watchdog?.cancel()
        watchdog = nil
        if let web = view {
            web.navigationDelegate = nil
            web.evaluateJavaScript("window.mscanPeers?.forEach(closePeer => closePeer())")
            web.stopLoading()
        }
        view = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard view === webView else { return }
        for source in ICESource.allCases where results[source]?.phase == .gathering {
            Task { await collect(source, in: webView) }
        }
    }

    private func collect(_ source: ICESource, in web: WKWebView) async {
        guard view === web else { return }
        let result: ICECollection
        do {
            // Each invocation constructs its own peer with exactly one destination (or none).
            let stun = source.endpoint.map { "stun:" + $0 } ?? ""
            let raw = try await web.callAsyncJavaScript(Self.script, arguments: ["stunURL": stun],
                                                        in: nil, contentWorld: .page)
            let report = try JSONDecoder().decode(Report.self, from: Data((raw as? String ?? "").utf8))
            result = ICECollection(source: source, report: report)
        } catch {
            result = ICECollection(.unavailable)
        }
        guard view === web, results[source]?.phase == .gathering else { return }
        results[source] = result
        if !results.values.contains(where: { $0.phase == .gathering }) { closePage() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if view === webView { finishPending(.unavailable) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if view === webView { finishPending(.unavailable) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if view === webView { finishPending(.unavailable) }
    }

    struct Report: Decodable {
        let status: String
        let events: [ICEObservation.Event]
        let errors: [Int]
    }

    static let script = #"""
    const events = [], errors = [];
    if (!window.isSecureContext || typeof RTCPeerConnection !== "function")
      return JSON.stringify({status:"unavailable", events, errors});
    const peer = new RTCPeerConnection({iceServers: stunURL ? [{urls:stunURL}] : []});
    return await new Promise(resolve => {
      let done = false;
      const finish = status => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        peer.onicecandidate = null;
        peer.onicegatheringstatechange = null;
        peer.onicecandidateerror = null;
        peer.close();
        window.mscanPeers.delete(cancel);
        resolve(JSON.stringify({status, events, errors}));
      };
      const timer = setTimeout(() => finish("timeout"), 9000);
      const cancel = () => finish("cancelled");
      (window.mscanPeers ??= new Set()).add(cancel);
      peer.onicecandidate = ({candidate:c}) => {
        if (!c) { finish("complete"); return; }
        if (c.candidate && events.length < 100) events.push({
          candidate:c.candidate, address:c.address, port:c.port, type:c.type,
          protocolName:c.protocol, relatedAddress:c.relatedAddress
        });
      };
      peer.onicecandidateerror = e => { if (Number.isInteger(e.errorCode) && errors.length < 20) errors.push(e.errorCode); };
      peer.onicegatheringstatechange = () => {
        if (peer.iceGatheringState === "complete") finish("complete");
      };
      try {
        peer.createDataChannel("mscan");
        peer.createOffer().then(offer => peer.setLocalDescription(offer)).catch(() => finish("unavailable"));
      } catch (_) { finish("unavailable"); }
    });
    """#
}

private struct ICEPage: NSViewRepresentable {
    let page: WKWebView
    func makeNSView(context: Context) -> WKWebView { page }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct WebRTCDiagnosticsView: View {
    @Environment(\.diagnosticToolIsActive) private var active
    @StateObject private var probe = WebRTCProbe()
    @State private var selected = Set(ICESource.allCases)
    @State private var comparison = ""

    private var validReference: Bool {
        comparison.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || DiagnosticIP(comparison) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(rtcText("intro"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text(rtcText("reference.label")).font(.callout)
                TextField(rtcText("reference.placeholder"), text: $comparison)
                    .textFieldStyle(.roundedBorder).accessibilityLabel(rtcText("reference.label"))
            }
            if !validReference {
                Text(leakText("rtc.invalidReference")).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if probe.running {
                    Button(leakText("common.stop")) { probe.cancel() }.buttonStyle(.bordered)
                    ProgressView().controlSize(.small)
                } else {
                    Button(selected.count == 1 ? rtcText("run.local") :
                            L10n.format("run.sources", selected.count, table: "RTCPerspectives")) {
                        probe.run(sources: selected)
                    }
                    .buttonStyle(.borderedProminent).disabled(!active || !validReference)
                }
            }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(rtcText("heading.source")).frame(width: 166, alignment: .leading)
                    Text(rtcText("heading.candidate")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(rtcText("heading.socket")).frame(width: 100, alignment: .trailing)
                }
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.quaternary.opacity(0.45))
                ForEach(ICESource.allCases, id: \.self) { source in
                    Divider()
                    sourceRow(source)
                }
                Divider()
            }
            Link(destination: URL(string: "https://browserleaks.com/webrtc")!) {
                Label(rtcText("browser"), systemImage: "arrow.up.right")
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) {
            if let web = probe.view {
                ICEPage(page: web).id(ObjectIdentifier(web)).frame(width: 1, height: 1)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .onChange(of: active) { _, value in if !value { probe.cancel() } }
        .onDisappear { probe.cancel() }
    }

    private func sourceRow(_ source: ICESource) -> some View {
        let included = selected.contains(source)
        let result = probe.results[source] ?? ICECollection(.idle)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if source == .local {
                    Label(source.title, systemImage: "desktopcomputer")
                        .font(.callout.weight(.medium))
                } else {
                    Toggle(source.title, isOn: Binding(get: { included }, set: { include in
                        if include { selected.insert(source) } else { selected.remove(source) }
                        probe.clear(source)
                    })).toggleStyle(.checkbox).disabled(probe.running).font(.callout.weight(.medium))
                }
                Text(verbatim: source.endpoint ?? rtcText("source.noSTUN"))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(width: 166, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                if result.phase != .complete || !included {
                    Text(rtcText(included ? "phase." + result.phase.rawValue : "phase.excluded"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(result.candidates, id: \.self) { candidate in
                    candidateRow(candidate)
                }
                if !result.errors.isEmpty {
                    Text(L10n.format("rtc.serverErrors", result.errors.map(String.init).joined(separator: ", "), table: "LeakTests"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
    }

    private func candidateRow(_ item: ICEObservation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: item.address ?? leakText("rtc.hidden"))
                    .font(.callout.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: [item.transport, item.port.map { String($0) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .trailing)
            }
            Text([item.typeLabel, item.family].joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            if let related = item.related {
                Text(L10n.format("rtc.related", related, table: "LeakTests")).font(.caption)
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let agrees = item.agrees(with: DiagnosticIP(comparison)) {
                Text(leakText(agrees ? "rtc.matches" : "rtc.differs"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
