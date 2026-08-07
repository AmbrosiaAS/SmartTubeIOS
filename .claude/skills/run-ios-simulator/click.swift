// CGEvent-based clicker for the iOS Simulator's render view.
//
// Why this exists: System Events `click at {x, y}` does NOT reach the
// Simulator's render surface — it is not an accessibility control, so the click
// is delivered to the window and discarded. A synthetic CGEvent posted to the
// HID event tap does land. Coordinates are screen points (origin top-left).
//
// Build: swiftc -O click.swift -o click

import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else {
    FileHandle.standardError.write("usage: click <x> <y>\n".data(using: .utf8)!)
    exit(2)
}

let point = CGPoint(x: x, y: y)

func post(_ type: CGEventType) {
    CGEvent(mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left)?.post(tap: .cghidEventTap)
}

// Move first: the Simulator tracks hover state, and a down/up with no preceding
// move is sometimes dropped as spurious.
post(.mouseMoved)
usleep(120_000)
post(.leftMouseDown)
usleep(90_000)
post(.leftMouseUp)

print("clicked \(x),\(y)")
