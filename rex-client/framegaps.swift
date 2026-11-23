// What WindowServer composites for one window: the time of each new frame.
//
//   framegaps <window id> <seconds> [events.jsonl]
//
// Prints frame-gap stats. With an events file, also writes one Chrome trace
// slice per frame (ts and dur in µs of mach time), for perf-trace.sh. Only a
// window on the current Space is composited at the display's rate; for any
// other window it says so and writes nothing.
import AppKit
import ScreenCaptureKit

_ = NSApplication.shared  // ScreenCaptureKit needs a CoreGraphics connection
setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count >= 3, let wid = CGWindowID(args[1]), let secs = Double(args[2]) else {
  print("usage: framegaps <window id> <seconds> [events.jsonl]")
  exit(2)
}

final class Frames: NSObject, SCStreamOutput {
  var times: [Double] = []  // µs of mach time
  let usPerTick: Double = {
    var tb = mach_timebase_info()
    mach_timebase_info(&tb)
    return Double(tb.numer) / Double(tb.denom) / 1000
  }()
  func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
    guard let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
      let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
      let display = info[.displayTime] as? UInt64
    else { return }
    times.append(Double(display) * usPerTick)
  }
}

let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
guard let window = content.windows.first(where: { $0.windowID == wid }) else {
  print("no window \(wid)")
  exit(1)
}
guard window.isOnScreen else {
  print("window \(wid) is not on screen (another Space?): no WindowServer timing")
  exit(0)
}
let cfg = SCStreamConfiguration()
cfg.width = 320
cfg.height = 200
cfg.minimumFrameInterval = CMTime(value: 1, timescale: 240)
cfg.queueDepth = 8
let frames = Frames(), queue = DispatchQueue(label: "frames")
let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: cfg, delegate: nil)
try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: queue)
try await stream.startCapture()
try await Task.sleep(for: .seconds(secs))
try await stream.stopCapture()

let t = queue.sync { frames.times }
let gaps = zip(t.dropFirst(), t).map { $0 - $1 }
if args.count > 3 {
  var out = "{\"name\":\"process_name\",\"ph\":\"M\",\"pid\":1,\"args\":{\"name\":\"WindowServer (Rex window)\"}}\n"
  for (i, g) in gaps.enumerated() {
    out += "{\"name\":\"frame\",\"cat\":\"window\",\"ph\":\"X\",\"pid\":1,\"tid\":1,\"ts\":\(t[i]),\"dur\":\(g)}\n"
  }
  try out.write(toFile: args[3], atomically: true, encoding: .utf8)
}
guard gaps.count > 10 else {
  print("frames=\(t.count): the window barely changed")
  exit(0)
}
let d = gaps.sorted()
let q = { (p: Double) in d[min(d.count - 1, Int(Double(d.count) * p))] / 1000 }
let worst = d[Int(Double(d.count) * 0.99)...]
print(String(format: "window: %d frames, %.1f fps, p50 %.1f ms, p99 %.1f ms, max %.1f ms, 1%% low %.1f fps, >25 ms: %d",
  d.count, Double(d.count) / ((t.last! - t.first!) / 1e6), q(0.5), q(0.99), d.last! / 1000,
  1e6 / (worst.reduce(0, +) / Double(worst.count)), d.filter { $0 > 25000 }.count))
