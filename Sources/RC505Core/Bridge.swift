import Foundation

// The bridge: keeps a model of what the looper is doing, drives it over MIDI,
// and feeds the control page and OBS overlay over WebSocket.
//
// The looper is set up (tools/assigns.js + tools/final-plan.json) so that:
//   - it reports each track's rec/dub and play/stop as CCs (config "report")
//   - three CCs control it: step the "target track", rec/play it, stop it (config "control")

public func log(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
private func nowMs() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }

struct Config {
    var httpPort = 5055
    var midiPortMatch = "RC-505"
    var midiChannel = 1
    var gapMs = 12
    var reportRec = [1, 2, 3, 4, 5]
    var reportPlay = [6, 7, 8, 9, 10]
    var targetStep = 20
    var recPlay = 21
    var stop = 22

    init(file: URL) {
        guard let data = try? Data(contentsOf: file), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        httpPort = o["httpPort"] as? Int ?? httpPort
        midiPortMatch = o["midiPortMatch"] as? String ?? midiPortMatch
        midiChannel = o["midiChannel"] as? Int ?? midiChannel
        gapMs = o["gapMs"] as? Int ?? gapMs
        if let r = o["report"] as? [String: Any] {
            reportRec = r["rec"] as? [Int] ?? reportRec
            reportPlay = r["play"] as? [Int] ?? reportPlay
        }
        if let c = o["control"] as? [String: Any] {
            targetStep = c["targetStep"] as? Int ?? targetStep
            recPlay = c["recPlay"] as? Int ?? recPlay
            stop = c["stop"] as? Int ?? stop
        }
    }
}

/// What tools/snapshot.js read from the looper's storage: names, tempo and which tracks hold audio.
struct MemoryInfo {
    var name = ""
    var tempo: Double?
    var recAction = 0 // 0: REC -> OVERDUB, 1: REC -> PLAY
    var targetTrack = 1
    var tracks: [(hasPhrase: Bool, loopMs: Double)] = []
}

struct Track {
    var state = "empty" // empty | stop | play | rec | overdub
    var loopMs: Double = 0
    var since: Double = 0
    var isRunning: Bool { state == "rec" || state == "play" || state == "overdub" }
}

public final class Bridge {
    private let root: URL
    /// Where the memory snapshot is read from and the last known state is saved.
    private let dataDirectory: URL
    private let config: Config
    private var memories: [Int: MemoryInfo] = [:]
    private var snapshotCurrentMemory = 1
    private let server = WebServer()

    /// All model state below is touched only on `model`. MIDI sequences that need
    /// pauses run on `sender`, one at a time, hopping onto `model` to read or change state.
    private let model = DispatchQueue(label: "rc505.model")
    private let sender = DispatchQueue(label: "rc505.sender")
    private let scanner = DispatchQueue(label: "rc505.scanner")
    private var timers: [DispatchSourceTimer] = []

    private var device: MidiDevice?
    private var connected = false
    private var portName: String?
    private var memoryNumber = 1
    private var memoryName = ""
    private var tempo: Double?
    private var snapshotTempo: Double?
    private var tracks = [Track](repeating: Track(), count: 5)
    private var flags = [(rec: Bool, play: Bool)](repeating: (false, false), count: 5)
    private var targetTrack = 1
    private var recAction = 0
    private var lastAppPress = [Double](repeating: 0, count: 5)
    private var lastMemoryRequest: Double = 0
    /// The track the app just commanded, kept briefly to notice the looper acting on a different one.
    private var pending: (track: Int, stop: Bool, at: Double, previous: Track, confirmed: Bool)?

    // MIDI clock
    private var lastTickTime: Double = 0
    private var lastTickSeen: Double = 0
    private var tickCount = 0
    private var intervals: [Double] = []

    public var port: Int { config.httpPort }

    /// `root` holds `public/` and `config.json`; `dataDirectory` defaults to `root/data`.
    public init(root: URL, dataDirectory: URL? = nil, portOverride: Int? = nil) {
        self.root = root
        self.dataDirectory = dataDirectory ?? root.appendingPathComponent("data")
        var cfg = Config(file: root.appendingPathComponent("config.json"))
        if let p = portOverride { cfg.httpPort = p }
        config = cfg
        loadSnapshot()
        if let saved = readData("state.json") as? [String: Any], let memory = saved["memory"] as? Int {
            targetTrack = saved["targetTrack"] as? Int ?? 1
            loadMemory(memory, keepTarget: true)
        } else {
            loadMemory(snapshotCurrentMemory, keepTarget: false)
        }
    }

    // MARK: setup

    private func readData(_ name: String) -> Any? {
        guard let data = try? Data(contentsOf: dataDirectory.appendingPathComponent(name)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func loadSnapshot() {
        guard let o = readData("memories.json") as? [String: Any] else { return }
        snapshotCurrentMemory = o["currentMemory"] as? Int ?? 1
        for m in o["memories"] as? [[String: Any]] ?? [] {
            guard let number = m["number"] as? Int else { continue }
            var info = MemoryInfo()
            info.name = m["name"] as? String ?? ""
            info.tempo = (m["tempo"] as? NSNumber)?.doubleValue
            info.recAction = m["recAction"] as? Int ?? 0
            info.targetTrack = m["targetTrack"] as? Int ?? 1
            info.tracks = (m["tracks"] as? [[String: Any]] ?? []).map {
                ($0["hasPhrase"] as? Bool ?? false, ($0["loopMs"] as? NSNumber)?.doubleValue ?? 0)
            }
            memories[number] = info
        }
    }

    public func start() -> Bool {
        server.onRequest = { [unowned self] path in self.handleRequest(path) }
        server.onSocketOpen = { [unowned self] client in
            let text = self.model.sync { self.stateMessage() }
            client.send(text)
        }
        server.onSocketMessage = { [unowned self] text in self.handleSocketMessage(text) }
        guard server.start(port: UInt16(config.httpPort)) else { return false }
        log("Control page: http://localhost:\(config.httpPort)/")
        log("OBS overlay:  http://localhost:\(config.httpPort)/overlay")

        scanner.async { [self] in
            scan()
            if !model.sync(execute: { connected }) {
                log("Waiting for a MIDI port matching \"\(config.midiPortMatch)\" (the looper must not be in USB storage mode)")
            }
        }
        every(3, on: scanner) { [unowned self] in self.scan() }
        every(1, on: model) { [unowned self] in // the clock went quiet
            if self.tempo != nil, nowMs() - self.lastTickSeen > 2000 { self.tempo = nil; self.intervals.removeAll(); self.pushState() }
        }
        return true
    }

    private func every(_ seconds: Int, on queue: DispatchQueue, _ work: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(seconds), repeating: .seconds(seconds))
        timer.setEventHandler(handler: work)
        timer.resume()
        timers.append(timer)
    }

    // MARK: memory and persistence (model queue)

    private func loadMemory(_ number: Int, keepTarget: Bool) {
        let info = memories[number]
        memoryNumber = number
        memoryName = info?.name ?? ""
        snapshotTempo = info?.tempo
        recAction = info?.recAction ?? 0
        if !keepTarget { targetTrack = info?.targetTrack ?? 1 }
        flags = [(rec: Bool, play: Bool)](repeating: (false, false), count: 5)
        pending = nil
        let now = nowMs()
        tracks = (0..<5).map { i in
            let t = info.flatMap { i < $0.tracks.count ? $0.tracks[i] : nil }
            return Track(state: t?.hasPhrase == true ? "stop" : "empty", loopMs: t?.loopMs ?? 0, since: now)
        }
        persist()
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try? Data(jsonString(["memory": memoryNumber, "targetTrack": targetTrack]).utf8).write(to: dataDirectory.appendingPathComponent("state.json"))
    }

    // MARK: messages to the pages (model queue)

    private func stateObject() -> [String: Any] {
        [
            "connected": connected,
            "portName": portName ?? NSNull(),
            "memory": ["number": memoryNumber, "name": memoryName],
            "tempo": tempo ?? NSNull(),
            "snapshotTempo": snapshotTempo ?? NSNull(),
            "tracks": tracks.map { ["state": $0.state, "loopMs": $0.loopMs, "since": $0.since] },
        ]
    }
    private func stateMessage() -> String { jsonString(["type": "state", "state": stateObject(), "now": nowMs()]) }
    private func pushState() { server.broadcast(stateMessage()) }
    private func announce(_ id: String, _ label: String, _ source: String) {
        server.broadcast(jsonString(["type": "press", "id": id, "label": label, "source": source]))
    }

    // MARK: track model (model queue)

    private func setTrack(_ i: Int, _ state: String, loopMs: Double? = nil, keepSince: Bool = false) {
        tracks[i].state = state
        if let l = loopMs { tracks[i].loopMs = l }
        if !keepSince { tracks[i].since = nowMs() }
    }

    /// What a press of rec/play should do. The looper does not report rec -> overdub or
    /// play <-> overdub, so presses made from the app are predicted here.
    private func predictRecPlay(_ i: Int) {
        let t = tracks[i]
        switch t.state {
        case "empty": setTrack(i, "rec", loopMs: 0)
        case "rec": setTrack(i, recAction == 1 ? "play" : "overdub", loopMs: nowMs() - t.since)
        case "play": setTrack(i, "overdub", keepSince: true)
        case "overdub": setTrack(i, "play", keepSince: true)
        case "stop": setTrack(i, "play")
        default: break
        }
    }
    private func predictStop(_ i: Int) {
        let t = tracks[i]
        if t.state == "rec" { setTrack(i, "stop", loopMs: nowMs() - t.since) } else if t.isRunning { setTrack(i, "stop") }
    }

    /// A status report from the looper: the truth, applied over any prediction.
    private func onReport(rec isRec: Bool, _ i: Int, _ on: Bool) {
        let now = nowMs()
        if var p = pending, now - p.at < 600 {
            if i == p.track {
                p.confirmed = true
                pending = p
            } else if !p.confirmed, p.stop ? (!on && tracks[i].isRunning) : (on && (isRec || tracks[i].state != "rec")) {
                // The looper acted on a different track than the one commanded, so its target
                // track is not where we thought. Learn it and undo the prediction. (A recording
                // track dropping to play is ignored: the looper does that by itself when
                // another track starts recording.)
                log("Target track corrected: the looper answered on track \(i + 1), not \(p.track + 1)")
                targetTrack = i + 1
                tracks[p.track] = p.previous
                pending = nil
                persist()
            }
        }
        let before = tracks[i].state
        if isRec { flags[i].rec = on } else { flags[i].play = on }
        let t = tracks[i]
        let f = flags[i]
        if isRec, on {
            if f.play { if t.state != "overdub" { setTrack(i, "overdub", keepSince: true) } }
            else if t.state != "rec", t.state != "overdub" { setTrack(i, "rec", loopMs: 0) }
        } else if !isRec, on {
            if t.state == "rec", f.rec { setTrack(i, "play", loopMs: now - t.since) } // a real first pass just ended
            else if t.state == "overdub" { setTrack(i, "play", keepSince: true) }
            else if t.state != "play" { setTrack(i, "play") }
        } else if !on, !f.rec, !f.play {
            if t.state == "rec" { setTrack(i, "stop", loopMs: now - t.since) } else if t.isRunning { setTrack(i, "stop") }
        }
        // Show it as a hardware press unless the app just pressed this track itself.
        let after = tracks[i].state
        if after != before, now - lastAppPress[i] > 1500 {
            let label = ["rec": "Rec", "play": "Play", "overdub": "Overdub", "stop": "Stop"][after] ?? after
            announce("t\(i + 1).\(after == "stop" ? "stop" : "recplay")", "Track \(i + 1) \(label)", "device")
        }
        pushState()
    }

    // MARK: MIDI in (model queue)

    private func onMidi(_ bytes: [UInt8], _ time: Double) {
        let status = bytes[0]
        if status == 0xF8 { onClock(time); return }
        if status == 0xFA || status == 0xFB { tickCount = 0; return } // loop start: re-align the beat counter
        if status >= 0xF0 { return }
        let kind = status & 0xF0
        if kind == 0xC0, bytes.count >= 2 { // the looper switched memory
            let number = Int(bytes[1]) + 1
            loadMemory(number, keepTarget: false)
            announce("memory", "Memory \(number)", nowMs() - lastMemoryRequest < 1500 ? "app" : "device")
            pushState()
        } else if kind == 0xB0, bytes.count >= 3 {
            let cc = Int(bytes[1])
            if let i = config.reportRec.firstIndex(of: cc) { onReport(rec: true, i, bytes[2] >= 64) }
            else if let i = config.reportPlay.firstIndex(of: cc) { onReport(rec: false, i, bytes[2] >= 64) }
        }
    }

    private func onClock(_ time: Double) {
        let gap = time - lastTickTime
        if lastTickTime > 0, gap > 0, gap < 500 {
            intervals.append(gap)
            if intervals.count > 96 { intervals.removeFirst() }
        }
        lastTickTime = time
        lastTickSeen = nowMs()
        if tickCount % 24 == 0 {
            if intervals.count >= 24 {
                let average = intervals.reduce(0, +) / Double(intervals.count)
                let bpm = (60000 / (average * 24) * 10).rounded() / 10
                if tempo == nil || abs(bpm - (tempo ?? 0)) >= 0.3 { tempo = bpm; pushState() }
            }
            server.broadcast(jsonString(["type": "beat", "n": (tickCount / 24) % 4]))
        }
        tickCount += 1
    }

    // MARK: device discovery (scanner queue)

    private func scan() {
        if let current = model.sync(execute: { device }) {
            if !current.isAlive {
                current.close()
                model.sync {
                    device = nil; connected = false; portName = nil; tempo = nil
                    pushState()
                }
                log("Looper disconnected")
            }
            return
        }
        let opened = Midi.open(matching: config.midiPortMatch) { [weak self] bytes, time in
            self?.model.async { self?.onMidi(bytes, time) }
        }
        guard let opened = opened else { return }
        model.sync {
            device = opened; connected = true; portName = opened.name
            lastTickTime = 0; intervals.removeAll()
            pushState()
        }
        log("Looper connected: \(opened.name)")
    }

    // MARK: MIDI out (sender queue)

    private func sendMidi(_ bytes: [UInt8]) {
        let current = model.sync { device }
        current?.send(bytes)
    }
    private func pause() { Thread.sleep(forTimeInterval: Double(config.gapMs) / 1000) }
    private func tap(_ cc: Int) {
        let status = UInt8(0xB0 | (config.midiChannel - 1))
        sendMidi([status, UInt8(cc), 127]); pause()
        sendMidi([status, UInt8(cc), 0]); pause()
    }

    /// Steps the looper's target track to `i` (each tap moves it down one, wrapping 1 -> 5),
    /// then taps rec/play or stop.
    private func trackAction(_ i: Int, stop: Bool) {
        model.sync { lastAppPress[i] = nowMs() }
        while model.sync(execute: { targetTrack != i + 1 }) {
            tap(config.targetStep)
            model.sync { targetTrack = targetTrack == 1 ? 5 : targetTrack - 1 }
        }
        model.sync {
            persist()
            // Predict first: the looper's own report arrives within milliseconds and must win.
            pending = (i, stop, nowMs(), tracks[i], false)
            if stop { predictStop(i) } else { predictRecPlay(i) }
            pushState()
        }
        tap(stop ? config.stop : config.recPlay)
    }

    // MARK: commands (any thread)

    @discardableResult
    func press(_ id: String, source: String = "app") -> Bool {
        let parts = id.split(separator: ".")
        if parts.count == 2, parts[0].count == 2, parts[0].first == "t", let n = Int(parts[0].dropFirst()), (1...5).contains(n),
           parts[1] == "recplay" || parts[1] == "stop" {
            let stop = parts[1] == "stop"
            model.sync { announce(id, "Track \(n) \(stop ? "Stop" : "Rec/Play")", source) }
            sender.async { self.trackAction(n - 1, stop: stop) }
            return true
        }
        if id == "all" { // no spare assign slot for ALL START/STOP, so do it track by track
            let (stopping, targets): (Bool, [Int]) = model.sync {
                let stopping = tracks.contains { $0.isRunning }
                announce(id, stopping ? "All Stop" : "All Start", source)
                return (stopping, tracks.indices.filter { stopping ? tracks[$0].isRunning : tracks[$0].state == "stop" })
            }
            for i in targets { sender.async { self.trackAction(i, stop: stopping) } }
            return true
        }
        return false
    }

    @discardableResult
    func selectMemory(_ number: Int) -> Bool {
        guard (1...99).contains(number) else { return false }
        // The looper echoes the program change when it really switches (it refuses while
        // recording), so the model only changes when that echo arrives in onMidi. Sent even
        // when we think we are already there: re-picking a memory is how to resync.
        sender.async { [self] in
            // Just after a stop the looper sometimes ignores the first request, so ask twice.
            for attempt in 0..<2 where attempt == 0 || model.sync(execute: { memoryNumber != number }) {
                model.sync { lastMemoryRequest = nowMs() }
                sendMidi([UInt8(0xC0 | (config.midiChannel - 1)), UInt8(number - 1)])
                Thread.sleep(forTimeInterval: 1.5)
            }
            model.sync {
                if memoryNumber != number {
                    server.broadcast(jsonString(["type": "notice", "text": "The looper did not switch to memory \(number). Stop all tracks first."]))
                }
            }
        }
        return true
    }

    // Manual corrections for when the model has drifted from the real looper.
    @discardableResult
    func setTrackState(_ i: Int, _ state: String) -> Bool {
        guard (0..<5).contains(i), ["empty", "stop", "play", "rec", "overdub"].contains(state) else { return false }
        model.sync { setTrack(i, state); pushState() }
        return true
    }
    @discardableResult
    func setTargetTrack(_ n: Int) -> Bool {
        guard (1...5).contains(n) else { return false }
        model.sync { targetTrack = n; persist() }
        return true
    }

    // MARK: HTTP and WebSocket

    private static let contentTypes = ["html": "text/html", "js": "text/javascript", "css": "text/css", "json": "application/json", "svg": "image/svg+xml"]

    private func handleRequest(_ path: String) -> HTTPResponse {
        let parts = path.split(separator: "/").map(String.init)
        // Simple endpoints so a Stream Deck or script can trigger actions.
        if parts.count == 3, parts[0] == "api" {
            switch parts[1] {
            case "press": let ok = press(parts[2], source: "api"); return .json(ok ? 200 : 404, ["ok": ok])
            case "memory": let ok = Int(parts[2]).map { selectMemory($0) } ?? false; return .json(ok ? 200 : 400, ["ok": ok])
            case "target": let ok = Int(parts[2]).map { setTargetTrack($0) } ?? false; return .json(ok ? 200 : 400, ["ok": ok])
            default: return .notFound
            }
        }
        if path == "/api/state" {
            return .json(200, model.sync { () -> [String: Any] in var o = stateObject(); o["targetTrack"] = targetTrack; return o })
        }
        if path == "/memories.json" {
            return .json(200, memories.keys.sorted().map { ["number": $0, "name": memories[$0]?.name ?? ""] as [String: Any] })
        }
        let relative = path == "/" ? "control.html" : path == "/overlay" ? "overlay.html" : String(path.dropFirst())
        guard !relative.contains(".."), !relative.contains("\\"), !relative.isEmpty else { return .notFound }
        let file = root.appendingPathComponent("public").appendingPathComponent(relative)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let data = try? Data(contentsOf: file) else { return .notFound }
        return HTTPResponse(status: 200, contentType: Self.contentTypes[file.pathExtension] ?? "application/octet-stream", body: Array(data))
    }

    private func handleSocketMessage(_ text: String) {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], let type = o["type"] as? String else { return }
        switch type {
        case "press": if let id = o["id"] as? String { press(id) }
        case "memory": if let n = (o["number"] as? NSNumber)?.intValue { selectMemory(n) }
        case "setTrack": if let i = (o["track"] as? NSNumber)?.intValue, let s = o["state"] as? String { setTrackState(i, s) }
        default: break
        }
    }
}
