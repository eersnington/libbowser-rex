// GPU and CPU load every 50 ms, as Chrome trace counters, for perf-trace.sh.
//
//   sysmon <seconds> <out.jsonl> <rex client pid> <engine pid>
//
// With 0 seconds it runs until killed; with "-" as the file it prints each
// line as it samples.
// GPU time per process comes from the IOKit accelerator user clients (what
// Activity Monitor's GPU column reads); CPU from proc_pid_rusage and the
// kernel's per-core ticks. Other apps appear only as one total, never by name.
import Darwin
import Foundation
import IOKit

let args = CommandLine.arguments
guard args.count == 5, let secs = Double(args[1]), let rex = pid_t(args[3]), let engine = pid_t(args[4]) else {
  print("usage: sysmon <seconds> <out.jsonl> <rex client pid> <engine pid>")
  exit(2)
}
let usPerTick: Double = {
  var tb = mach_timebase_info()
  mach_timebase_info(&tb)
  return Double(tb.numer) / Double(tb.denom) / 1000
}()
func nowUs() -> Double { Double(mach_absolute_time()) * usPerTick }

/// Accumulated GPU nanoseconds per pid.
func gpuTimes() -> [pid_t: Double] {
  var out: [pid_t: Double] = [:]
  var it: io_iterator_t = 0
  guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else {
    return out
  }
  defer { IOObjectRelease(it) }
  while case let accel = IOIteratorNext(it), accel != 0 {
    defer { IOObjectRelease(accel) }
    var kids: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(accel, kIOServicePlane, &kids) == KERN_SUCCESS else { continue }
    defer { IOObjectRelease(kids) }
    while case let c = IOIteratorNext(kids), c != 0 {
      defer { IOObjectRelease(c) }
      guard let creator = IORegistryEntryCreateCFProperty(c, "IOUserClientCreator" as CFString, nil, 0)?
        .takeRetainedValue() as? String,
        let usage = IORegistryEntryCreateCFProperty(c, "AppUsage" as CFString, nil, 0)?.takeRetainedValue() as? [[String: Any]],
        let pid = pid_t(creator.split(separator: ",").first?.dropFirst(4) ?? "")
      else { continue }
      out[pid, default: 0] += usage.reduce(0) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.doubleValue ?? 0) }
    }
  }
  return out
}

func cpuUs(_ pid: pid_t) -> Double {
  var ri = rusage_info_v4()
  let ok = withUnsafeMutablePointer(to: &ri) {
    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
  }
  return ok == 0 ? Double(ri.ri_user_time + ri.ri_system_time) * usPerTick : 0
}

/// Busy and total ticks over all cores.
func machineTicks() -> (busy: Double, total: Double) {
  var count: natural_t = 0
  var info: processor_info_array_t?
  var infoCount: mach_msg_type_number_t = 0
  guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
    let info
  else { return (0, 0) }
  defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * 4) }
  var busy = 0.0, total = 0.0
  for i in 0..<Int(count) {
    let b = i * Int(CPU_STATE_MAX)
    let user = Double(info[b + Int(CPU_STATE_USER)]), sys = Double(info[b + Int(CPU_STATE_SYSTEM)])
    let nice = Double(info[b + Int(CPU_STATE_NICE)]), idle = Double(info[b + Int(CPU_STATE_IDLE)])
    busy += user + sys + nice
    total += user + sys + nice + idle
  }
  return (busy, total)
}

func children(of pid: pid_t) -> [pid_t] {
  var kids = [pid_t](repeating: 0, count: 256)
  let n = proc_listchildpids(pid, &kids, Int32(kids.count * MemoryLayout<pid_t>.size))
  return Array(kids.prefix(Int(max(n, 0))))
}

func isGPUProcess(_ pid: pid_t) -> Bool {
  var mib = [CTL_KERN, KERN_PROCARGS2, pid]
  var len = 0
  guard sysctl(&mib, 3, nil, &len, nil, 0) == 0, len > 0 else { return false }
  var buf = [CChar](repeating: 0, count: len)
  guard sysctl(&mib, 3, &buf, &len, nil, 0) == 0 else { return false }
  return String(decoding: buf.map { UInt8(bitPattern: $0 == 0 ? 10 : $0) }, as: UTF8.self)
    .split(separator: "\n").contains("--type=gpu-process")
}

let engineKids = children(of: engine)
let gpuProcess = engineKids.first(where: isGPUProcess) ?? -1
let windowServer: pid_t = {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
  p.arguments = ["-x", "WindowServer"]
  let pipe = Pipe()
  p.standardOutput = pipe
  try? p.run()
  p.waitUntilExit()
  return pid_t(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
}()

var lines = [#"{"name":"process_name","ph":"M","pid":2,"args":{"name":"Mac load (sysmon)"}}"#]
var prevT = nowUs(), prevGPU = gpuTimes(), prevMachine = machineTicks()
var prevCPU = Dictionary(uniqueKeysWithValues: ([engine, rex] + engineKids).map { ($0, cpuUs($0)) })
setvbuf(stdout, nil, _IOLBF, 0)
let stream = args[2] == "-"
if stream { print(lines[0]) }
let end = secs > 0 ? prevT + secs * 1e6 : .infinity
while nowUs() < end {
  usleep(50_000)
  let t = nowUs(), gpu = gpuTimes(), machine = machineTicks()
  let wall = (t - prevT) * 1000  // ns, like the GPU times
  func gpuPct(_ pids: [pid_t]) -> Double {
    pids.reduce(0) { $0 + (gpu[$1, default: 0] - prevGPU[$1, default: 0]) } / wall * 100
  }
  let named = [gpuProcess, windowServer, rex]
  let others = gpu.keys.filter { !named.contains($0) }
  let gpuLine: [String: Double] = [
    "Chromium GPU process": gpuPct([gpuProcess]), "WindowServer": gpuPct([windowServer]),
    "Rex client": gpuPct([rex]), "other apps": gpuPct(others),
  ]
  let kids = children(of: engine)
  var cpuNow: [pid_t: Double] = [:]
  for p in [engine, rex] + kids { cpuNow[p] = cpuUs(p) }
  func cpuPct(_ pids: [pid_t]) -> Double {
    pids.reduce(0) { $0 + max(0, cpuNow[$1, default: 0] - prevCPU[$1, default: cpuNow[$1, default: 0]]) } / (t - prevT) * 100
  }
  let dTotal = machine.total - prevMachine.total
  let cpuLine: [String: Double] = [
    "engine (all processes)": cpuPct([engine] + kids), "Rex client": cpuPct([rex]),
    "whole Mac, % of all cores": dTotal > 0 ? (machine.busy - prevMachine.busy) / dTotal * 100 : 0,
  ]
  for (name, values) in [("GPU busy %", gpuLine), ("CPU %", cpuLine)] {
    let data = try! JSONSerialization.data(withJSONObject: [
      "name": name, "ph": "C", "pid": 2, "tid": 1, "ts": prevT, "args": values.mapValues { ($0 * 10).rounded() / 10 },
    ])
    let line = String(decoding: data, as: UTF8.self)
    if stream { print(line) } else { lines.append(line) }
  }
  prevT = t
  prevGPU = gpu
  prevMachine = machine
  prevCPU = cpuNow
}
if !stream { try lines.joined(separator: "\n").appending("\n").write(toFile: args[2], atomically: true, encoding: .utf8) }
