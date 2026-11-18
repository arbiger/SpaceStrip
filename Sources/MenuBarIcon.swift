import AppKit

enum MenuBarIcon {
    static func image(pointSize: CGFloat = 17) -> NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url),
              image.size.height > 0 else { return nil }

        let aspectRatio = image.size.width / image.size.height
        image.size = NSSize(width: pointSize * aspectRatio, height: pointSize)
        image.isTemplate = false
        return image
    }
}
