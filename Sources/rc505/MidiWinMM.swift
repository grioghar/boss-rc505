#if os(Windows)
import Foundation
import WinSDK

/// Windows multimedia MIDI (winmm). Needs the Roland RC-505 USB driver installed.
final class WinMidiDevice: MidiDevice {
    let name: String
    private var hIn: HMIDIIN?
    private var hOut: HMIDIOUT?
    private let inIndex: UINT
    private let onMessage: MidiHandler
    /// winmm calls back into a plain C function, which finds the open device here.
    fileprivate static weak var current: WinMidiDevice?

    private static func wide<T>(_ tuple: inout T) -> String {
        withUnsafePointer(to: &tuple) {
            $0.withMemoryRebound(to: WCHAR.self, capacity: MemoryLayout<T>.size / MemoryLayout<WCHAR>.size) {
                String(decodingCString: $0, as: UTF16.self)
            }
        }
    }
    private static func inputName(_ i: UINT) -> String {
        var caps = MIDIINCAPSW()
        guard midiInGetDevCapsW(UINT_PTR(i), &caps, UINT(MemoryLayout<MIDIINCAPSW>.size)) == 0 else { return "" }
        return wide(&caps.szPname)
    }
    private static func outputName(_ i: UINT) -> String {
        var caps = MIDIOUTCAPSW()
        guard midiOutGetDevCapsW(UINT_PTR(i), &caps, UINT(MemoryLayout<MIDIOUTCAPSW>.size)) == 0 else { return "" }
        return wide(&caps.szPname)
    }

    init?(matching match: String, onMessage: @escaping MidiHandler) {
        let matches: (String) -> Bool = { $0.range(of: match, options: .caseInsensitive) != nil }
        guard let i = (0..<midiInGetNumDevs()).first(where: { matches(Self.inputName($0)) }),
              let o = (0..<midiOutGetNumDevs()).first(where: { matches(Self.outputName($0)) }) else { return nil }
        inIndex = i
        name = Self.inputName(i)
        self.onMessage = onMessage

        let callback: @convention(c) (HMIDIIN?, UINT, DWORD_PTR, DWORD_PTR, DWORD_PTR) -> Void = { _, message, _, param1, param2 in
            guard message == UINT(MIM_DATA), let device = WinMidiDevice.current else { return }
            let status = UInt8(param1 & 0xFF)
            let d1 = UInt8((param1 >> 8) & 0xFF)
            let d2 = UInt8((param1 >> 16) & 0xFF)
            let kind = status & 0xF0
            let bytes: [UInt8] = status >= 0xF8 ? [status] : (kind == 0xC0 || kind == 0xD0) ? [status, d1] : [status, d1, d2]
            device.onMessage(bytes, Double(param2)) // param2: milliseconds since midiInStart
        }
        guard midiInOpen(&hIn, i, unsafeBitCast(callback, to: DWORD_PTR.self), 0, DWORD(CALLBACK_FUNCTION)) == 0 else { return nil }
        guard midiOutOpen(&hOut, o, 0, 0, DWORD(CALLBACK_NULL)) == 0 else { midiInClose(hIn); return nil }
        WinMidiDevice.current = self
        midiInStart(hIn)
    }

    var isAlive: Bool { Self.inputName(inIndex) == name }

    func send(_ bytes: [UInt8]) {
        var packed: DWORD = 0
        for (n, b) in bytes.prefix(3).enumerated() { packed |= DWORD(b) << DWORD(8 * n) }
        midiOutShortMsg(hOut, packed)
    }

    func close() {
        if let h = hIn { midiInStop(h); midiInClose(h) }
        if let h = hOut { midiOutClose(h) }
        hIn = nil
        hOut = nil
    }
}
#endif
