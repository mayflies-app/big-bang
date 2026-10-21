import AppKit

@MainActor enum GlassSurface {
    static func wrap(_ content: NSView, cornerRadius: CGFloat) -> NSView {
        MacAppGlass.makeSurface(content: content, cornerRadius: cornerRadius,
                                forceStandard: CommandLine.arguments.contains("--standard-appearance")).view
    }
}
