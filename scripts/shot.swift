// Usage: swift shot.swift <owner-name> <out.png> — captures that app's largest window.
import CoreGraphics
import Foundation
let owner = CommandLine.arguments[1]
let out = CommandLine.arguments[2]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
let wins = list.filter { ($0[kCGWindowOwnerName as String] as? String) == owner && ($0[kCGWindowLayer as String] as? Int) == 0 }
guard let win = wins.max(by: {
  let a = $0[kCGWindowBounds as String] as! [String: Double], b = $1[kCGWindowBounds as String] as! [String: Double]
  return a["Width"]! * a["Height"]! < b["Width"]! * b["Height"]!
}) else { print("no window"); exit(1) }
let id = win[kCGWindowNumber as String] as! Int
let p = Process(); p.launchPath = "/usr/sbin/screencapture"; p.arguments = ["-x", "-o", "-l\(id)", out]; p.launch(); p.waitUntilExit()
