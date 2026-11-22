import Foundation

/// One complete MIDI message and the driver's timestamp for it, in milliseconds.
typealias MidiHandler = (_ bytes: [UInt8], _ timeMs: Double) -> Void

protocol MidiDevice: AnyObject {
    var name: String { get }
    /// False once the device has gone away (unplugged, or switched to USB storage mode).
    var isAlive: Bool { get }
    func send(_ bytes: [UInt8])
    func close()
}

enum Midi {
    /// Opens the first MIDI device whose name contains `match` (case-insensitive), for input and output.
    static func open(matching match: String, onMessage: @escaping MidiHandler) -> MidiDevice? {
        #if canImport(CoreMIDI)
        return CoreMidiDevice(matching: match, onMessage: onMessage)
        #elseif os(Linux)
        return AlsaMidiDevice(matching: match, onMessage: onMessage)
        #elseif os(Windows)
        return WinMidiDevice(matching: match, onMessage: onMessage)
        #else
        return nil
        #endif
    }
}

/// Turns a raw MIDI byte stream into whole messages: handles running status and
/// real-time bytes arriving in the middle of another message; skips SysEx.
final class MidiParser {
    private var status: UInt8 = 0
    private var data: [UInt8] = []
    private let emit: MidiHandler
    init(_ emit: @escaping MidiHandler) { self.emit = emit }

    func feed(_ bytes: [UInt8], _ timeMs: Double) {
        for b in bytes {
            if b >= 0xF8 { emit([b], timeMs); continue }
            if b & 0x80 != 0 {
                status = b >= 0xF0 ? 0 : b
                data.removeAll(keepingCapacity: true)
                continue
            }
            guard status != 0 else { continue }
            data.append(b)
            let kind = status & 0xF0
            if data.count == ((kind == 0xC0 || kind == 0xD0) ? 1 : 2) {
                emit([status] + data, timeMs)
                data.removeAll(keepingCapacity: true)
            }
        }
    }
}

func monotonicMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }
