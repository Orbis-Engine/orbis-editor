import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController

    // A launcher wants a window big enough to show a project list without
    // scrolling, and an editor needs room for three regions side by side.
    // Sized for the second, since that is where the time is spent.
    let target = NSSize(width: 1280, height: 800)
    var frame = windowFrame
    frame.size = target
    self.setFrame(frame, display: true)
    self.center()
    self.minSize = NSSize(width: 960, height: 620)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
