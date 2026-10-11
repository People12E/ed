// LayerTextures.swift — text and shape layers are rasterised once (CoreGraphics / UIKit) and cached as textures.
// They then go through the same transform + blend path as video.

import UIKit
import MetalKit

final class LayerTextureStore {
    private let loader: MTKTextureLoader
    private var cache: [String: MTLTexture] = [:]
    private let lock = NSLock()

    init(device: MTLDevice) {
        loader = MTKTextureLoader(device: device)
    }

    func texture(for layer: Layer) -> MTLTexture? {
        let key = layer.contentKey
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()

        guard let image = Self.rasterize(layer), let cg = image.cgImage else { return nil }
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: true,
            .origin: MTKTextureLoader.Origin.topLeft,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.shared.rawValue)
        ]
        guard let tex = try? loader.newTexture(cgImage: cg, options: options) else { return nil }

        lock.lock()
        if cache.count > 48 { cache.removeAll() }
        cache[key] = tex
        lock.unlock()
        return tex
    }

    static func rasterize(_ layer: Layer) -> UIImage? {
        let color = UIColor(layer.color)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        switch layer.kind {
        case .video:
            return nil

        case .text:
            let font = UIFont.systemFont(ofSize: CGFloat(layer.fontSize), weight: .heavy)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph
            ]
            let string = NSAttributedString(string: layer.text.isEmpty ? " " : layer.text, attributes: attributes)
            let bounds = string.boundingRect(with: CGSize(width: 3800, height: 3800),
                                             options: [.usesLineFragmentOrigin], context: nil)
            let pad: CGFloat = 16
            let size = CGSize(width: min(ceil(bounds.width) + pad * 2, 4000),
                              height: min(ceil(bounds.height) + pad * 2, 4000))
            let textRect = CGRect(x: pad, y: pad, width: size.width - pad * 2, height: size.height - pad * 2)
            return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                string.draw(with: textRect, options: [.usesLineFragmentOrigin], context: nil)
            }

        case .shape:
            let w = CGFloat(min(max(layer.shapeWidth, 4), 4000))
            let h = CGFloat(min(max(layer.shapeHeight, 4), 4000))
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            return UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
                color.setFill()
                switch layer.shape {
                case .rectangle: UIBezierPath(rect: rect).fill()
                case .roundedRectangle: UIBezierPath(roundedRect: rect, cornerRadius: min(w, h) * 0.14).fill()
                case .ellipse: UIBezierPath(ovalIn: rect).fill()
                }
            }
        }
    }
}
