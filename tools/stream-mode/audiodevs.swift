import CoreAudio
import Foundation

func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ def: T) -> T {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    var v = def
    guard AudioObjectHasProperty(obj, &addr) else { return def }
    let st = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v)
    return st == noErr ? v : def
}
func str(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var v: Unmanaged<CFString>? = nil
    guard AudioObjectHasProperty(obj, &addr), AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr, let s = v?.takeRetainedValue() else { return "?" }
    return s as String
}
func channels(_ obj: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let buf = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size)); defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, buf) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(buf).reduce(0) { $0 + Int($1.mNumberChannels) }
}
var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
let defOut = prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioObjectID(0))
let defIn = prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, AudioObjectID(0))
let defSys = prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioObjectPropertyScopeGlobal, AudioObjectID(0))
print(String(format: "%-4@ %-34@ %-52@ %6@ %5@ %5@ %7@ %-12@ %@", "id", "name", "uid", "rate", "in", "out", "bufsz", "buf range", "flags"))
for id in ids {
    let uid = str(id, kAudioDevicePropertyDeviceUID)
    let name = str(id, kAudioObjectPropertyName)
    let rate = prop(id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0))
    let bufsz = prop(id, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, UInt32(0))
    let range = prop(id, kAudioDevicePropertyBufferFrameSizeRange, kAudioObjectPropertyScopeGlobal, AudioValueRange(mMinimum: 0, mMaximum: 0))
    let running = prop(id, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, UInt32(0))
    var flags: [String] = []
    if id == defOut { flags.append("DEFAULT-OUT") }; if id == defIn { flags.append("DEFAULT-IN") }; if id == defSys { flags.append("SYSTEM-OUT") }
    if running != 0 { flags.append("running") }
    print(String(format: "%-4d %-34@ %-52@ %6.0f %5d %5d %7d %-12@ %@", id, String(name.prefix(34)), String(uid.prefix(52)), rate, channels(id, kAudioObjectPropertyScopeInput), channels(id, kAudioObjectPropertyScopeOutput), bufsz, "\(Int(range.mMinimum))–\(Int(range.mMaximum))", flags.joined(separator: ",")))
}
