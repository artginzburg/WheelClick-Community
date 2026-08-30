import AppKit

// A cue card for the perf runs that need a pair of hands.
//
// The scripts print their phases to whoever launched them — which, when a
// measurement is driven from an agent's shell or a background terminal, is not
// the person with a finger on the mouse. Runs were lost to exactly that: the
// phase changed, nobody knew, and the resulting zeros looked like data.
//
// Deliberately a NON-ACTIVATING panel: it must never take focus, or it would
// change the very thing some runs are measuring. It polls a text file once a
// second — cheap, and it means any script can drive it with `echo`.
//
//   perf/.build/cue /tmp/wc-cue.txt &
//   echo "Phase 2 of 3 — hands off" > /tmp/wc-cue.txt

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let panel = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: 780, height: 190),
    styleMask: [.nonactivatingPanel, .titled], backing: .buffered, defer: false
)
panel.title = "WheelClick measurement"
panel.level = .floating
panel.isFloatingPanel = true
panel.hidesOnDeactivate = false

let label = NSTextField(labelWithString: "")
label.frame = NSRect(x: 26, y: 20, width: 728, height: 150)
label.font = .systemFont(ofSize: 22, weight: .medium)
label.maximumNumberOfLines = 4
panel.contentView?.addSubview(label)

if let screen = NSScreen.main {
    panel.setFrameOrigin(NSPoint(x: screen.frame.midX - 390, y: screen.frame.maxY - 300))
}
panel.orderFrontRegardless()

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/wheelclick-cue.txt"
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    if text != label.stringValue { label.stringValue = text }
}
app.run()
