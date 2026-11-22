// Mounts libbowser surfaces inside Rex panes.
//
// Rex shows a block it can't render as an "Unsupported block" placeholder: a
// NativePaneView whose content area is a SwiftUI NSHostingView. For panes whose
// block comes from the `dev.libbowser` creator, this puts a BowserPaneView over
// that content area, gets a ticket from the block, and attaches.
//
// This is the client half of the integration. A first-party Rex client would
// do the same with a real renderer for the flavor instead of a swizzle.
import AppKit
import ObjectiveC

private let creatorName = ProcessInfo.processInfo.environment["BOWSER_REX_CREATOR"] ?? "dev.libbowser"
private let paneClassName = "_TtCE8RexMacOSO9RexShared9Workspace14NativePaneView"
private let flippedClassName = "_TtCE8RexMacOSO9RexShared9Workspace21NativePaneFlippedView"

// MARK: - Reading Rex's pane model

struct PaneBlock: Equatable {
  var blockID: String
  var creator: String?
  var flavor: String?
}

/// Follow stored properties by name through Swift values.
private func child(_ value: Any, _ path: [String]) -> Any? {
  var current: Any = value
  for name in path {
    var found: Any?
    var mirror: Mirror? = Mirror(reflecting: current)
    while found == nil, let m = mirror {
      found = m.children.first { $0.label == name }?.value
      mirror = m.superclassMirror
    }
    guard var next = found else { return nil }
    // Look through optionals.
    let m = Mirror(reflecting: next)
    if m.displayStyle == .optional {
      guard let some = m.children.first?.value else { return nil }
      next = some
    }
    current = next
  }
  return current
}

/// The block shown in a NativePaneView, from `cell.context.pane.block`.
func paneBlock(_ pane: NSView) -> PaneBlock? {
  guard let block = child(pane, ["cell", "context", "pane", "block"]),
    let id = child(block, ["blockID", "rawValue"]) as? String
  else { return nil }
  return PaneBlock(
    blockID: id, creator: child(block, ["creatorName"]) as? String, flavor: child(block, ["flavor"]) as? String)
}

// MARK: - Ticket from the block

/// Ask the block for a fresh ticket through the Rex CLI (`ticket` is a method
/// of the dev.libbowser plugin, rex/plugin). REX_SERVER in this
/// process already names the right server.
func fetchTicket(blockID: String, completion: @escaping (String?) -> Void) {
  let env = ProcessInfo.processInfo.environment
  // Dev hook: a fixed ticket, to test mounting without the server plugin.
  if let fixed = env["BOWSER_REX_TICKET"] { return DispatchQueue.main.async { completion(fixed) } }
  let cli = env["BOWSER_REX_CLI"] ?? "/usr/local/bin/rex"
  let method = env["BOWSER_REX_TICKET_METHOD"] ?? "ticket"
  DispatchQueue.global(qos: .userInitiated).async {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cli)
    p.arguments = ["--autostart=false", "block", "call", "-b", blockID, method]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch {
      rexTrace("ticket: can't run \(cli): \(error)")
      return DispatchQueue.main.async { completion(nil) }
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    // The reply's shape belongs to the plugin; take the first ticket-looking string.
    let ticket = findTicket(try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    if ticket == nil { rexTrace("ticket: none in \(String(decoding: data, as: UTF8.self).prefix(200))") }
    DispatchQueue.main.async { completion(ticket) }
  }
}

private func findTicket(_ json: Any?) -> String? {
  switch json {
  // Any wire version: "bowser<N>:". The version check belongs to libbowser.
  case let s as String: return s.range(of: #"^bowser[0-9]+:"#, options: .regularExpression) != nil ? s : nil
  case let d as [String: Any]: return d.values.lazy.compactMap(findTicket).first
  case let a as [Any]: return a.lazy.compactMap(findTicket).first
  default: return nil
  }
}

// MARK: - The pane view

final class BowserPaneView: NSView, NSTextInputClient {
  let blockID: String
  private var host: OpaquePointer?
  private var attaching = false
  private var caret = bowser_rect_s()
  private var compositionRects: [bowser_rect_s] = []
  private var marked = NSAttributedString()
  private var cursor = NSCursor.arrow

  init(blockID: String) {
    self.blockID = blockID
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    addTrackingArea(NSTrackingArea(
      rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self))
  }
  required init?(coder: NSCoder) { fatalError() }

  override var acceptsFirstResponder: Bool { true }
  override var isFlipped: Bool { true }

  // MARK: Attach and detach follow the window

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { detach() } else { attach() }
  }

  private func attach() {
    guard host == nil, !attaching else { return }
    attaching = true
    requestTicket(attempt: 0)
  }

  /// A producer that is still starting has no ticket yet (CEF takes about a
  /// second), so retry with backoff for up to ~15 s.
  private func requestTicket(attempt: Int) {
    fetchTicket(blockID: blockID) { [weak self] ticket in
      guard let self else { return }
      guard self.window != nil, self.host == nil else { self.attaching = false; return }
      guard let ticket else {
        guard attempt < 12 else { self.attaching = false; return rexTrace("block \(self.blockID): no ticket, giving up") }
        let delay = min(0.1 * pow(2, Double(attempt)), 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.requestTicket(attempt: attempt + 1) }
        return
      }
      self.attaching = false
      var cfg = bowser_host_config_s()
      cfg.size = MemoryLayout<bowser_host_config_s>.size
      cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
      cfg.wakeup_cb = { ud in
        let view = Unmanaged<BowserPaneView>.fromOpaque(ud!).takeUnretainedValue()
        DispatchQueue.main.async { if let h = view.host { bowser_host_tick(h) } }
      }
      cfg.caret_cb = { ud, _, r in BowserPaneView.from(ud).caret = r }
      cfg.composition_cb = { ud, _, active, rects, n in
        BowserPaneView.from(ud).compositionRects = active ? Array(UnsafeBufferPointer(start: rects, count: n)) : []
      }
      cfg.cursor_cb = { ud, _, c in BowserPaneView.from(ud).setCursor(c) }
      cfg.detached_cb = { ud, _, why in
        let view = BowserPaneView.from(ud)
        rexTrace("block \(view.blockID): detached (\(why.rawValue))")
        view.detach()
      }
      var h: OpaquePointer?
      guard bowser_host_attach(ticket, &cfg, &h) == BOWSER_OK, let h else {
        rexTrace("block \(self.blockID): attach failed: \(String(cString: bowser_last_error()))")
        return
      }
      self.host = h
      self.layer?.addSublayer(bowser_host_layer(h))
      self.needsLayout = true
      rexTrace("block \(self.blockID): attached")
    }
  }

  func detach() {
    guard let h = host else { return }
    host = nil
    bowser_host_detach(h)
  }

  static func from(_ ud: UnsafeMutableRawPointer?) -> BowserPaneView {
    Unmanaged<BowserPaneView>.fromOpaque(ud!).takeUnretainedValue()
  }

  override func layout() {
    super.layout()
    guard let host else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    bowser_host_layer(host).frame = bounds
    CATransaction.commit()
    bowser_host_resize(host, bowser_size_s(width: bounds.width, height: bounds.height,
                                           scale: Double(window?.backingScaleFactor ?? 2)))
  }

  private func setCursor(_ c: bowser_cursor_e) {
    switch c {
    case BOWSER_CURSOR_IBEAM: cursor = .iBeam
    case BOWSER_CURSOR_POINTER: cursor = .pointingHand
    case BOWSER_CURSOR_CROSSHAIR: cursor = .crosshair
    case BOWSER_CURSOR_NOT_ALLOWED: cursor = .operationNotAllowed
    case BOWSER_CURSOR_RESIZE_LEFT_RIGHT: cursor = .resizeLeftRight
    case BOWSER_CURSOR_RESIZE_UP_DOWN: cursor = .resizeUpDown
    default: cursor = .arrow
    }
    cursor.set()
  }

  // MARK: Mouse

  // NSEvent.timestamp and bowser timestamps share a clock: CLOCK_UPTIME_RAW.
  private func nanos(_ e: NSEvent) -> UInt64 { UInt64(e.timestamp * 1e9) }

  private func mouse(_ e: NSEvent, _ action: bowser_mouse_action_e, _ button: Int32) {
    guard let host else { return }
    let p = convert(e.locationInWindow, from: nil)  // flipped: already top-left
    var m = bowser_mouse_s(
      action: action, button: button, x: p.x, y: p.y,
      click_count: Int32(e.type == .mouseMoved ? 0 : e.clickCount), mods: UInt64(e.modifierFlags.rawValue),
      timestamp_ns: nanos(e))
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
    let p = convert(e.locationInWindow, from: nil)
    var s = bowser_scroll_s(
      dx: e.scrollingDeltaX, dy: e.scrollingDeltaY, precise: e.hasPreciseScrollingDeltas,
      phase: Int32(e.phase.rawValue), momentum_phase: Int32(e.momentumPhase.rawValue),
      x: p.x, y: p.y, mods: UInt64(e.modifierFlags.rawValue), timestamp_ns: nanos(e))
    bowser_host_scroll(host, &s)
  }

  // MARK: Keys

  override func keyDown(with e: NSEvent) {
    // Command shortcuts belong to Rex.
    if e.modifierFlags.contains(.command) { return super.keyDown(with: e) }
    key(e, e.isARepeat ? BOWSER_KEY_REPEAT : BOWSER_KEY_PRESS)
    inputContext?.handleEvent(e)
  }
  override func keyUp(with e: NSEvent) {
    if e.modifierFlags.contains(.command) { return super.keyUp(with: e) }
    key(e, BOWSER_KEY_RELEASE)
  }
  override func doCommand(by selector: Selector) {}

  private func key(_ e: NSEvent, _ action: bowser_key_action_e) {
    guard let host else { return }
    (e.characters ?? "").withCString { t in
      (e.charactersIgnoringModifiers ?? "").withCString { u in
        var k = bowser_key_s(
          action: action, keycode: e.keyCode, mods: UInt64(e.modifierFlags.rawValue), text: t, unmodified_text: u,
          timestamp_ns: nanos(e))
        bowser_host_key(host, &k)
      }
    }
  }

  override func becomeFirstResponder() -> Bool {
    if let host { bowser_host_focus(host, true) }
    return true
  }
  override func resignFirstResponder() -> Bool {
    if let host { bowser_host_focus(host, false) }
    return true
  }

  // MARK: NSTextInputClient

  private func sendText(_ kind: bowser_text_kind_e, _ string: Any?, selected: NSRange, replacement: NSRange) {
    guard let host else { return }
    let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    func loc(_ r: NSRange) -> Int64 { r.location == NSNotFound ? -1 : Int64(r.location) }
    s.withCString { c in
      var t = bowser_text_s(
        kind: kind, text: c, selected_location: loc(selected), selected_length: Int64(selected.length),
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
    let none = NSRange(location: NSNotFound, length: 0)
    sendText(BOWSER_TEXT_UNMARK, nil, selected: none, replacement: none)
  }
  func hasMarkedText() -> Bool { marked.length > 0 }
  func markedRange() -> NSRange {
    marked.length > 0 ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0)
  }
  func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle] }
  func attributedSubstring(forProposedRange r: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
  func characterIndex(for point: NSPoint) -> Int { NSNotFound }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    let r = compositionRects.first ?? caret
    let local = NSRect(x: r.x, y: r.y, width: max(r.width, 1), height: r.height)  // flipped view
    guard let window else { return .zero }
    return window.convertToScreen(convert(local, to: nil))
  }
}

// MARK: - Mounting into panes

private var mountKey: UInt8 = 0

/// Called after every NativePaneView layout.
func reconcilePane(_ pane: NSView) {
  let mounted = objc_getAssociatedObject(pane, &mountKey) as? BowserPaneView
  let block = paneBlock(pane)
  let wanted = block?.creator == creatorName ? block : nil

  // Rex reuses pane views: drop a mount that no longer matches the block.
  if let mounted, mounted.blockID != wanted?.blockID {
    mounted.removeFromSuperview()
    objc_setAssociatedObject(pane, &mountKey, nil, .OBJC_ASSOCIATION_RETAIN)
  }
  guard let wanted else { return }

  // The content area is the placeholder's NSHostingView inside the flipped view.
  guard let flipped = pane.subviews.first(where: { NSStringFromClass(type(of: $0)) == flippedClassName }),
    let content = flipped.subviews.first(where: { NSStringFromClass(type(of: $0)).contains("NSHostingView") })
  else { return }

  let view: BowserPaneView
  if let existing = objc_getAssociatedObject(pane, &mountKey) as? BowserPaneView {
    view = existing
  } else {
    view = BowserPaneView(blockID: wanted.blockID)
    objc_setAssociatedObject(pane, &mountKey, view, .OBJC_ASSOCIATION_RETAIN)
    rexTrace("block \(wanted.blockID): mounting (\(wanted.flavor ?? "?"))")
  }
  if view.superview !== flipped {
    flipped.addSubview(view, positioned: .above, relativeTo: content)
  }
  content.isHidden = true
  if view.frame != content.frame { view.frame = content.frame }
}

private var originalLayout: IMP?

/// Hook NativePaneView.layout. Adds the override to that class only, so
/// NSView.layout stays untouched for every other view.
@_cdecl("rex_bowser_install")
public func rexBowserInstall() {
  guard let cls = NSClassFromString(paneClassName) else {
    return rexTrace("no \(paneClassName); Rex changed")
  }
  let sel = #selector(NSView.layout)
  let block: @convention(block) (NSView) -> Void = { pane in
    if let originalLayout {
      typealias Fn = @convention(c) (NSView, Selector) -> Void
      unsafeBitCast(originalLayout, to: Fn.self)(pane, sel)
    }
    reconcilePane(pane)
  }
  let imp = imp_implementationWithBlock(block)
  let inherited = class_getInstanceMethod(cls, sel)!
  if class_addMethod(cls, sel, imp, method_getTypeEncoding(inherited)) {
    originalLayout = method_getImplementation(inherited)  // NSView's (or a superclass's)
  } else {
    originalLayout = method_setImplementation(class_getInstanceMethod(cls, sel)!, imp)
  }
  rexTrace("installed on \(paneClassName)")
}

func rexTrace(_ s: String) {
  guard let path = ProcessInfo.processInfo.environment["BOWSER_REX_TRACE"],
    let f = fopen(path, "a")
  else { return }
  fputs(s + "\n", f)
  fclose(f)
}
