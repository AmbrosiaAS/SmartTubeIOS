// CGEvent drag for the iOS Simulator, with a hold at the end.
//
// Needed because the app switcher gesture is a swipe up from the very bottom
// edge that PAUSES partway — a plain fast drag just goes Home. Simulator UI
// automation presets also cap swipe travel well below full screen height, so
// long gestures have to be synthesised here.
//
// usage: drag <x1> <y1> <x2> <y2> [steps] [holdMillis]
// Coordinates are screen points (origin top-left).

import CoreGraphics
import Foundation

let a = CommandLine.arguments
guard a.count >= 5,
      let x1 = Double(a[1]), let y1 = Double(a[2]),
      let x2 = Double(a[3]), let y2 = Double(a[4]) else {
    FileHandle.standardError.write("usage: drag <x1> <y1> <x2> <y2> [steps] [holdMillis]\n".data(using: .utf8)!)
    exit(2)
}
let steps = a.count > 5 ? (Int(a[5]) ?? 30) : 30
let holdMs = a.count > 6 ? (UInt32(a[6]) ?? 700) : 700

func post(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

post(.mouseMoved, CGPoint(x: x1, y: y1))
usleep(120_000)
post(.leftMouseDown, CGPoint(x: x1, y: y1))
usleep(80_000)

// Ease out so the gesture decelerates towards the end — UIKit reads a fast
// finish as a flick (go Home) and a slow finish as a drag (open the switcher).
for i in 1...steps {
    let t = Double(i) / Double(steps)
    let eased = 1 - pow(1 - t, 3)
    post(.leftMouseDragged, CGPoint(x: x1 + (x2 - x1) * eased,
                                    y: y1 + (y2 - y1) * eased))
    usleep(12_000)
}

// Hold still before lifting: this is what distinguishes "open the app switcher"
// from "go to the home screen".
usleep(holdMs * 1000)
post(.leftMouseUp, CGPoint(x: x2, y: y2))

print("dragged (\(x1),\(y1)) -> (\(x2),\(y2)) steps=\(steps) hold=\(holdMs)ms")
