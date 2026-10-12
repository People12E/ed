// EffectDefs.swift — the effects that are implemented, with their parameters and GPU passes.
// Kernel numbers match the `switch` in `effect_apply` (Shaders.metal). Sliders fill p0.x, p0.y ... in order;
// colours fill c0, c1 ... in order.

import Foundation

struct EffectSlider {
    let key: String
    let title: String
    let min: Double
    let max: Double
    let def: Double
    let decimals: Int
}

struct EffectColor {
    let key: String
    let title: String
    let def: [Double]
}

struct EffectPass {
    let kernel: UInt32
    var dirX: Float = 0
    var dirY: Float = 0
    var radiusSlot: Float = 0          // which of p0.x...p0.w holds the blur radius for this pass
    var usesOriginal = false           // the pass also reads the layer before the effect (glow, drop shadow)
}

struct EffectDef {
    let name: String
    let category: String
    let sliders: [EffectSlider]
    let colors: [EffectColor]
    let passes: [EffectPass]

    var defaultParams: [String: Double] {
        var p: [String: Double] = [:]
        for s in sliders { p[s.key] = s.def }
        for c in colors {
            p[c.key + ".r"] = c.def[0]; p[c.key + ".g"] = c.def[1]; p[c.key + ".b"] = c.def[2]
        }
        return p
    }
}

enum EffectRegistry {
    static let defs: [EffectDef] = [
        EffectDef(name: "Brightness & Contrast", category: "Color Correction",
                  sliders: [EffectSlider(key: "brightness", title: "Brightness", min: -100.0, max: 100.0, def: 0.0, decimals: 0), EffectSlider(key: "contrast", title: "Contrast", min: -100.0, max: 100.0, def: 0.0, decimals: 0)],
                  colors: [],
                  passes: [EffectPass(kernel: 1, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Hue/Saturation", category: "Color Correction",
                  sliders: [EffectSlider(key: "hue", title: "Hue", min: -180.0, max: 180.0, def: 0.0, decimals: 0), EffectSlider(key: "saturation", title: "Saturation", min: -100.0, max: 100.0, def: 0.0, decimals: 0), EffectSlider(key: "lightness", title: "Lightness", min: -100.0, max: 100.0, def: 0.0, decimals: 0)],
                  colors: [],
                  passes: [EffectPass(kernel: 2, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Exposure", category: "Color Correction",
                  sliders: [EffectSlider(key: "exposure", title: "Exposure", min: -5.0, max: 5.0, def: 0.0, decimals: 2), EffectSlider(key: "offset", title: "Offset", min: -0.5, max: 0.5, def: 0.0, decimals: 2), EffectSlider(key: "gamma", title: "Gamma", min: 0.2, max: 3.0, def: 1.0, decimals: 2)],
                  colors: [],
                  passes: [EffectPass(kernel: 3, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Levels", category: "Color Correction",
                  sliders: [EffectSlider(key: "inBlack", title: "Input black", min: 0.0, max: 1.0, def: 0.0, decimals: 2), EffectSlider(key: "inWhite", title: "Input white", min: 0.0, max: 1.0, def: 1.0, decimals: 2), EffectSlider(key: "gamma", title: "Gamma", min: 0.2, max: 3.0, def: 1.0, decimals: 2), EffectSlider(key: "outBlack", title: "Output black", min: 0.0, max: 1.0, def: 0.0, decimals: 2), EffectSlider(key: "outWhite", title: "Output white", min: 0.0, max: 1.0, def: 1.0, decimals: 2)],
                  colors: [],
                  passes: [EffectPass(kernel: 4, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Invert", category: "Channel",
                  sliders: [EffectSlider(key: "amount", title: "Blend", min: 0.0, max: 1.0, def: 1.0, decimals: 2)],
                  colors: [],
                  passes: [EffectPass(kernel: 5, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Tint", category: "Color Correction",
                  sliders: [EffectSlider(key: "amount", title: "Amount", min: 0.0, max: 1.0, def: 1.0, decimals: 2)],
                  colors: [EffectColor(key: "black", title: "Map black to", def: [0.0, 0.0, 0.0]), EffectColor(key: "white", title: "Map white to", def: [1.0, 1.0, 1.0])],
                  passes: [EffectPass(kernel: 6, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Tritone", category: "Color Correction",
                  sliders: [EffectSlider(key: "amount", title: "Blend", min: 0.0, max: 1.0, def: 1.0, decimals: 2)],
                  colors: [EffectColor(key: "shadows", title: "Shadows", def: [0.05, 0.02, 0.15]), EffectColor(key: "mids", title: "Midtones", def: [0.6, 0.3, 0.4]), EffectColor(key: "highs", title: "Highlights", def: [1.0, 0.95, 0.8])],
                  passes: [EffectPass(kernel: 7, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Vibrance", category: "Color Correction",
                  sliders: [EffectSlider(key: "vibrance", title: "Vibrance", min: -100.0, max: 100.0, def: 40.0, decimals: 0)],
                  colors: [],
                  passes: [EffectPass(kernel: 8, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Black & White", category: "Color Correction",
                  sliders: [EffectSlider(key: "amount", title: "Amount", min: 0.0, max: 1.0, def: 1.0, decimals: 2)],
                  colors: [],
                  passes: [EffectPass(kernel: 9, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Photo Filter", category: "Color Correction",
                  sliders: [EffectSlider(key: "density", title: "Density", min: 0.0, max: 1.0, def: 0.5, decimals: 2)],
                  colors: [EffectColor(key: "filter", title: "Filter color", def: [0.9, 0.55, 0.2])],
                  passes: [EffectPass(kernel: 10, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Gamma/Pedestal/Gain", category: "Color Correction",
                  sliders: [EffectSlider(key: "gamma", title: "Gamma", min: 0.2, max: 3.0, def: 1.0, decimals: 2), EffectSlider(key: "pedestal", title: "Pedestal", min: -0.5, max: 0.5, def: 0.0, decimals: 2), EffectSlider(key: "gain", title: "Gain", min: 0.0, max: 3.0, def: 1.0, decimals: 2)],
                  colors: [],
                  passes: [EffectPass(kernel: 11, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Gaussian Blur", category: "Blur & Sharpen",
                  sliders: [EffectSlider(key: "blurriness", title: "Blurriness", min: 0.0, max: 200.0, def: 20.0, decimals: 0)],
                  colors: [],
                  passes: [EffectPass(kernel: 12, dirX: 1.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false), EffectPass(kernel: 12, dirX: 0.0, dirY: 1.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Fast Box Blur", category: "Blur & Sharpen",
                  sliders: [EffectSlider(key: "radius", title: "Radius", min: 0.0, max: 200.0, def: 20.0, decimals: 0)],
                  colors: [],
                  passes: [EffectPass(kernel: 13, dirX: 1.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false), EffectPass(kernel: 13, dirX: 0.0, dirY: 1.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Directional Blur", category: "Blur & Sharpen",
                  sliders: [EffectSlider(key: "angle", title: "Direction", min: -180.0, max: 180.0, def: 0.0, decimals: 0), EffectSlider(key: "length", title: "Length", min: 0.0, max: 300.0, def: 40.0, decimals: 0)],
                  colors: [],
                  passes: [EffectPass(kernel: 14, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Radial Blur", category: "Blur & Sharpen",
                  sliders: [EffectSlider(key: "amount", title: "Amount", min: 0.0, max: 100.0, def: 30.0, decimals: 0), EffectSlider(key: "cx", title: "Center X", min: 0.0, max: 1.0, def: 0.5, decimals: 2), EffectSlider(key: "cy", title: "Center Y", min: 0.0, max: 1.0, def: 0.5, decimals: 2)],
                  colors: [],
                  passes: [EffectPass(kernel: 15, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Sharpen", category: "Blur & Sharpen",
                  sliders: [EffectSlider(key: "amount", title: "Amount", min: 0.0, max: 400.0, def: 100.0, decimals: 0)],
                  colors: [],
                  passes: [EffectPass(kernel: 16, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Unsharp Mask", category: "Blur & Sharpen",
                  sliders: [EffectSlider(key: "amount", title: "Amount", min: 0.0, max: 500.0, def: 150.0, decimals: 0), EffectSlider(key: "radius", title: "Radius", min: 0.5, max: 20.0, def: 3.0, decimals: 1)],
                  colors: [],
                  passes: [EffectPass(kernel: 17, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Glow", category: "Stylize",
                  sliders: [EffectSlider(key: "threshold", title: "Threshold", min: 0.0, max: 1.0, def: 0.6, decimals: 2), EffectSlider(key: "radius", title: "Radius", min: 0.0, max: 200.0, def: 40.0, decimals: 0), EffectSlider(key: "intensity", title: "Intensity", min: 0.0, max: 5.0, def: 1.2, decimals: 2)],
                  colors: [EffectColor(key: "tint", title: "Glow color", def: [1.0, 1.0, 1.0])],
                  passes: [EffectPass(kernel: 18, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false), EffectPass(kernel: 12, dirX: 1.0, dirY: 0.0, radiusSlot: 1.0, usesOriginal: false), EffectPass(kernel: 12, dirX: 0.0, dirY: 1.0, radiusSlot: 1.0, usesOriginal: false), EffectPass(kernel: 19, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: true)]),
        EffectDef(name: "Mosaic", category: "Stylize",
                  sliders: [EffectSlider(key: "h", title: "Horizontal blocks", min: 2.0, max: 200.0, def: 20.0, decimals: 0), EffectSlider(key: "v", title: "Vertical blocks", min: 2.0, max: 200.0, def: 20.0, decimals: 0)],
                  colors: [],
                  passes: [EffectPass(kernel: 20, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Find Edges", category: "Stylize",
                  sliders: [EffectSlider(key: "invert", title: "Invert (0/1)", min: 0.0, max: 1.0, def: 0.0, decimals: 0), EffectSlider(key: "blend", title: "Blend with original", min: 0.0, max: 1.0, def: 0.0, decimals: 2)],
                  colors: [],
                  passes: [EffectPass(kernel: 21, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Emboss", category: "Stylize",
                  sliders: [EffectSlider(key: "direction", title: "Direction", min: -180.0, max: 180.0, def: 45.0, decimals: 0), EffectSlider(key: "relief", title: "Relief", min: 0.0, max: 10.0, def: 2.0, decimals: 1), EffectSlider(key: "blend", title: "Blend with original", min: 0.0, max: 1.0, def: 0.0, decimals: 2)],
                  colors: [],
                  passes: [EffectPass(kernel: 22, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Posterize", category: "Stylize",
                  sliders: [EffectSlider(key: "level", title: "Level", min: 2.0, max: 32.0, def: 6.0, decimals: 0)],
                  colors: [],
                  passes: [EffectPass(kernel: 23, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Threshold", category: "Stylize",
                  sliders: [EffectSlider(key: "level", title: "Level", min: 0.0, max: 1.0, def: 0.5, decimals: 2)],
                  colors: [],
                  passes: [EffectPass(kernel: 24, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "CC Vignette", category: "Stylize",
                  sliders: [EffectSlider(key: "amount", title: "Amount", min: 0.0, max: 1.0, def: 0.7, decimals: 2), EffectSlider(key: "start", title: "Start", min: 0.0, max: 1.5, def: 0.5, decimals: 2), EffectSlider(key: "feather", title: "Feather", min: 0.05, max: 2.0, def: 0.8, decimals: 2)],
                  colors: [],
                  passes: [EffectPass(kernel: 25, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Scatter", category: "Stylize",
                  sliders: [EffectSlider(key: "amount", title: "Scatter amount", min: 0.0, max: 200.0, def: 20.0, decimals: 0)],
                  colors: [],
                  passes: [EffectPass(kernel: 52, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Motion Tile", category: "Stylize",
                  sliders: [EffectSlider(key: "scale", title: "Tile scale", min: 10.0, max: 200.0, def: 50.0, decimals: 0)],
                  colors: [],
                  passes: [EffectPass(kernel: 53, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Bulge", category: "Distort",
                  sliders: [EffectSlider(key: "amount", title: "Height", min: -1.0, max: 1.0, def: 0.5, decimals: 2), EffectSlider(key: "radius", title: "Radius", min: 0.05, max: 1.5, def: 0.5, decimals: 2), EffectSlider(key: "cx", title: "Center X", min: 0.0, max: 1.0, def: 0.5, decimals: 2), EffectSlider(key: "cy", title: "Center Y", min: 0.0, max: 1.0, def: 0.5, decimals: 2)],
                  colors: [],
                  passes: [EffectPass(kernel: 26, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Twirl", category: "Distort",
                  sliders: [EffectSlider(key: "angle", title: "Angle", min: -720.0, max: 720.0, def: 90.0, decimals: 0), EffectSlider(key: "radius", title: "Radius", min: 0.05, max: 1.5, def: 0.5, decimals: 2), EffectSlider(key: "cx", title: "Center X", min: 0.0, max: 1.0, def: 0.5, decimals: 2), EffectSlider(key: "cy", title: "Center Y", min: 0.0, max: 1.0, def: 0.5, decimals: 2)],
                  colors: [],
                  passes: [EffectPass(kernel: 27, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Spherize", category: "Distort",
                  sliders: [EffectSlider(key: "amount", title: "Amount", min: 0.0, max: 1.0, def: 1.0, decimals: 2), EffectSlider(key: "radius", title: "Radius", min: 0.05, max: 1.5, def: 0.5, decimals: 2), EffectSlider(key: "cx", title: "Center X", min: 0.0, max: 1.0, def: 0.5, decimals: 2), EffectSlider(key: "cy", title: "Center Y", min: 0.0, max: 1.0, def: 0.5, decimals: 2)],
                  colors: [],
                  passes: [EffectPass(kernel: 28, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Mirror", category: "Distort",
                  sliders: [EffectSlider(key: "cx", title: "Center X", min: 0.0, max: 1.0, def: 0.5, decimals: 2), EffectSlider(key: "cy", title: "Center Y", min: 0.0, max: 1.0, def: 0.5, decimals: 2), EffectSlider(key: "angle", title: "Angle", min: -180.0, max: 180.0, def: 0.0, decimals: 0)],
                  colors: [],
                  passes: [EffectPass(kernel: 29, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Ripple", category: "Distort",
                  sliders: [EffectSlider(key: "cx", title: "Center X", min: 0.0, max: 1.0, def: 0.5, decimals: 2), EffectSlider(key: "cy", title: "Center Y", min: 0.0, max: 1.0, def: 0.5, decimals: 2), EffectSlider(key: "wavelength", title: "Wavelength", min: 10.0, max: 400.0, def: 80.0, decimals: 0), EffectSlider(key: "amplitude", title: "Amplitude", min: 0.0, max: 100.0, def: 12.0, decimals: 0), EffectSlider(key: "speed", title: "Speed", min: -4.0, max: 4.0, def: 1.0, decimals: 1)],
                  colors: [],
                  passes: [EffectPass(kernel: 30, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Wave Warp", category: "Distort",
                  sliders: [EffectSlider(key: "height", title: "Wave height", min: 0.0, max: 200.0, def: 20.0, decimals: 0), EffectSlider(key: "width", title: "Wavelength", min: 10.0, max: 600.0, def: 120.0, decimals: 0), EffectSlider(key: "direction", title: "Direction", min: -180.0, max: 180.0, def: 0.0, decimals: 0), EffectSlider(key: "speed", title: "Speed", min: -4.0, max: 4.0, def: 1.0, decimals: 1)],
                  colors: [],
                  passes: [EffectPass(kernel: 31, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Polar Coordinates", category: "Distort",
                  sliders: [EffectSlider(key: "interp", title: "Interpolation", min: 0.0, max: 1.0, def: 1.0, decimals: 2), EffectSlider(key: "type", title: "Type (0 rect to polar, 1 polar to rect)", min: 0.0, max: 1.0, def: 0.0, decimals: 0)],
                  colors: [],
                  passes: [EffectPass(kernel: 32, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Offset", category: "Distort",
                  sliders: [EffectSlider(key: "x", title: "Shift X", min: -2000.0, max: 2000.0, def: 0.0, decimals: 0), EffectSlider(key: "y", title: "Shift Y", min: -2000.0, max: 2000.0, def: 0.0, decimals: 0)],
                  colors: [],
                  passes: [EffectPass(kernel: 33, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Magnify", category: "Distort",
                  sliders: [EffectSlider(key: "scale", title: "Scale", min: 100.0, max: 800.0, def: 200.0, decimals: 0), EffectSlider(key: "size", title: "Size", min: 0.05, max: 1.0, def: 0.25, decimals: 2), EffectSlider(key: "cx", title: "Center X", min: 0.0, max: 1.0, def: 0.5, decimals: 2), EffectSlider(key: "cy", title: "Center Y", min: 0.0, max: 1.0, def: 0.5, decimals: 2)],
                  colors: [],
                  passes: [EffectPass(kernel: 34, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Turbulent Displace", category: "Distort",
                  sliders: [EffectSlider(key: "amount", title: "Amount", min: 0.0, max: 300.0, def: 40.0, decimals: 0), EffectSlider(key: "size", title: "Size", min: 5.0, max: 500.0, def: 100.0, decimals: 0), EffectSlider(key: "evolution", title: "Evolution", min: 0.0, max: 20.0, def: 0.0, decimals: 1), EffectSlider(key: "speed", title: "Animate speed", min: 0.0, max: 5.0, def: 0.5, decimals: 1)],
                  colors: [],
                  passes: [EffectPass(kernel: 35, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Noise", category: "Noise & Grain",
                  sliders: [EffectSlider(key: "amount", title: "Amount", min: 0.0, max: 1.0, def: 0.2, decimals: 2), EffectSlider(key: "mono", title: "Monochrome (0/1)", min: 0.0, max: 1.0, def: 0.0, decimals: 0)],
                  colors: [],
                  passes: [EffectPass(kernel: 36, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Fractal Noise", category: "Noise & Grain",
                  sliders: [EffectSlider(key: "contrast", title: "Contrast", min: 0.0, max: 5.0, def: 1.5, decimals: 2), EffectSlider(key: "scale", title: "Scale", min: 10.0, max: 1000.0, def: 200.0, decimals: 0), EffectSlider(key: "opacity", title: "Opacity", min: 0.0, max: 1.0, def: 1.0, decimals: 2), EffectSlider(key: "speed", title: "Animate speed", min: 0.0, max: 5.0, def: 0.3, decimals: 1)],
                  colors: [],
                  passes: [EffectPass(kernel: 37, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Fill", category: "Generate",
                  sliders: [EffectSlider(key: "opacity", title: "Opacity", min: 0.0, max: 1.0, def: 1.0, decimals: 2)],
                  colors: [EffectColor(key: "color", title: "Color", def: [1.0, 0.15, 0.15])],
                  passes: [EffectPass(kernel: 38, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Gradient Ramp", category: "Generate",
                  sliders: [EffectSlider(key: "sx", title: "Start X", min: 0.0, max: 1.0, def: 0.0, decimals: 2), EffectSlider(key: "sy", title: "Start Y", min: 0.0, max: 1.0, def: 0.0, decimals: 2), EffectSlider(key: "ex", title: "End X", min: 0.0, max: 1.0, def: 1.0, decimals: 2), EffectSlider(key: "ey", title: "End Y", min: 0.0, max: 1.0, def: 1.0, decimals: 2), EffectSlider(key: "mix", title: "Blend", min: 0.0, max: 1.0, def: 1.0, decimals: 2)],
                  colors: [EffectColor(key: "start", title: "Start color", def: [0.0, 0.0, 0.0]), EffectColor(key: "end", title: "End color", def: [1.0, 1.0, 1.0])],
                  passes: [EffectPass(kernel: 39, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "4-Color Gradient", category: "Generate",
                  sliders: [EffectSlider(key: "mix", title: "Blend", min: 0.0, max: 1.0, def: 1.0, decimals: 2)],
                  colors: [EffectColor(key: "tl", title: "Top left", def: [1.0, 0.2, 0.3]), EffectColor(key: "tr", title: "Top right", def: [1.0, 0.8, 0.2]), EffectColor(key: "bl", title: "Bottom left", def: [0.2, 0.4, 1.0]), EffectColor(key: "br", title: "Bottom right", def: [0.4, 1.0, 0.6])],
                  passes: [EffectPass(kernel: 40, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Checkerboard", category: "Generate",
                  sliders: [EffectSlider(key: "size", title: "Size", min: 4.0, max: 400.0, def: 60.0, decimals: 0), EffectSlider(key: "opacity", title: "Opacity", min: 0.0, max: 1.0, def: 0.5, decimals: 2)],
                  colors: [EffectColor(key: "color", title: "Color", def: [1.0, 1.0, 1.0])],
                  passes: [EffectPass(kernel: 41, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Grid", category: "Generate",
                  sliders: [EffectSlider(key: "size", title: "Size", min: 8.0, max: 600.0, def: 80.0, decimals: 0), EffectSlider(key: "border", title: "Border", min: 1.0, max: 40.0, def: 3.0, decimals: 0), EffectSlider(key: "opacity", title: "Opacity", min: 0.0, max: 1.0, def: 0.6, decimals: 2)],
                  colors: [EffectColor(key: "color", title: "Color", def: [1.0, 1.0, 1.0])],
                  passes: [EffectPass(kernel: 42, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Linear Color Key", category: "Keying",
                  sliders: [EffectSlider(key: "tolerance", title: "Matching tolerance", min: 0.0, max: 1.5, def: 0.3, decimals: 2), EffectSlider(key: "softness", title: "Matching softness", min: 0.0, max: 1.0, def: 0.1, decimals: 2)],
                  colors: [EffectColor(key: "key", title: "Key color", def: [0.0, 0.8, 0.1])],
                  passes: [EffectPass(kernel: 43, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Simple Choker", category: "Matte",
                  sliders: [EffectSlider(key: "amount", title: "Choke matte", min: -50.0, max: 50.0, def: 3.0, decimals: 0)],
                  colors: [],
                  passes: [EffectPass(kernel: 44, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Linear Wipe", category: "Transition",
                  sliders: [EffectSlider(key: "completion", title: "Transition completion", min: 0.0, max: 1.0, def: 0.5, decimals: 2), EffectSlider(key: "angle", title: "Wipe angle", min: -180.0, max: 360.0, def: 90.0, decimals: 0), EffectSlider(key: "feather", title: "Feather", min: 0.0, max: 400.0, def: 40.0, decimals: 0)],
                  colors: [],
                  passes: [EffectPass(kernel: 45, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Radial Wipe", category: "Transition",
                  sliders: [EffectSlider(key: "completion", title: "Transition completion", min: 0.0, max: 1.0, def: 0.5, decimals: 2), EffectSlider(key: "start", title: "Start angle", min: -180.0, max: 180.0, def: 0.0, decimals: 0), EffectSlider(key: "feather", title: "Feather", min: 0.0, max: 0.5, def: 0.02, decimals: 2)],
                  colors: [],
                  passes: [EffectPass(kernel: 46, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Iris Wipe", category: "Transition",
                  sliders: [EffectSlider(key: "completion", title: "Transition completion", min: 0.0, max: 1.0, def: 0.5, decimals: 2), EffectSlider(key: "feather", title: "Feather", min: 0.0, max: 400.0, def: 30.0, decimals: 0)],
                  colors: [],
                  passes: [EffectPass(kernel: 47, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Venetian Blinds", category: "Transition",
                  sliders: [EffectSlider(key: "completion", title: "Transition completion", min: 0.0, max: 1.0, def: 0.5, decimals: 2), EffectSlider(key: "direction", title: "Direction", min: 0.0, max: 180.0, def: 0.0, decimals: 0), EffectSlider(key: "width", title: "Width", min: 4.0, max: 300.0, def: 40.0, decimals: 0), EffectSlider(key: "feather", title: "Feather", min: 0.0, max: 100.0, def: 4.0, decimals: 0)],
                  colors: [],
                  passes: [EffectPass(kernel: 48, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Block Dissolve", category: "Transition",
                  sliders: [EffectSlider(key: "completion", title: "Transition completion", min: 0.0, max: 1.0, def: 0.5, decimals: 2), EffectSlider(key: "block", title: "Block size", min: 2.0, max: 200.0, def: 20.0, decimals: 0), EffectSlider(key: "seed", title: "Seed", min: 0.0, max: 100.0, def: 1.0, decimals: 0)],
                  colors: [],
                  passes: [EffectPass(kernel: 49, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false)]),
        EffectDef(name: "Drop Shadow", category: "Perspective",
                  sliders: [EffectSlider(key: "distance", title: "Distance", min: 0.0, max: 300.0, def: 20.0, decimals: 0), EffectSlider(key: "direction", title: "Direction", min: -180.0, max: 180.0, def: 135.0, decimals: 0), EffectSlider(key: "opacity", title: "Opacity", min: 0.0, max: 1.0, def: 0.6, decimals: 2), EffectSlider(key: "softness", title: "Softness", min: 0.0, max: 100.0, def: 12.0, decimals: 0)],
                  colors: [EffectColor(key: "color", title: "Shadow color", def: [0.0, 0.0, 0.0])],
                  passes: [EffectPass(kernel: 50, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: false), EffectPass(kernel: 12, dirX: 1.0, dirY: 0.0, radiusSlot: 3.0, usesOriginal: false), EffectPass(kernel: 12, dirX: 0.0, dirY: 1.0, radiusSlot: 3.0, usesOriginal: false), EffectPass(kernel: 51, dirX: 0.0, dirY: 0.0, radiusSlot: 0.0, usesOriginal: true)])
    ]

    private static let byName: [String: EffectDef] = Dictionary(uniqueKeysWithValues: defs.map { ($0.name, $0) })

    static func def(named name: String) -> EffectDef? { byName[name] }
    static func isImplemented(_ name: String) -> Bool { byName[name] != nil }
    static var implementedCount: Int { defs.count }
}
