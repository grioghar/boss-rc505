#if canImport(CoreMIDI)
import CoreMIDI
import Foundation

final class CoreMidiDevice: MidiDevice {
    let name: String
    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private let source: MIDIEndpointRef
    private let destination: MIDIEndpointRef
    private var parser: MidiParser!
    private let ticksToMs: Double

    private static func displayName(_ object: MIDIObjectRef) -> String {
        var value: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &value)
        return (value?.takeRetainedValue() as String?) ?? ""
    }
    private static func find(_ match: String, count: Int, get: (Int) -> MIDIEndpointRef) -> MIDIEndpointRef? {
        for i in 0..<count {
            let endpoint = get(i)
            if displayName(endpoint).range(of: match, options: .caseInsensitive) != nil { return endpoint }
        }
        return nil
    }

    init?(matching match: String, onMessage: @escaping MidiHandler) {
        guard let src = Self.find(match, count: MIDIGetNumberOfSources(), get: MIDIGetSource),
              let dst = Self.find(match, count: MIDIGetNumberOfDestinations(), get: MIDIGetDestination) else { return nil }
        source = src
        destination = dst
        name = Self.displayName(src)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        ticksToMs = Double(timebase.numer) / Double(timebase.denom) / 1_000_000
        parser = MidiParser(onMessage)

        guard MIDIClientCreateWithBlock("rc505" as CFString, &client, nil) == noErr else { return nil }
        let toMs = ticksToMs
        let parser = self.parser!
        let status = MIDIInputPortCreateWithBlock(client, "in" as CFString, &inPort) { list, _ in
            for packet in list.unsafeSequence() {
                let length = Int(packet.pointee.length)
                let base = UnsafeRawPointer(packet).advanced(by: MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data)!)
                let bytes = Array(UnsafeRawBufferPointer(start: base, count: length))
                let stamp = packet.pointee.timeStamp == 0 ? mach_absolute_time() : packet.pointee.timeStamp
                parser.feed(bytes, Double(stamp) * toMs)
            }
        }
        guard status == noErr,
              MIDIPortConnectSource(inPort, source, nil) == noErr,
              MIDIOutputPortCreate(client, "out" as CFString, &outPort) == noErr else {
            MIDIClientDispose(client)
            return nil
        }
    }

    var isAlive: Bool {
        for i in 0..<MIDIGetNumberOfSources() where MIDIGetSource(i) == source { return true }
        return false
    }

    func send(_ bytes: [UInt8]) {
        var list = MIDIPacketList()
        let first = MIDIPacketListInit(&list)
        _ = MIDIPacketListAdd(&list, MemoryLayout<MIDIPacketList>.size, first, 0, bytes.count, bytes)
        MIDISend(outPort, destination, &list)
    }

    func close() { MIDIClientDispose(client) }
}
#endif
