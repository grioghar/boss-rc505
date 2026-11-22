#if os(Linux)
import CALSA
import Foundation

/// ALSA raw MIDI. Needs libasound2 (build: libasound2-dev) and a kernel driver that
/// exposes the looper as a rawmidi device.
final class AlsaMidiDevice: MidiDevice {
    let name: String
    private var input: OpaquePointer?
    private var output: OpaquePointer?
    private var alive = true
    private let lock = NSLock()

    init?(matching match: String, onMessage: @escaping MidiHandler) {
        var found: (hw: String, name: String)?
        var card: Int32 = -1
        while found == nil, snd_card_next(&card) == 0, card >= 0 {
            var cardNamePtr: UnsafeMutablePointer<CChar>?
            var cardName = ""
            if snd_card_get_name(card, &cardNamePtr) == 0, let p = cardNamePtr { cardName = String(cString: p); free(p) }
            var ctl: OpaquePointer?
            guard snd_ctl_open(&ctl, "hw:\(card)", 0) == 0 else { continue }
            var device: Int32 = -1
            while found == nil, snd_ctl_rawmidi_next_device(ctl, &device) == 0, device >= 0 {
                var info: OpaquePointer?
                snd_rawmidi_info_malloc(&info)
                snd_rawmidi_info_set_device(info, UInt32(device))
                snd_rawmidi_info_set_stream(info, SND_RAWMIDI_STREAM_INPUT)
                var deviceName = ""
                if snd_ctl_rawmidi_info(ctl, info) == 0, let p = snd_rawmidi_info_get_name(info) { deviceName = String(cString: p) }
                snd_rawmidi_info_free(info)
                let full = "\(cardName) \(deviceName)"
                if full.range(of: match, options: .caseInsensitive) != nil { found = ("hw:\(card),\(device),0", full) }
            }
            snd_ctl_close(ctl)
        }
        guard let target = found, snd_rawmidi_open(&input, &output, target.hw, 0) == 0 else { return nil }
        name = target.name

        let parser = MidiParser(onMessage)
        let handle = input
        Thread.detachNewThread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 256)
            while true {
                let n = snd_rawmidi_read(handle, &buffer, 256)
                if n <= 0 { break }
                parser.feed(Array(buffer[0..<n]), monotonicMs())
            }
            self?.lock.lock(); self?.alive = false; self?.lock.unlock()
        }
    }

    var isAlive: Bool { lock.lock(); defer { lock.unlock() }; return alive }

    func send(_ bytes: [UInt8]) {
        guard let out = output else { return }
        if snd_rawmidi_write(out, bytes, bytes.count) < 0 { lock.lock(); alive = false; lock.unlock() }
        snd_rawmidi_drain(out)
    }

    func close() {
        if let i = input { snd_rawmidi_close(i) }
        if let o = output { snd_rawmidi_close(o) }
        input = nil
        output = nil
    }
}
#endif
