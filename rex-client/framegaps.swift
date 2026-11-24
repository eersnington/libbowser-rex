// What WindowServer composites for Rex windows: the time of each new frame.
//
//   framegaps <window id> <seconds> [events.jsonl]   stats, and trace slices
//   framegaps stream <window id>[,<window id>…]      one JSON line per frame
//   framegaps windows <pid>                          the process's window ids
//
// Times are µs of mach time. A window is only composited at the display's
// rate while it is on the current Space, so frames are only counted then.
// Stream mode prints {"w":id,"ts":…} per frame and {"w":id,"on":bool,"ts":…}
// when a window shows or hides, until it is killed.
import AppKit
import ScreenCaptureKit

_ = NSApplication.shared  // ScreenCaptureKit needs a CoreGraphics connection
setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let usPerTick: Double = {
  var tb = mach_timebase_info()
  mach_timebase_info(&tb)
  return Double(tb.numer) / Double(tb.denom) / 1000
}()
func nowUs() -> Double { Double(mach_absolute_time()) * usPerTick }

func onScreen(_ id: CGWindowID) -> Bool {
  let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]]
  return (info?.first?[kCGWindowIsOnscreen as String] as? Bool) ?? false
}

final class Frames: NSObject, SCStreamOutput {
  let id: CGWindowID
  let onFrame: (CGWindowID, Double) -> Void
  init(id: CGWindowID, onFrame: @escaping (CGWindowID, Double) -> Void) {
    self.id = id
    self.onFrame = onFrame
  }
  func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
    guard let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
      let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
      let display = info[.displayTime] as? UInt64
    else { return }
    onFrame(id, Double(display) * usPerTick)
  }
}

func capture(_ ids: [CGWindowID], onFrame: @escaping (CGWindowID, Double) -> Void) async throws -> [SCStream] {
  let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
  var streams: [SCStream] = []
  for id in ids {
    guard let window = content.windows.first(where: { $0.windowID == id }) else { continue }
    let cfg = SCStreamConfiguration()
    cfg.width = 64  // only the timing matters; keep the copies tiny
    cfg.height = 40
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 240)
    cfg.queueDepth = 8
    let out = Frames(id: id, onFrame: onFrame)
    let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: cfg, delegate: nil)
    try s.addStreamOutput(out, type: .screen, sampleHandlerQueue: DispatchQueue(label: "frames \(id)"))
    objc_setAssociatedObject(s, "out", out, .OBJC_ASSOCIATION_RETAIN)
    try await s.startCapture()
    streams.append(s)
  }
  return streams
}

if args.count == 3, args[1] == "windows", let pid = Int(args[2]) {
  // The process's normal windows big enough to hold panes.
  let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
  let ids = all.filter {
    ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
      && (($0[kCGWindowBounds as String] as? [String: Double])?["Height"] ?? 0) > 200
  }.compactMap { $0[kCGWindowNumber as String] as? Int }
  print(ids.map(String.init).joined(separator: ","))
  exit(0)
}

if args.count == 3, args[1] == "stream" {
  let ids = args[2].split(separator: ",").compactMap { CGWindowID($0) }
  let lock = NSLock()
  var visible = Dictionary(uniqueKeysWithValues: ids.map { ($0, onScreen($0)) })
  for (id, on) in visible { print("{\"w\":\(id),\"on\":\(on),\"ts\":\(nowUs())}") }
  let streams = try await capture(ids) { id, ts in
    let on = lock.withLock { visible[id] ?? false }
    if on { print("{\"w\":\(id),\"ts\":\(ts)}") }
  }
  _ = streams
  while true {
    try await Task.sleep(for: .milliseconds(250))
    for id in ids {
      let on = onScreen(id)
      let was = lock.withLock {
        let was = visible[id]
        visible[id] = on
        return was
      }
      if was != on { print("{\"w\":\(id),\"on\":\(on),\"ts\":\(nowUs())}") }
    }
  }
}

guard args.count >= 3, let wid = CGWindowID(args[1]), let secs = Double(args[2]) else {
  print("usage: framegaps <window id> <seconds> [events.jsonl] | framegaps stream <id>[,<id>…]")
  exit(2)
}
guard onScreen(wid) else {
  print("window \(wid) is not on screen (another Space?): no WindowServer timing")
  exit(0)
}
let lock = NSLock()
var t: [Double] = []
let streams = try await capture([wid]) { _, ts in
  lock.withLock { t.append(ts) }
}
try await Task.sleep(for: .seconds(secs))
for s in streams { try await s.stopCapture() }
let times = lock.withLock { t }
let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
if args.count > 3 {
  var out = "{\"name\":\"process_name\",\"ph\":\"M\",\"pid\":1,\"args\":{\"name\":\"WindowServer (Rex window)\"}}\n"
  for (i, g) in gaps.enumerated() {
    out += "{\"name\":\"frame\",\"cat\":\"window\",\"ph\":\"X\",\"pid\":1,\"tid\":1,\"ts\":\(times[i]),\"dur\":\(g)}\n"
  }
  try out.write(toFile: args[3], atomically: true, encoding: .utf8)
}
guard gaps.count > 10 else {
  print("frames=\(times.count): the window barely changed")
  exit(0)
}
let d = gaps.sorted()
let q = { (p: Double) in d[min(d.count - 1, Int(Double(d.count) * p))] / 1000 }
let worst = d[Int(Double(d.count) * 0.99)...]
print(String(format: "window: %d frames, %.1f fps, p50 %.1f ms, p99 %.1f ms, max %.1f ms, 1%% low %.1f fps, >25 ms: %d",
  d.count, Double(d.count) / ((times.last! - times.first!) / 1e6), q(0.5), q(0.99), d.last! / 1000,
  1e6 / (worst.reduce(0, +) / Double(worst.count)), d.filter { $0 > 25000 }.count))
