// A minimal AppKit host: mounts a bowser surface in a window and forwards
// input, including IME text, through NSTextInputClient.
//
// Usage: bowser-host <ticket>
import AppKit

final class SurfaceView: NSView, NSTextInputClient {
  var host: OpaquePointer?
  var caret = bowser_rect_s()
  var compositionRects: [bowser_rect_s] = []
  var marked = NSAttributedString()
  var cursor = NSCursor.arrow

  override var acceptsFirstResponder: Bool { true }
  override var wantsUpdateLayer: Bool { true }

  func mount(_ host: OpaquePointer) {
    self.host = host
    wantsLayer = true
    layer?.addSublayer(bowser_host_layer(host))
    addTrackingArea(NSTrackingArea(
      rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self))
    needsLayout = true
  }

  override func layout() {
    super.layout()
    guard let host else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    bowser_host_layer(host).frame = bounds
    CATransaction.commit()
    let scale = window?.backingScaleFactor ?? 2
    bowser_host_resize(host, bowser_size_s(width: bounds.width, height: bounds.height, scale: scale))
  }

  // NSEvent.timestamp and bowser timestamps share a clock: CLOCK_UPTIME_RAW.
  func nanos(_ event: NSEvent) -> UInt64 { UInt64(event.timestamp * 1e9) }

  // AppKit views have a bottom-left origin; bowser uses top-left.
  func point(_ event: NSEvent) -> NSPoint {
    let p = convert(event.locationInWindow, from: nil)
    return NSPoint(x: p.x, y: bounds.height - p.y)
  }

  func mouse(_ event: NSEvent, _ action: bowser_mouse_action_e, _ button: Int32) {
    guard let host else { return }
    let p = point(event)
    let clicks = Int32(event.type == .mouseMoved ? 0 : event.clickCount)
    var m = bowser_mouse_s(
      action: action, button: button, x: p.x, y: p.y, click_count: clicks,
      mods: UInt64(event.modifierFlags.rawValue), timestamp_ns: nanos(event))
    bowser_host_mouse(host, &m)
  }

  override func mouseDown(with e: NSEvent) {
    window?.makeFirstResponder(self)
    mouse(e, BOWSER_MOUSE_DOWN, 0)
  }
  override func mouseUp(with e: NSEvent) { mouse(e, BOWSER_MOUSE_UP, 0) }
  override func mouseDragged(with e: NSEvent) { mouse(e, BOWSER_MOUSE_DRAG, 0) }
  override func mouseMoved(with e: NSEvent) {
    mouse(e, BOWSER_MOUSE_MOVE, 0)
    cursor.set()
  }
  override func mouseExited(with e: NSEvent) { mouse(e, BOWSER_MOUSE_EXIT, 0) }
  override func rightMouseDown(with e: NSEvent) { mouse(e, BOWSER_MOUSE_DOWN, 1) }
  override func rightMouseUp(with e: NSEvent) { mouse(e, BOWSER_MOUSE_UP, 1) }

  override func scrollWheel(with e: NSEvent) {
    guard let host else { return }
    let p = point(e)
    var s = bowser_scroll_s(
      dx: e.scrollingDeltaX, dy: e.scrollingDeltaY, precise: e.hasPreciseScrollingDeltas,
      phase: Int32(e.phase.rawValue), momentum_phase: Int32(e.momentumPhase.rawValue),
      x: p.x, y: p.y, mods: UInt64(e.modifierFlags.rawValue), timestamp_ns: nanos(e))
    bowser_host_scroll(host, &s)
  }

  func key(_ e: NSEvent, _ action: bowser_key_action_e) {
    guard let host else { return }
    let text = e.characters ?? ""
    let unmodified = e.charactersIgnoringModifiers ?? ""
    text.withCString { t in
      unmodified.withCString { u in
        var k = bowser_key_s(
          action: action, keycode: e.keyCode, mods: UInt64(e.modifierFlags.rawValue),
          text: t, unmodified_text: u, timestamp_ns: nanos(e))
        bowser_host_key(host, &k)
      }
    }
  }

  override func keyDown(with e: NSEvent) {
    key(e, e.isARepeat ? BOWSER_KEY_REPEAT : BOWSER_KEY_PRESS)
    // Text, including IME composition, arrives through NSTextInputClient.
    inputContext?.handleEvent(e)
  }
  override func keyUp(with e: NSEvent) { key(e, BOWSER_KEY_RELEASE) }
  override func doCommand(by selector: Selector) {}  // keys reach the producer as key events

  override func becomeFirstResponder() -> Bool {
    if let host { bowser_host_focus(host, true) }
    return true
  }
  override func resignFirstResponder() -> Bool {
    if let host { bowser_host_focus(host, false) }
    return true
  }

  // MARK: NSTextInputClient

  func sendText(_ kind: bowser_text_kind_e, _ string: Any?, selected: NSRange, replacement: NSRange) {
    guard let host else { return }
    let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    func loc(_ r: NSRange) -> Int64 { r.location == NSNotFound ? -1 : Int64(r.location) }
    s.withCString { c in
      var t = bowser_text_s(
        kind: kind, text: c,
        selected_location: loc(selected), selected_length: Int64(selected.length),
        replacement_location: loc(replacement), replacement_length: Int64(replacement.length))
      bowser_host_text(host, &t)
    }
  }

  func insertText(_ string: Any, replacementRange: NSRange) {
    marked = NSAttributedString()
    sendText(BOWSER_TEXT_INSERT, string, selected: NSRange(location: NSNotFound, length: 0),
             replacement: replacementRange)
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    marked = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
    sendText(BOWSER_TEXT_SET_MARKED, string, selected: selectedRange, replacement: replacementRange)
  }

  func unmarkText() {
    marked = NSAttributedString()
    sendText(BOWSER_TEXT_UNMARK, nil, selected: NSRange(location: NSNotFound, length: 0),
             replacement: NSRange(location: NSNotFound, length: 0))
  }

  func hasMarkedText() -> Bool { marked.length > 0 }
  func markedRange() -> NSRange {
    marked.length > 0 ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0)
  }
  func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle] }
  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
  func characterIndex(for point: NSPoint) -> Int { NSNotFound }

  // Where the IME candidate window goes: the producer's latest rects.
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    let r = compositionRects.first ?? caret
    let local = NSRect(x: r.x, y: bounds.height - r.y - r.height, width: max(r.width, 1), height: r.height)
    guard let window else { return .zero }
    return window.convertToScreen(convert(local, to: nil))
  }
}

// Private CGS calls to place the window on a Mission Control Space, so test
// windows stay off the Spaces you work in. Set BOWSER_SPACE=<1-based index>.
@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray
@_silgen_name("CGSAddWindowsToSpaces") func CGSAddWindowsToSpaces(_ cid: Int32, _ windows: CFArray, _ spaces: CFArray)

func moveToSpace(_ window: NSWindow, index: Int) -> Bool {
  let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] ?? []
  let spaces = displays.flatMap { $0["Spaces"] as? [[String: Any]] ?? [] }
  guard index >= 1, index <= spaces.count, let id = spaces[index - 1]["ManagedSpaceID"] as? Int else { return false }
  CGSAddWindowsToSpaces(CGSMainConnectionID(), [window.windowNumber] as CFArray, [id] as CFArray)
  return true
}

final class App: NSObject, NSApplicationDelegate {
  let ticket: String
  var window: NSWindow!
  var view: SurfaceView!
  var host: OpaquePointer?

  init(ticket: String) { self.ticket = ticket }

  func applicationDidFinishLaunching(_ n: Notification) {
    view = SurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    window = NSWindow(
      contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered, defer: false)
    window.title = "bowser host"
    window.contentView = view
    window.center()

    var cfg = bowser_host_config_s()
    cfg.size = MemoryLayout<bowser_host_config_s>.size
    cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
    cfg.wakeup_cb = { ud in
      let app = Unmanaged<App>.fromOpaque(ud!).takeUnretainedValue()
      DispatchQueue.main.async { if let h = app.host { bowser_host_tick(h) } }
    }
    cfg.caret_cb = { ud, _, caret in App.from(ud).view.caret = caret }
    cfg.composition_cb = { ud, _, active, rects, count in
      App.from(ud).view.compositionRects = active ? Array(UnsafeBufferPointer(start: rects, count: count)) : []
    }
    cfg.cursor_cb = { ud, _, c in
      let cursor: NSCursor
      switch c {
      case BOWSER_CURSOR_IBEAM: cursor = .iBeam
      case BOWSER_CURSOR_POINTER: cursor = .pointingHand
      case BOWSER_CURSOR_CROSSHAIR: cursor = .crosshair
      case BOWSER_CURSOR_NOT_ALLOWED: cursor = .operationNotAllowed
      case BOWSER_CURSOR_RESIZE_LEFT_RIGHT: cursor = .resizeLeftRight
      case BOWSER_CURSOR_RESIZE_UP_DOWN: cursor = .resizeUpDown
      default: cursor = .arrow
      }
      App.from(ud).view.cursor = cursor
      cursor.set()
    }
    cfg.detached_cb = { ud, _, why in
      let app = App.from(ud)
      print("detached: \(why.rawValue)")
      app.window.title = "bowser host (detached)"
    }

    var h: OpaquePointer?
    let rc = bowser_host_attach(ticket, &cfg, &h)
    guard rc == BOWSER_OK, let h else {
      print("attach failed: \(String(cString: bowser_last_error()))")
      exit(1)
    }
    host = h
    let transport = bowser_host_transport(h) == BOWSER_TRANSPORT_CALAYERHOST ? "calayerhost" : "iosurface"
    window.title = "bowser host (\(transport))"
    view.mount(h)
    window.makeFirstResponder(view)
    if let space = ProcessInfo.processInfo.environment["BOWSER_SPACE"].flatMap(Int.init) {
      // Don't activate: that would switch the user to the window's Space.
      if !moveToSpace(window, index: space) { print("no Space \(space)") }
      window.orderFrontRegardless()
    } else {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
    print("window=\(window.windowNumber)")
    fflush(stdout)
  }

  static func from(_ ud: UnsafeMutableRawPointer?) -> App {
    Unmanaged<App>.fromOpaque(ud!).takeUnretainedValue()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

guard CommandLine.arguments.count > 1 else {
  print("usage: bowser-host <ticket>")
  exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = App(ticket: CommandLine.arguments[1])
app.delegate = delegate
app.run()
