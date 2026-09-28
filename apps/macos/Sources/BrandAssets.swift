import AppKit

enum BrandAssets {
    static let logo: NSImage = {
        guard let url = Bundle.main.url(forResource: "VectracastLogo", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { fatalError("Missing Vectracast logo") }
        image.accessibilityDescription = "Vectracast"
        return image
    }()

    static let menuBar: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for suffix in ["", "@2x", "@3x"] {
            guard let url = Bundle.main.url(forResource: "MenuBarTemplate" + suffix, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data) else { fatalError("Missing menu bar artwork") }
            rep.size = image.size
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        image.accessibilityDescription = "Vectracast"
        return image
    }()
}
