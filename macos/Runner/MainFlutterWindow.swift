import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    // The arguments this was launched with, handed to Dart's main.
    //
    // Without this they never arrive: on macOS a Flutter app is started by
    // LaunchServices and the embedder passes the entrypoint nothing unless it
    // is told to, so `main(List<String> arguments)` is always given an empty
    // list. `orbis_editor ~/Projects/Thing` opened the launcher instead, and
    // it did so in silence, which reads as the path being wrong rather than
    // as never having been looked at.
    //
    // The first is the executable itself. macOS also injects its own switches
    // — `-NSDocumentRevisionsDebugMode` and friends — which Dart's side drops
    // by ignoring anything that begins with a dash.
    let project = FlutterDartProject()
    project.dartEntrypointArguments = Array(CommandLine.arguments.dropFirst())

    let flutterViewController = FlutterViewController(project: project)
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
