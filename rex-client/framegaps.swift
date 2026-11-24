// What WindowServer composites for Rex windows: the time of each new frame.
//
//   framegaps <window id> <seconds> [events.jsonl]   stats, and trace slices
//   framegaps stream <window id>[,<window id>…] [panes.json]
//                                                    one JSON line per frame
//   framegaps windows <pid>                          the process's window ids
//
// Times are µs of mach time. A window is only composited at the display's
// rate while it is on the current Space, so frames are only counted then.
// Stream mode prints {"w":id,"ts":…} per frame and {"w":id,"on":bool,"ts":…}
// when a window shows or hides, until it is killed. With the Rex client's
// pane rectangles (BOWSER_REX_PANES), it also prints {"w":id,"p":block,"ts":…}
// for each pane whose pixels changed in that frame: what one pane showed,
// which the window's frames can't tell when several panes animate. Pixels are
// compared in memory and never kept.
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
  let onFrame: (CGWindowID, Double, CVPixelBuffer?) -> Void
  init(id: CGWindowID, onFrame: @escaping (CGWindowID, Double, CVPixelBuffer?) -> Void) {
    self.id = id
    self.onFrame = onFrame
  }
  func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
    guard let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
      let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
      let display = info[.displayTime] as? UInt64
    else { return }
    onFrame(id, Double(display) * usPerTick, CMSampleBufferGetImageBuffer(sb))
  }
}

func capture(_ ids: [CGWindowID], pixels: Bool = false, onFrame: @escaping (CGWindowID, Double, CVPixelBuffer?) -> Void) async throws -> [SCStream] {
  let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
  var streams: [SCStream] = []
  for id in ids {
    guard let window = content.windows.first(where: { $0.windowID == id }) else { continue }
    let cfg = SCStreamConfiguration()
    // Timing alone needs only a tiny copy. Pane pixels need half the
    // window's point size: motion under a copied pixel looks like a pause.
    cfg.width = pixels ? Int(window.frame.width / 2) : 64
    cfg.height = pixels ? Int(window.frame.height / 2) : 40
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
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

/// The bytes of a rectangle of the frame (half the window's scale), to
/// compare with the next frame's: any difference means the pane changed.
func region(_ buf: CVPixelBuffer, _ r: [Double], _ scale: Double) -> [UInt8] {
  CVPixelBufferLockBaseAddress(buf, .readOnly)
  defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
  guard let base = CVPixelBufferGetBaseAddress(buf)?.assumingMemoryBound(to: UInt8.self) else { return [] }
  let row = CVPixelBufferGetBytesPerRow(buf), w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
  // Inset a pixel: the edge blends with the pane's border.
  let x0 = min(w, max(0, Int(r[0] * scale) + 1)), x1 = min(w, max(x0, Int((r[0] + r[2]) * scale) - 1))
  let y0 = min(h, max(0, Int(r[1] * scale) + 1)), y1 = min(h, max(y0, Int((r[1] + r[3]) * scale) - 1))
  var out = [UInt8]()
  out.reserveCapacity((x1 - x0) * 4 * (y1 - y0))
  for y in y0..<y1 {
    out.append(contentsOf: UnsafeBufferPointer(start: base + y * row + x0 * 4, count: (x1 - x0) * 4))
  }
  return out
}

if args.count >= 3, args[1] == "stream" {
  let ids = args[2].split(separator: ",").compactMap { CGWindowID($0) }
  let panesPath = args.count > 3 ? args[3] : nil
  let lock = NSLock()
  var visible = Dictionary(uniqueKeysWithValues: ids.map { ($0, onScreen($0)) })
  var panes: [String: [String: [Double]]] = [:]  // window → block → rect, plus "size"
  var previous: [String: [UInt8]] = [:]
  func loadPanes() {
    guard let panesPath, let data = FileManager.default.contents(atPath: panesPath),
      let p = try? JSONSerialization.jsonObject(with: data) as? [String: [String: [Double]]]
    else { return }
    lock.withLock { panes = p }
  }
  loadPanes()
  for (id, on) in visible { print("{\"w\":\(id),\"on\":\(on),\"ts\":\(nowUs())}") }
  let streams = try await capture(ids, pixels: panesPath != nil) { id, ts, buf in
    let (on, mine) = lock.withLock { (visible[id] ?? false, panes[String(id)]) }
    guard on else { return }
    print("{\"w\":\(id),\"ts\":\(ts)}")
    guard let buf, let mine, let size = mine["size"], size[0] > 0 else { return }
    let scale = Double(CVPixelBufferGetWidth(buf)) / size[0]
    for (block, rect) in mine where block != "size" {
      let now = region(buf, rect, scale)
      let key = "\(id) \(block)"
      let before = lock.withLock { previous.updateValue(now, forKey: key) }
      if let before, before.count == now.count, before != now {
        print("{\"w\":\(id),\"p\":\"\(block)\",\"ts\":\(ts)}")
      }
    }
  }
  let parent = getppid()
  while true {
    try await Task.sleep(for: .milliseconds(250))
    // Using the streams here keeps them alive: released, they stop capturing.
    if getppid() != parent || streams.isEmpty { exit(0) }  // the recorder is gone
    loadPanes()
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
let streams = try await capture([wid]) { _, ts, _ in
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
