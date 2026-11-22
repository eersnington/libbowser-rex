// Swift-side reflection for rexinject: read stored properties of Rex's Swift
// views by name, which the Objective-C runtime can't see.
import Foundation

/// Describe the stored properties of `object`, one per line, each value cut
/// to `limit` characters. The caller frees the result.
@_cdecl("bowser_mirror_describe")
public func bowserMirrorDescribe(_ object: AnyObject, _ limit: Int) -> UnsafeMutablePointer<CChar> {
  var lines: [String] = []
  var mirror: Mirror? = Mirror(reflecting: object)
  while let m = mirror {
    for child in m.children {
      var value = String(describing: child.value)
      if value.count > limit { value = String(value.prefix(limit)) + "…" }
      lines.append("\(child.label ?? "_") = \(value)")
    }
    mirror = m.superclassMirror
  }
  return strdup(lines.joined(separator: "\n"))
}

/// Every stored property under `object`, to `depth` levels, as
/// `path = value` lines. For finding where a value lives.
@_cdecl("bowser_mirror_tree")
public func bowserMirrorTree(_ object: AnyObject, _ depth: Int) -> UnsafeMutablePointer<CChar> {
  var lines: [String] = []
  func walk(_ value: Any, _ path: String, _ level: Int) {
    var mirror: Mirror? = Mirror(reflecting: value)
    while let m = mirror {
      for child in m.children {
        let p = path + "." + (child.label ?? "_")
        let leaf = Mirror(reflecting: child.value).children.isEmpty
        if leaf || level >= depth {
          var v = String(describing: child.value)
          if v.count > 160 { v = String(v.prefix(160)) + "…" }
          lines.append("\(p) = \(v)")
        } else {
          walk(child.value, p, level + 1)
        }
      }
      mirror = m.superclassMirror
    }
  }
  walk(object, "", 0)
  return strdup(lines.joined(separator: "\n"))
}

/// The value of the stored property `name` on `object`, described, or nil.
@_cdecl("bowser_mirror_field")
public func bowserMirrorField(_ object: AnyObject, _ name: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
  let key = String(cString: name)
  var mirror: Mirror? = Mirror(reflecting: object)
  while let m = mirror {
    if let child = m.children.first(where: { $0.label == key }) {
      return strdup(String(describing: child.value))
    }
    mirror = m.superclassMirror
  }
  return nil
}
