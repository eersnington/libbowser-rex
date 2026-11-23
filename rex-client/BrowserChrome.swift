// The browser chrome a Rex pane shows over a page: an address bar, a find bar,
// and a loading line. They float over the page instead of taking space from
// it, so showing them never resizes (and never relayouts) the page.
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

// MARK: - Address bar

final class AddressBar: FloatingBar, NSTextFieldDelegate {
  let send: SendMessage
  var onDismiss: () -> Void = {}
  private let field = NSTextField()
  private lazy var back = symbolButton("chevron.left", "Back", self, #selector(goBack))
  private lazy var forward = symbolButton("chevron.right", "Forward", self, #selector(goForward))
  private lazy var reload = symbolButton("arrow.clockwise", "Reload", self, #selector(reloadOrStop))
  private var loading = false

  init(send: @escaping SendMessage) {
    self.send = send
    super.init(frame: .zero)
    field.bezelStyle = .roundedBezel
    field.placeholderString = "Search or enter website name"
    field.delegate = self
    field.cell?.isScrollable = true
    field.cell?.wraps = false
    field.lineBreakMode = .byTruncatingTail
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    stack([back, forward, reload, field])
  }
  required init?(coder: NSCoder) { fatalError() }

  func update(_ s: BrowserState) {
    back.isEnabled = s.canGoBack
    forward.isEnabled = s.canGoForward
    loading = s.loading
    reload.image = NSImage(systemSymbolName: s.loading ? "xmark" : "arrow.clockwise",
                           accessibilityDescription: s.loading ? "Stop" : "Reload")
    // Don't overwrite what the user is typing.
    if field.currentEditor() == nil { field.stringValue = s.url }
  }

  /// Show the full address, selected, ready to type over (⌘L).
  func focus() {
    window?.makeFirstResponder(field)
    field.currentEditor()?.selectAll(nil)
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
      if !typed.isEmpty { send("navigate", ["url": typed]) }
      onDismiss()
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      onDismiss()
      return true
    default:
      return false
    }
  }

  @objc private func goBack() { send("back", nil) }
  @objc private func goForward() { send("forward", nil) }
  @objc private func reloadOrStop() { send(loading ? "stop" : "reload", nil) }
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

/// A 2 pt line along the top edge while a page loads, like Safari's.
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
