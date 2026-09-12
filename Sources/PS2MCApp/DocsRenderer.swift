import PS2MCKit
import SwiftUI

/// Renders the real views to PNGs for the README.
///
/// `screencapture` needs Screen Recording permission, which this app has no business
/// asking for just to document itself. `ImageRenderer` walks the same view hierarchy the
/// app displays, so the images are accurate without any extra grant.
@MainActor
enum DocsRenderer {
    /// Which view `--docs-pose` should present. Read by `MainView` at build time.
    ///
    /// ImageRenderer cannot draw AppKit-backed controls (Picker, Toggle) or ScrollView
    /// contents — they come out as blank placeholders — so the real screenshots are taken
    /// by posing the live window at a known rect and letting `screencapture -R` have it.
    static let posed: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--docs-pose"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    /// Place the window at a fixed size and print the rect in screencapture's coordinate
    /// space (origin top-left), so the shell can capture exactly this window.
    static func poseWindow(size: CGSize) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }),
              let screen = window.screen ?? NSScreen.main else { return }
        let origin = CGPoint(x: screen.frame.minX + 80, y: screen.frame.maxY - size.height - 80)
        window.setFrame(CGRect(origin: CGPoint(x: origin.x, y: origin.y),
                               size: size), display: true)
        window.makeKeyAndOrderFront(nil)
        let frame = window.frame
        // AppKit measures from the bottom-left of the primary screen; screencapture wants
        // top-left, so the y axis has to be flipped against the whole desktop height.
        let deskHeight = (NSScreen.screens.map(\.frame.maxY).max() ?? screen.frame.maxY)
        let top = deskHeight - frame.maxY
        print("RECT \(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))")
        fflush(stdout)
    }

    /// Renders only the controller diagram. It is pure SwiftUI shapes and text, which
    /// ImageRenderer reproduces exactly; everything with real controls is captured from a
    /// live window by `scripts/screenshots.sh` instead.
    static func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        render(ControllerDiagram(state: AppModel.demoState)
                   .padding(24)
                   .background(Color(nsColor: .windowBackgroundColor)),
               size: CGSize(width: 470, height: 300),
               to: directory.appendingPathComponent("controller.png"))
        print("rendered controller diagram into \(directory.path)")
    }

    private static func render(_ view: some View, size: CGSize, to url: URL) {
        let renderer = ImageRenderer(content:
            view.frame(width: size.width, height: size.height))
        renderer.scale = 2                       // retina, so text is not mushy
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(
                "could not render \(url.lastPathComponent)\n".data(using: .utf8)!)
            return
        }
        try? png.write(to: url)
    }
}

extension AppModel {
    /// Mid-play: walking forward-left, looking right, mining while cycling the hotbar.
    static var demoState: ControllerState {
        var state = ControllerState()
        state.connected = true
        state.leftX = -0.62
        state.leftY = -0.71
        state.rightX = 0.48
        state.rightY = -0.12
        state.buttons = [.l2, .r1]
        return state
    }
}
