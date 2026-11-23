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

/// Rex's own "focus this pane" action, as its header uses it.
func paneFocusAction(_ pane: NSView) -> (() -> Void)? {
  child(pane, ["cell", "state", "headerActions", "onFocus"]) as? () -> Void
}

/// Whether Rex considers `blockID` the focused block of the pane's window.
func paneIsFocused(_ pane: NSView, blockID: String) -> Bool {
  (child(pane, ["cell", "window", "focusedBlockID", "rawValue"]) as? String) == blockID
}

// MARK: - Ticket from the block

/// Ask the block for a fresh ticket through the Rex CLI (`ticket` is a method
/// of the dev.libbowser plugin, rex/plugin). REX_SERVER in this
/// process already names the right server.
///
/// With `now`, a ticket the plugin has ready comes back before this returns,
/// so the pane attaches in the same main-thread turn that mounts it: Rex lays
/// out its window for 100 ms or more right after a pane appears, and an
/// attach that waits for the main thread waits for that.
func fetchTicket(blockID: String, now: Bool = false, completion: @escaping (String?) -> Void) {
  let env = ProcessInfo.processInfo.environment
  // Dev hook: a fixed ticket, to test mounting without the server plugin.
  if let fixed = env["BOWSER_REX_TICKET"] { return DispatchQueue.main.async { completion(fixed) } }
  if let path = env["BOWSER_REX_TICKETS"] {
    if now, let ticket = askTicketSocket(path, blockID: blockID, waitMs: 20) {
      return completion(ticket)
    }
    return DispatchQueue.global(qos: .userInteractive).async {
      let ticket = askTicketSocket(path, blockID: blockID, waitMs: 5000)
      DispatchQueue.main.async { completion(ticket) }
    }
  }
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

/// The plugin's ticket socket (rex/plugin/tickets.go): about 1 ms, where the
/// CLI takes about 25.
private func askTicketSocket(_ path: String, blockID: String, waitMs: Int) -> String? {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { return nil }
  defer { close(fd) }
  var limit = timeval(tv_sec: waitMs / 1000, tv_usec: Int32(waitMs % 1000 * 1000))
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  let max = MemoryLayout.size(ofValue: addr.sun_path)
  guard path.utf8.count < max else { return nil }
  withUnsafeMutableBytes(of: &addr.sun_path) { buf in
    buf.copyBytes(from: path.utf8)
    buf[path.utf8.count] = 0
  }
  let ok = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
  }
  guard ok == 0 else {
    rexTrace("ticket: can't connect to \(path): \(String(cString: strerror(errno)))")
    return nil
  }
  let line = Array((blockID + "\n").utf8)
  guard write(fd, line, line.count) == line.count else { return nil }
  var reply = [UInt8]()
  var chunk = [UInt8](repeating: 0, count: 512)
  while !reply.contains(UInt8(ascii: "\n")) {
    let n = read(fd, &chunk, chunk.count)
    if n <= 0 { break }
    reply += chunk[0..<n]
  }
  let ticket = findTicket(try? JSONSerialization.jsonObject(with: Data(reply)))
  if ticket == nil { rexTrace("ticket: none in \(String(decoding: reply, as: UTF8.self).prefix(200))") }
  return ticket
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
  weak var pane: NSView?
  private var host: OpaquePointer?
  private var attaching = false
  private var caret = bowser_rect_s()
  private var compositionRects: [bowser_rect_s] = []
  private var marked = NSAttributedString()
  private var cursor = NSCursor.arrow

  private(set) var state = BrowserState()
  // The chrome is made on first use: building it (an NSSearchField, effect
  // views) costs more than the rest of mounting a pane.
  private var addressBarIfMade: AddressBar?
  private var findBarIfMade: FindBar?
  private var progressLineIfMade: ProgressLine?
  private var addressBar: AddressBar {
    if let b = addressBarIfMade { return b }
    let b = AddressBar(send: { [weak self] in self?.send($0, $1) })
    b.onDismiss = { [weak self, weak b] in self?.dismiss(b) }
    addressBarIfMade = b
    addBar(b)
    return b
  }
  private var findBar: FindBar {
    if let b = findBarIfMade { return b }
    let b = FindBar(send: { [weak self] in self?.send($0, $1) })
    b.onDismiss = { [weak self, weak b] in self?.dismiss(b) }
    findBarIfMade = b
    addBar(b)
    return b
  }
  private var progressLine: ProgressLine {
    if let l = progressLineIfMade { return l }
    let l = ProgressLine()
    progressLineIfMade = l
    addSubview(l)
    layoutChrome()
    return l
  }
  private func addBar(_ bar: NSView) {
    bar.isHidden = true
    addSubview(bar)
    layoutChrome()
  }

  init(blockID: String) {
    self.blockID = blockID
    super.init(frame: .zero)
    wantsLayer = true
    addTrackingArea(NSTrackingArea(
      rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self))
  }
  required init?(coder: NSCoder) { fatalError() }

  override var acceptsFirstResponder: Bool { true }
  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }

  // Shows only where no frame covers yet, such as the strip a growing pane
  // reveals for a frame. Most pages draw on the system text background.
  override func updateLayer() { layer?.backgroundColor = NSColor.textBackgroundColor.cgColor }

  // MARK: Attach and detach follow the window

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
    if let window {
      NotificationCenter.default.addObserver(
        self, selector: #selector(screenChanged), name: NSWindow.didChangeScreenNotification, object: window)
      attach()
    } else {
      detach()
    }
  }

  /// The engine puts its hidden window on this display, so the page renders
  /// at its scale and refresh rate.
  @objc private func screenChanged() {
    guard let host, let number = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else { return }
    bowser_host_set_display(host, number.uint32Value)
  }

  private func attach() {
    guard host == nil, !attaching else { return }
    attaching = true
    requestTicket(attempt: 0)
  }

  /// A producer that is still starting has no ticket yet (CEF takes about a
  /// second), so retry with backoff for up to ~15 s.
  private func requestTicket(attempt: Int) {
    fetchTicket(blockID: blockID, now: attempt == 0) { [weak self] ticket in
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
      cfg.message_cb = { ud, _, name, body in
        // Copy now: the strings are only valid during the callback.
        BowserPaneView.from(ud).receive(String(cString: name!), body.map { String(cString: $0) })
      }
      cfg.detached_cb = { ud, _, why in
        let view = BowserPaneView.from(ud)
        rexTrace("block \(view.blockID): detached (\(why.rawValue))")
        view.detach()
      }
      var h: OpaquePointer?
      let attachStart = Perf.now()
      let rc = bowser_host_attach(ticket, &cfg, &h)
      Perf.slice("bowser_host_attach", from: attachStart)
      guard rc == BOWSER_OK, let h else {
        rexTrace("block \(self.blockID): attach failed: \(String(cString: bowser_last_error()))")
        // A used or expired ticket: ask the block for a fresh one.
        if rc == BOWSER_ERR_TICKET, attempt < 12 {
          self.attaching = true
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.requestTicket(attempt: attempt + 1) }
        }
        return
      }
      self.host = h
      self.sentSize = nil
      self.screenChanged()
      CATransaction.begin()
      // Runs once the window's transaction with the page in it is committed
      // to the render server: when the page can first be on screen.
      CATransaction.setCompletionBlock { [blockID = self.blockID] in rexTrace("block \(blockID): committed") }
      self.layer?.addSublayer(bowser_host_layer(h))
      CATransaction.commit()
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

  private var sentSize: bowser_size_s?

  override func layout() {
    super.layout()
    layoutChrome()
    guard let host else { return }
    let size = bowser_size_s(width: bounds.width, height: bounds.height, scale: Double(window?.backingScaleFactor ?? 2))
    // Rex lays panes out often; only a real change reaches the engine, where a
    // resize means a page relayout.
    if let s = sentSize, s.width == size.width, s.height == size.height, s.scale == size.scale { return }
    sentSize = size
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    bowser_host_layer(host).frame = bounds
    CATransaction.commit()
    bowser_host_resize(host, size)
  }


  // MARK: Chrome

  private func layoutChrome() {
    let inset: CGFloat = 8, height: CGFloat = 34
    progressLineIfMade?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 2)
    let addressWidth = min(bounds.width - 2 * inset, 720)
    addressBarIfMade?.frame = NSRect(x: (bounds.width - addressWidth) / 2, y: inset, width: addressWidth, height: height)
    let findWidth = min(bounds.width - 2 * inset, 380)
    findBarIfMade?.frame = NSRect(x: bounds.width - findWidth - inset, y: inset, width: findWidth, height: height)
  }

  private func send(_ name: String, _ body: [String: Any]?) {
    guard let host else { return }
    var json: String?
    if let body, let data = try? JSONSerialization.data(withJSONObject: body) {
      json = String(data: data, encoding: .utf8)
    }
    let rc = bowser_host_send(host, name, json)
    rexTrace("send \(name) \(json ?? "") -> \(rc.rawValue)")
  }

  fileprivate func receive(_ name: String, _ body: String?) {
    switch name {
    case "state":
      guard let s = BrowserState(json: body) else { return }
      state = s
      addressBarIfMade?.update(s)
      if s.loading || progressLineIfMade != nil { progressLine.update(loading: s.loading, progress: s.progress) }
    case "menu":
      showMenu(body)
    case "find_result":
      guard let data = body?.data(using: .utf8),
        let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return }
      findBarIfMade?.update(count: o["count"] as? Int ?? 0, active: o["active"] as? Int ?? 0)
    default:
      break
    }
  }


  // MARK: Native menus

  private var pickedMenuIndex = -1

  /// The engine's `menu` message (a `<select>` list or a context menu) as a
  /// real NSMenu in this process. Items are numbered depth-first, separators
  /// included, as adapters/cef/README.md specifies; the pick goes back in
  /// `menu_result`.
  private func showMenu(_ body: String?) {
    guard let data = body?.data(using: .utf8),
      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let id = o["id"] as? Int, let items = o["items"] as? [[String: Any]]
    else { return }
    let menu = NSMenu()
    menu.autoenablesItems = false
    var next = 0
    func build(_ items: [[String: Any]], into m: NSMenu) {
      for item in items {
        let index = next
        next += 1
        if item["separator"] as? Bool == true {
          m.addItem(.separator())
          continue
        }
        let mi = NSMenuItem(title: item["label"] as? String ?? "", action: #selector(pickMenuItem(_:)), keyEquivalent: "")
        mi.target = self
        mi.tag = index
        mi.isEnabled = item["enabled"] as? Bool ?? true
        mi.state = item["checked"] as? Bool == true ? .on : .off
        if let children = item["children"] as? [[String: Any]], !children.isEmpty {
          let sub = NSMenu()
          sub.autoenablesItems = false
          build(children, into: sub)
          mi.submenu = sub
          mi.action = nil
        }
        m.addItem(mi)
      }
    }
    build(items, into: menu)
    let at = NSPoint(x: o["x"] as? Double ?? 0, y: o["y"] as? Double ?? 0)  // flipped view: top-left, like the engine
    // A <select> opens with its current item over the control, as native pop-up buttons do.
    let selected = o["selected"] as? Int ?? -1
    let positioning = o["kind"] as? String == "select" && selected >= 0 ? menu.item(withTag: selected) : nil
    pickedMenuIndex = -1
    menu.popUp(positioning: positioning, at: at, in: self)  // returns when the menu closes
    send("menu_result", ["id": id, "index": pickedMenuIndex])
  }

  @objc private func pickMenuItem(_ item: NSMenuItem) { pickedMenuIndex = item.tag }

  private func show(_ bar: NSView) {
    bar.isHidden = false
    layoutChrome()
    if let a = bar as? AddressBar { a.update(state); a.focus() } else if let f = bar as? FindBar { f.focus() }
  }

  private func dismiss(_ bar: NSView?) {
    bar?.isHidden = true
    window?.makeFirstResponder(self)
  }

  /// Browser keys while the page or its chrome has the keyboard. Called from
  /// the NSApplication.sendEvent hook, before Rex sees the key: Rex consumes
  /// its menu shortcuts (⌘A, ⌘F, ⌘R, …) before the views' key-equivalent pass.
  /// Rex keeps every other ⌘ key, including ⌘[ and ⌘] for pane focus.
  func handleBrowserKey(_ e: NSEvent, in window: NSWindow) -> Bool {
    guard host != nil else { return false }
    let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
    let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
    // Edit keys go to the first responder: the page, or the field editor when
    // the address or find bar is being typed in, which then behaves natively.
    let edit: Selector? =
      switch (mods, key) {
      case ([.command], "a"): #selector(NSResponder.selectAll(_:))
      case ([.command], "c"): #selector(NSText.copy(_:))
      case ([.command], "x"): #selector(NSText.cut(_:))
      case ([.command], "v"): #selector(NSText.paste(_:))
      case ([.command], "z"): #selector(BowserPaneView.undo(_:))  // same "undo:" a text field answers
      case ([.command, .shift], "z"): #selector(BowserPaneView.redo(_:))
      default: nil
      }
    // Walk the responder chain of the window the key went to (not NSApp's key
    // window, which a background window isn't).
    if let edit { return window.firstResponder?.tryToPerform(edit, with: self) ?? false }
    switch (mods, key) {
    case ([.command], "l"): show(addressBar)
    case ([.command], "r"), ([.command, .shift], "r"): send("reload", nil)
    case ([.command], "f"): show(findBar)
    case ([.command], "g"): findBarIfMade?.findNext()
    case ([.command, .shift], "g"): findBarIfMade?.findPrevious()
    case ([.command], "="), ([.command], "+"), ([.command, .shift], "="), ([.command, .shift], "+"):
      send("zoom", ["delta": 1])
    case ([.command], "-"): send("zoom", ["delta": -1])
    case ([.command], "0"): send("zoom", ["delta": 0])
    default: return false
    }
    return true
  }

  // Rex's Edit menu sends these down the responder chain.
  @objc func copy(_ sender: Any?) { send("edit", ["command": "copy"]) }
  @objc func cut(_ sender: Any?) { send("edit", ["command": "cut"]) }
  @objc func paste(_ sender: Any?) { send("edit", ["command": "paste"]) }
  @objc override func selectAll(_ sender: Any?) { send("edit", ["command": "select_all"]) }
  @objc func undo(_ sender: Any?) { send("edit", ["command": "undo"]) }
  @objc func redo(_ sender: Any?) { send("edit", ["command": "redo"]) }
  @objc func delete(_ sender: Any?) { send("edit", ["command": "delete"]) }

  @objc func validateMenuItem(_ item: NSMenuItem) -> Bool { host != nil }

  override func otherMouseDown(with e: NSEvent) {
    switch e.buttonNumber {
    case 3: send("back", nil)
    case 4: send("forward", nil)
    default: super.otherMouseDown(with: e)
    }
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
    // Tell Rex first, the way its pane header does, so its focus and the
    // inactive-pane fade follow the click.
    if let pane, !paneIsFocused(pane, blockID: blockID) { paneFocusAction(pane)?() }
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

/// Called after every NativePaneView layout. Costs about 0.1 ms (measured
/// over 50 calls while resizing splits), so it can run on every layout.
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
    rexTrace("block \(wanted.blockID): mounting (\(wanted.flavor ?? "?")), focus action \(paneFocusAction(pane) != nil ? "found" : "missing")")
  }
  if view.superview !== flipped {
    flipped.addSubview(view, positioned: .above, relativeTo: content)
  }
  view.pane = pane
  content.isHidden = true
  if view.frame != content.frame { view.frame = content.frame }

  // Rex moved focus here (⌘], a click on the header, the API): take the
  // keyboard, unless something inside the view already has it.
  if paneIsFocused(pane, blockID: wanted.blockID), let window = view.window,
    !((window.firstResponder as? NSView)?.isDescendant(of: view) ?? false)
  {
    window.makeFirstResponder(view)
    rexTrace("block \(wanted.blockID): took focus from Rex")
  }
}

/// The BowserPaneView that has the keyboard in `window`, if any: the page
/// itself, or a field in its chrome (whose field editor is the first
/// responder, with the field as its delegate).
private func keyboardPane(in window: NSWindow) -> BowserPaneView? {
  var view: NSView? = window.firstResponder as? NSView
  if let editor = view as? NSTextView, editor.isFieldEditor { view = editor.delegate as? NSView }
  while let v = view {
    if let pane = v as? BowserPaneView { return pane }
    view = v.superview
  }
  return nil
}

/// From the NSApplication.sendEvent hook: true when a browser pane took the key.
@_cdecl("rex_bowser_handle_key")
public func rexBowserHandleKey(_ event: NSEvent) -> Bool {
  guard event.type == .keyDown, event.modifierFlags.contains(.command),
    let window = event.window ?? NSApp.keyWindow, let pane = keyboardPane(in: window)
  else { return false }
  return pane.handleBrowserKey(event, in: window)
}

private var originalLayout: IMP?

/// Hook NativePaneView.layout. Adds the override to that class only, so
/// NSView.layout stays untouched for every other view.
@_cdecl("rex_bowser_install")
public func rexBowserInstall() {
  _ = perfWatch
  guard let cls = NSClassFromString(paneClassName) else {
    return rexTrace("no \(paneClassName); Rex changed")
  }
  let sel = #selector(NSView.layout)
  let block: @convention(block) (NSView) -> Void = { pane in
    let start = Perf.now()
    if let originalLayout {
      typealias Fn = @convention(c) (NSView, Selector) -> Void
      unsafeBitCast(originalLayout, to: Fn.self)(pane, sel)
    }
    reconcilePane(pane)
    Perf.slice("pane layout", from: start, over: 1000)
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
  Perf.instant(s)
  guard let path = ProcessInfo.processInfo.environment["BOWSER_REX_TRACE"],
    let f = fopen(path, "a")
  else { return }
  var tv = timeval()
  gettimeofday(&tv, nil)
  fputs(String(format: "%ld.%06d ", tv.tv_sec, tv.tv_usec) + s + "\n", f)
  fclose(f)
}

/// BOWSER_REX_PERF=<file>: Chrome trace events, one JSON object a line, with
/// `ts` in microseconds of mach time, the clock the engine's trace_start
/// reports against its own. rex-client/perf-trace.sh merges them into the
/// engine's trace, so a late frame lines up with what Rex's main thread did.
enum Perf {
  static let file: FileHandle? = {
    guard let path = ProcessInfo.processInfo.environment["BOWSER_REX_PERF"] else { return nil }
    FileManager.default.createFile(atPath: path, contents: nil)
    let f = FileHandle(forWritingAtPath: path)
    f?.seekToEndOfFile()
    return f
  }()
  static let queue = DispatchQueue(label: "perf", qos: .utility)
  static let pid = ProcessInfo.processInfo.processIdentifier
  static let timebase: Double = {
    var tb = mach_timebase_info()
    mach_timebase_info(&tb)
    return Double(tb.numer) / Double(tb.denom) / 1000
  }()

  static func now() -> Double { Double(mach_absolute_time()) * timebase }

  static func write(_ event: [String: Any]) {
    guard let file else { return }
    var e = event
    e["pid"] = pid
    e["tid"] = pthread_main_np() != 0 ? 1 : 2
    queue.async {
      guard let data = try? JSONSerialization.data(withJSONObject: e) else { return }
      file.write(data + Data("\n".utf8))
    }
  }

  /// A slice from `start` to now, if it took at least `over` microseconds.
  static func slice(_ name: String, from start: Double, over: Double = 0) {
    guard file != nil else { return }
    let end = now()
    if end - start >= over { write(["name": name, "cat": "rex", "ph": "X", "ts": start, "dur": end - start]) }
  }

  static func instant(_ name: String) {
    guard file != nil else { return }
    write(["name": name, "cat": "rex", "ph": "i", "s": "t", "ts": now()])
  }
}

/// Each main run loop turn that runs 4 ms or more becomes a slice: the time
/// Rex's main thread could not lay out, commit, or handle input.
private let perfWatch: Void = {
  guard Perf.file != nil else { return }
  Perf.write(["name": "process_name", "ph": "M", "args": ["name": "Rex client"]])
  Perf.write(["name": "thread_name", "ph": "M", "args": ["name": "main"]])
  var woke = Perf.now()
  let observer = CFRunLoopObserverCreateWithHandler(
    nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0
  ) { _, activity in
    if activity == .afterWaiting { woke = Perf.now() } else { Perf.slice("main thread busy", from: woke, over: 4000) }
  }
  CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
}()
