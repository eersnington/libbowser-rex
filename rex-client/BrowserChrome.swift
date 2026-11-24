// The browser chrome of a Rex pane: a toolbar above the page (back, forward,
// reload, the address, a loading line), and a find bar that floats over the
// page, so showing it never resizes (and never relayouts) the page.
//
// Everything here talks to the engine through the vocabulary in
// adapters/cef/README.md, via the `send` closure.
import AppKit

/// The engine's `state` message.
struct BrowserState {
  var url = ""
  var title = ""
  var loading = false
  var progress = 0.0
  var canGoBack = false
  var canGoForward = false

  init() {}
  init?(json body: String?) {
    guard let data = body?.data(using: .utf8),
      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    url = o["url"] as? String ?? ""
    title = o["title"] as? String ?? ""
    loading = o["loading"] as? Bool ?? false
    progress = o["progress"] as? Double ?? 0
    canGoBack = o["can_go_back"] as? Bool ?? false
    canGoForward = o["can_go_forward"] as? Bool ?? false
  }
}

typealias SendMessage = (_ name: String, _ body: [String: Any]?) -> Void

private func symbolButton(_ symbol: String, _ label: String, _ target: AnyObject, _ action: Selector) -> NSButton {
  let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: target,
                   action: action)
  b.bezelStyle = .accessoryBarAction
  b.isBordered = false
  b.imagePosition = .imageOnly
  b.toolTip = label
  return b
}

/// A floating bar in the style of the system's compact toolbars.
class FloatingBar: NSVisualEffectView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    material = .headerView
    blendingMode = .withinWindow
    state = .followsWindowActiveState
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 0.5
    layer?.borderColor = NSColor.separatorColor.cgColor
    shadow = NSShadow()
    layer?.shadowOpacity = 0.12
    layer?.shadowRadius = 8
    layer?.shadowOffset = CGSize(width: 0, height: -2)
  }
  required init?(coder: NSCoder) { fatalError() }

  func stack(_ views: [NSView]) {
    let s = NSStackView(views: views)
    s.orientation = .horizontal
    s.spacing = 4
    s.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
    s.translatesAutoresizingMaskIntoConstraints = false
    addSubview(s)
    NSLayoutConstraint.activate([
      s.leadingAnchor.constraint(equalTo: leadingAnchor), s.trailingAnchor.constraint(equalTo: trailingAnchor),
      s.topAnchor.constraint(equalTo: topAnchor), s.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }
}

// MARK: - Toolbar

/// The row above the page, always shown: back and forward (only once there is
/// somewhere to go), reload or stop, and the address. The address reads as
/// host and path; a click or ⌘L edits the full URL, selected, and Return
/// loads it. A loading line runs along its bottom edge.
final class Toolbar: NSVisualEffectView, NSTextFieldDelegate {
  static let height: CGFloat = 30
  let send: SendMessage
  /// The address was submitted or abandoned: the page takes the keyboard back.
  var onDone: () -> Void = {}
  private lazy var back = symbolButton("chevron.left", "Back (⌘[)", self, #selector(goBack))
  private lazy var forward = symbolButton("chevron.right", "Forward (⌘])", self, #selector(goForward))
  private lazy var reload = symbolButton("arrow.clockwise", "Reload (⌘R)", self, #selector(reloadOrStop))
  private let field = AddressField()
  private let progress = ProgressLine()
  private let rule = NSBox()
  private var page = BrowserState()

  init(send: @escaping SendMessage) {
    self.send = send
    super.init(frame: .zero)
    material = .headerView
    blendingMode = .withinWindow
    state = .followsWindowActiveState
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 12)
    field.placeholderString = "Search or enter website name"
    field.delegate = self
    field.onFocus = { [weak self] in self?.fieldDidFocus() }
    field.cell?.isScrollable = true
    field.cell?.wraps = false
    field.lineBreakMode = .byTruncatingTail
    rule.boxType = .separator
    for v in [back, forward, reload, field, rule, progress] as [NSView] { addSubview(v) }
    update(BrowserState())
  }
  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    let h = Toolbar.height, b: CGFloat = 24
    var x: CGFloat = 6
    for button in [back, forward, reload] where !button.isHidden {
      button.frame = NSRect(x: x, y: (h - b) / 2, width: b, height: b)
      x += b + 2
    }
    let fieldHeight = field.intrinsicContentSize.height
    field.frame = NSRect(x: x + 6, y: (h - fieldHeight) / 2, width: max(0, bounds.width - x - 18), height: fieldHeight)
    rule.frame = NSRect(x: 0, y: h - 1, width: bounds.width, height: 1)
    progress.frame = NSRect(x: 0, y: h - 2, width: bounds.width, height: 2)
  }
  override var isFlipped: Bool { true }

  func update(_ s: BrowserState) {
    page = s
    // Like terminal-browser: no arrows until there is history to walk.
    let history = s.canGoBack || s.canGoForward
    if back.isHidden == history {
      back.isHidden = !history
      forward.isHidden = !history
      needsLayout = true
    }
    back.isEnabled = s.canGoBack
    forward.isEnabled = s.canGoForward
    reload.image = NSImage(systemSymbolName: s.loading ? "xmark" : "arrow.clockwise",
                           accessibilityDescription: s.loading ? "Stop" : "Reload")
    reload.toolTip = s.loading ? "Stop" : "Reload (⌘R)"
    if !editing { show() }
    progress.update(loading: s.loading, progress: s.progress)
  }

  private var editing: Bool { field.currentEditor() != nil }

  /// The address as people read it: no scheme, no trailing slash.
  private func show() {
    var u = page.url
    for scheme in ["https://", "http://", "file://"] where u.hasPrefix(scheme) {
      u.removeFirst(scheme.count)
    }
    if u.hasSuffix("/") { u.removeLast() }
    if let home = ProcessInfo.processInfo.environment["HOME"], u.hasPrefix(home) { u = "~" + u.dropFirst(home.count) }
    field.stringValue = u
    field.textColor = .secondaryLabelColor
  }

  /// ⌘L: the full address, selected, ready to type over.
  func edit() {
    window?.makeFirstResponder(field)
  }

  /// The first click or ⌘L: the full URL in place of the short one, all
  /// selected, as browsers do.
  private func fieldDidFocus() {
    guard let editor = field.currentEditor() else { return }
    field.stringValue = page.url
    field.textColor = .labelColor
    editor.selectAll(nil)
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
      if !typed.isEmpty { send("navigate", ["url": typed]) }
      finish()
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      finish()
      return true
    default:
      return false
    }
  }

  func controlTextDidEndEditing(_ obj: Notification) { show() }

  private func finish() {
    onDone()
    show()
  }

  @objc private func goBack() { send("back", nil) }
  @objc private func goForward() { send("forward", nil) }
  @objc private func reloadOrStop() { send(page.loading ? "stop" : "reload", nil) }
}

/// A text field that says when it takes the keyboard. After the click that
/// focused it is handled, so selecting all isn't undone by the click.
final class AddressField: NSTextField {
  var onFocus: () -> Void = {}
  override func becomeFirstResponder() -> Bool {
    let took = super.becomeFirstResponder()
    if took { DispatchQueue.main.async { [weak self] in self?.onFocus() } }
    return took
  }
}

// MARK: - Find bar

final class FindBar: FloatingBar, NSSearchFieldDelegate {
  let send: SendMessage
  var onDismiss: () -> Void = {}
  private let field = NSSearchField()
  private let count = NSTextField(labelWithString: "")
  private lazy var previous = symbolButton("chevron.up", "Previous", self, #selector(findPrevious))
  private lazy var next = symbolButton("chevron.down", "Next", self, #selector(findNext))
  private lazy var done = symbolButton("xmark.circle.fill", "Done", self, #selector(close))

  init(send: @escaping SendMessage) {
    self.send = send
    super.init(frame: .zero)
    field.delegate = self
    field.sendsSearchStringImmediately = true
    field.placeholderString = "Find on page"
    field.target = self
    field.action = #selector(textChanged)
    count.textColor = .secondaryLabelColor
    count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    field.widthAnchor.constraint(equalToConstant: 200).isActive = true
    stack([field, count, previous, next, done])
  }
  required init?(coder: NSCoder) { fatalError() }

  var text: String { field.stringValue }

  func focus() {
    window?.makeFirstResponder(field)
    field.currentEditor()?.selectAll(nil)
  }

  func update(count total: Int, active: Int) {
    count.stringValue = text.isEmpty ? "" : total == 0 ? "Not found" : "\(active) of \(total)"
  }

  @objc private func textChanged() {
    if text.isEmpty {
      send("find_stop", nil)
      count.stringValue = ""
    } else {
      send("find", ["text": text, "forward": true, "next": false])
    }
  }
  @objc func findNext() { if !text.isEmpty { send("find", ["text": text, "forward": true, "next": true]) } }
  @objc func findPrevious() { if !text.isEmpty { send("find", ["text": text, "forward": false, "next": true]) } }
  @objc func close() {
    send("find_stop", nil)
    onDismiss()
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      NSEvent.modifierFlags.contains(.shift) ? findPrevious() : findNext()
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      close()
      return true
    default:
      return false
    }
  }
}

// MARK: - Loading line

/// A 2 pt line while a page loads, like Safari's.
final class ProgressLine: NSView {
  private let bar = CALayer()
  private var visible = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    bar.anchorPoint = .zero
    layer?.addSublayer(bar)
    alphaValue = 0
  }
  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() { bar.backgroundColor = NSColor.controlAccentColor.cgColor }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func update(loading: Bool, progress: Double) {
    let shown = loading
    let width = bounds.width * max(0.08, min(1, progress))
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.2)
    bar.frame = CGRect(x: 0, y: 0, width: loading ? width : bounds.width, height: bounds.height)
    CATransaction.commit()
    if shown != visible {
      visible = shown
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = shown ? 0.1 : 0.35
        animator().alphaValue = shown ? 1 : 0
      }
    }
  }
}
