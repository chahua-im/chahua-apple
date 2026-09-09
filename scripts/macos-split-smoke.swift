// Run against the DEBUG-only -bubble-timeline -fixture-split window:
// swift scripts/macos-split-smoke.swift <pid>
// Requires Accessibility/input-posting permission for the invoking terminal.
// This deliberately uses real WindowServer input: hosted XCTest NSEvent injection
// does not exercise SwiftUI's drag recognizer on every supported macOS version.
import AppKit
import ApplicationServices

struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
}
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw SmokeFailure(description: message) }
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value
}
func descendant(_ element: AXUIElement, description: String, depth: Int = 0) -> AXUIElement? {
    guard depth < 8 else { return nil }
    if attribute(element, "AXDescription") as? String == description { return element }
    for child in attribute(element, "AXChildren") as? [AXUIElement] ?? [] {
        if let result = descendant(child, description: description, depth: depth + 1) { return result }
    }
    return nil
}
func point(_ element: AXUIElement) throws -> CGPoint {
    guard let raw = attribute(element, "AXPosition"), CFGetTypeID(raw) == AXValueGetTypeID() else {
        throw SmokeFailure(description: "Missing native screen geometry")
    }
    var result = CGPoint.zero
    try require(AXValueGetValue(raw as! AXValue, .cgPoint, &result), "Invalid native screen geometry")
    return result
}

try require(CommandLine.arguments.count == 2, "Usage: swift scripts/macos-split-smoke.swift <fixture-pid>")
guard let pid = pid_t(CommandLine.arguments[1]), let application = NSRunningApplication(processIdentifier: pid) else {
    throw SmokeFailure(description: "No running fixture process with that PID")
}
try require(AXIsProcessTrusted() && CGPreflightPostEventAccess(), "Grant the invoking terminal Accessibility/input-posting permission first")
let app = AXUIElementCreateApplication(pid)
guard let window = (attribute(app, "AXWindows") as? [AXUIElement])?.first(where: {
    attribute($0, "AXTitle") as? String == "Native bubble timeline"
}), descendant(window, description: "Conversation list width") != nil else {
    throw SmokeFailure(description: "Open the dedicated -bubble-timeline -fixture-split diagnostic window first")
}
application.activate(options: [])
AXUIElementPerformAction(window, kAXRaiseAction as CFString)
Thread.sleep(forTimeInterval: 0.3)
try require(application.isActive, "Fixture must be the active application; no input was sent")
let source = CGEventSource(stateID: .combinedSessionState)
let originalPointer = CGEvent(source: nil)?.location
var heldPointer: CGPoint?
func mouse(_ type: CGEventType, at location: CGPoint) throws {
    if type != .leftMouseUp {
        let focused = attribute(app, "AXFocusedWindow")
        try require(application.isActive && focused.map { CFEqual($0, window) } == true,
                    "Fixture lost focus; stopping input rather than driving another window")
    }
    guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: .left) else {
        throw SmokeFailure(description: "Cannot construct native mouse event")
    }
    heldPointer = type == .leftMouseUp ? nil : location
    event.post(tap: .cghidEventTap)
}
defer {
    if let heldPointer { try? mouse(.leftMouseUp, at: heldPointer) }
    if let originalPointer { CGWarpMouseCursorPosition(originalPointer) }
}
func dividerPosition() throws -> CGPoint {
    guard let divider = descendant(window, description: "Conversation list width") else {
        throw SmokeFailure(description: "Fixture divider disappeared during input")
    }
    return try point(divider)
}
func waitForDivider(x: CGFloat, label: String) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 1
    var actual = try dividerPosition().x
    while abs(actual - x) > 1, ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.01)
        actual = try dividerPosition().x
    }
    try require(abs(actual - x) <= 1, "\(label): divider tracking error \(actual - x)pt (expected screen x \(x), got \(actual))")
    // Allow another rendered update to expose feedback after the first match.
    Thread.sleep(forTimeInterval: 0.05)
    actual = try dividerPosition().x
    try require(abs(actual - x) <= 1, "\(label): divider drifted by \(actual - x)pt after layout")
}
func drag(_ moves: [(offset: CGFloat, delta: CGFloat)], label: String) throws {
    let initial = try dividerPosition()
    // The 24-point accessible hit area is centered on the floating pane gap.
    let start = CGPoint(x: initial.x + 11, y: initial.y + 200)
    try mouse(.leftMouseDown, at: start)
    Thread.sleep(forTimeInterval: 0.05)
    for move in moves {
        try mouse(.leftMouseDragged, at: CGPoint(x: start.x + move.offset, y: start.y))
        try waitForDivider(x: initial.x + move.delta, label: "\(label), pointer \(move.offset)pt")
    }
    let last = moves.last!
    try mouse(.leftMouseUp, at: CGPoint(x: start.x + last.offset, y: start.y))
    try waitForDivider(x: initial.x + last.delta, label: "\(label), release")
    print("PASS: \(label)")
}

// Establish the lower clamp without relying on persisted diagnostic window state.
let initial = try dividerPosition()
let start = CGPoint(x: initial.x + 11, y: initial.y + 200)
try mouse(.leftMouseDown, at: start)
Thread.sleep(forTimeInterval: 0.05)
try mouse(.leftMouseDragged, at: CGPoint(x: start.x - 200, y: start.y))
Thread.sleep(forTimeInterval: 0.2)
try mouse(.leftMouseUp, at: CGPoint(x: start.x - 200, y: start.y))
Thread.sleep(forTimeInterval: 0.2)
let minimum = try dividerPosition().x
// The fixture must have enough space for a 400pt sidebar and 440pt detail.
var windowSize = CGSize.zero
if let value = attribute(window, "AXSize"), CFGetTypeID(value) == AXValueGetTypeID() {
    AXValueGetValue(value as! AXValue, .cgSize, &windowSize)
}
try require(windowSize.width >= 900, "Use a diagnostic window at least 900 points wide")
try drag([(40, 40)], label: "restart from minimum clamp")
try drag([8, 16, 24, 32, 48, 64, 52, 36, 20, 0].map { ($0, $0) }, label: "successive movement and reversal")
try drag([(100, 80), (140, 80), (60, 60), (-60, -40), (-100, -40), (-20, -20)], label: "both clamps and reversal")
try drag([(12, 12), (24, 24), (-12, -12)], label: "new gesture uses rendered origin")
try waitForDivider(x: minimum + 8, label: "final width")
print("All physical splitter checks passed (1pt screen-rounding tolerance). This is a correctness check, not an FPS benchmark.")
