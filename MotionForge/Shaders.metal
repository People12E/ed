// Shaders.metal — MotionForge
// 1) displaceChromaticKernel : After-Effects-style Displacement Map + Turbulent Displace
//                              fused with spectral radial Chromatic Aberration (one pass, one write).
// 2) present_vertex/fragment : split-screen compare + linear -> display encode.
//
// Working space: linear-light, premultiplied alpha, rgba16Float.
// Texture origin is top-left (same as After Effects), +x right, +y down.

#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Parameter block. Layout MUST match Swift `DisplaceChromaticParams` (stride 80).
// float2 members first (8-byte aligned), then 4-byte scalars, total multiple of 8.
// ---------------------------------------------------------------------------
struct DCParams {
    float2 displaceScale;     //   0  max displacement in pixels (x, y) at map value 0 / 1
    float2 mapOffset;         //   8  UV offset of the map
    float2 mapTile;           //  16  UV tiling of the map
    float2 caCenter;          //  24  normalized aberration center (0.5, 0.5 = middle)
    float2 turbOffset;        //  32  pixel offset for the procedural turbulence field
    float  caAmount;          //  40  aberration in pixels at the frame corner
    float  caFalloff;         //  44  radial exponent (1 = linear, 2 = quadratic)
    float  turbAmount;        //  48  turbulent displacement in pixels
    float  turbSize;          //  52  turbulence feature size in pixels
    float  turbEvolution;     //  56  z-slice of the noise (animate with time)
    uint   mapChannelX;       //  60  0 R, 1 G, 2 B, 3 A, 4 Luma
    uint   mapChannelY;       //  64
    uint   edgeMode;          //  68  0 clamp, 1 wrap, 2 mirror, 3 transparent
    uint   spectralSamples;   //  72  1...31 samples across the spectrum
    uint   flags;             //  76  bit0 use map, bit1 use turbulence
};                            //  80

constant uint FLAG_USE_MAP  = 1u << 0;
constant uint FLAG_USE_TURB = 1u << 1;

// ---------------------------------------------------------------------------
// Noise (hash without sine, value noise, 4-octave fBm)
// ---------------------------------------------------------------------------
static inline float hash13(float3 p3) {
    p3 = fract(p3 * 0.1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return fract((p3.x + p3.y) * p3.z);
}

static inline float valueNoise(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = hash13(i + float3(0, 0, 0));
    float n100 = hash13(i + float3(1, 0, 0));
    float n010 = hash13(i + float3(0, 1, 0));
    float n110 = hash13(i + float3(1, 1, 0));
    float n001 = hash13(i + float3(0, 0, 1));
    float n101 = hash13(i + float3(1, 0, 1));
    float n011 = hash13(i + float3(0, 1, 1));
    float n111 = hash13(i + float3(1, 1, 1));
    float a = mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y);
    float b = mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y);
    return mix(a, b, f.z);
}

static inline float fbm(float3 p) {
    float sum = 0.0, amp = 0.5;
    for (int i = 0; i < 4; ++i) {
        sum += amp * (valueNoise(p) * 2.0 - 1.0);
        p = p * 2.02 + float3(17.1, 9.2, 5.3);
        amp *= 0.5;
    }
    return sum;                       // roughly [-0.9, 0.9]
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static inline float4 unpremultiply(float4 c) {
    return (c.a > 1e-5) ? float4(c.rgb / c.a, c.a) : float4(0.0);
}

static inline float selectChannel(float4 c, uint which) {
    switch (which) {
        case 0:  return c.r;
        case 1:  return c.g;
        case 2:  return c.b;
        case 3:  return c.a;
        default: return dot(c.rgb, float3(0.2126, 0.7152, 0.0722));   // Rec.709 luma
    }
}

static inline float4 sampleEdge(texture2d<float, access::sample> t, float2 uv, uint mode) {
    constexpr sampler sClamp (coord::normalized, address::clamp_to_edge,   filter::linear);
    constexpr sampler sRepeat(coord::normalized, address::repeat,          filter::linear);
    constexpr sampler sMirror(coord::normalized, address::mirrored_repeat, filter::linear);
    constexpr sampler sZero  (coord::normalized, address::clamp_to_zero,   filter::linear);
    switch (mode) {
        case 1:  return t.sample(sRepeat, uv);
        case 2:  return t.sample(sMirror, uv);
        case 3:  return t.sample(sZero,   uv);
        default: return t.sample(sClamp,  uv);
    }
}

// Smooth R/G/B response across t in [0,1]; t = 0 is the short (blue) end, t = 1 the long (red) end.
static inline float3 spectralWeight(float t) {
    float r = smoothstep(0.25, 1.0, t);
    float b = smoothstep(0.25, 1.0, 1.0 - t);
    float g = 1.0 - abs(2.0 * t - 1.0);
    g = g * g * (3.0 - 2.0 * g);
    return float3(r, g, b);
}

// ---------------------------------------------------------------------------
// Kernel
// ---------------------------------------------------------------------------
kernel void displaceChromaticKernel(
    texture2d<float, access::sample> src  [[texture(0)]],
    texture2d<float, access::sample> dmap [[texture(1)]],   // bound but unused if FLAG_USE_MAP is clear
    texture2d<float, access::write>  dst  [[texture(2)]],
    constant DCParams&               P    [[buffer(0)]],
    uint2                            gid  [[thread_position_in_grid]])
{
    const uint W = dst.get_width();
    const uint H = dst.get_height();
    if (gid.x >= W || gid.y >= H) return;

    const float2 size = float2(W, H);
    const float2 px   = float2(gid) + 0.5;
    const float2 uv   = px / size;

    // ---- 1. Geometric displacement, in pixels -----------------------------------------
    float2 dispPx = float2(0.0);

    if (P.flags & FLAG_USE_MAP) {
        constexpr sampler sMap(coord::normalized, address::repeat, filter::linear);
        float4 m = unpremultiply(dmap.sample(sMap, uv * P.mapTile + P.mapOffset));
        // AE convention: 0.5 = no movement, 0 / 1 = full negative / positive displacement.
        float2 d = float2(selectChannel(m, P.mapChannelX),
                          selectChannel(m, P.mapChannelY)) - 0.5;
        dispPx += d * 2.0 * P.displaceScale;
    }

    if (P.flags & FLAG_USE_TURB) {
        float  s = max(P.turbSize, 1.0);
        float3 q = float3((px + P.turbOffset) / s, P.turbEvolution);
        dispPx += float2(fbm(q), fbm(q + float3(31.7, 11.3, 7.1))) * P.turbAmount;
    }

    const float2 uvD = uv + dispPx / size;

    // ---- 2. Radial chromatic aberration on the displaced coordinates ----------------------
    const float2 fromC    = (uv - P.caCenter) * size;              // pixels, aspect-correct
    const float  len      = length(fromC);
    const float2 dir      = (len > 1e-4) ? fromC / len : float2(0.0);
    const float  halfDiag = 0.5 * length(size);
    const float  r        = len / halfDiag;                        // 0 at center, ~1 at corner
    const float  mag      = P.caAmount * pow(max(r, 1e-5), P.caFalloff);

    uint N = clamp(P.spectralSamples, 1u, 31u);
    if (abs(mag) < 0.02) N = 1u;                                   // aberration invisible: one tap

    float3 acc  = float3(0.0);
    float3 wsum = float3(0.0);
    float  accA = 0.0;

    for (uint i = 0; i < N; ++i) {
        const float t      = (N == 1u) ? 0.5 : float(i) / float(N - 1u);
        const float lambda = t * 2.0 - 1.0;                        // -1 blue (inward) ... +1 red (outward)
        const float2 uvS   = uvD + dir * (mag * lambda) / size;
        const float4 s     = sampleEdge(src, uvS, P.edgeMode);     // premultiplied
        const float3 w     = spectralWeight(t);
        acc  += s.rgb * w;
        wsum += w;
        accA += s.a;
    }

    // Per-channel weights are normalized so a neutral pixel stays neutral.
    // rgb is deliberately NOT clamped to alpha: scene-referred HDR values > 1 must survive.
    const float3 rgb = acc / max(wsum, float3(1e-5));
    const float  a   = accA / float(N);

    dst.write(float4(rgb, a), gid);
}

// ===========================================================================
// Present pass: draws original (left of divider) vs processed (right of divider)
// ===========================================================================
struct PresentUniforms {
    float splitX;           // 0 = show processed everywhere, otherwise divider position in [0,1]
    float viewportWidth;    // drawable width in pixels (keeps the divider 1 px wide)
};

struct PresentOut {
    float4 position [[position]];
    float2 uv;
};

vertex PresentOut present_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);          // (0,0) (2,0) (0,2): one oversized triangle
    PresentOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

static inline float3 linearToSRGB(float3 c) {
    c = max(c, float3(0.0));
    float3 hi = 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055;
    float3 lo = 12.92 * c;
    return select(hi, lo, c <= float3(0.0031308));
}

fragment float4 present_fragment(
    PresentOut                in        [[stage_in]],
    texture2d<float>          processed [[texture(0)]],
    texture2d<float>          original  [[texture(1)]],
    constant PresentUniforms& U         [[buffer(0)]])
{
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 c = (in.uv.x < U.splitX) ? original.sample(s, in.uv) : processed.sample(s, in.uv);

    const float3 backdrop = float3(0.012);                // linear, dark neutral behind transparency
    float3 rgb = c.rgb + (1.0 - c.a) * backdrop;          // premultiplied "over"

    if (U.splitX > 0.0 && abs(in.uv.x - U.splitX) * U.viewportWidth < 1.0) rgb = float3(1.0);

    // Drawable is bgra8Unorm (non-sRGB), so encode here. Use bgra8Unorm_srgb or an EDR
    // rgba16Float layer to let the hardware do it / keep HDR headroom instead.
    return float4(linearToSRGB(rgb), 1.0);
}

// ===========================================================================
// Layer pass: one textured quad per layer, 2D affine transform in comp pixels (+x right, +y down).
// Output is premultiplied; blending is fixed-function (see LayerCompositor.makePSO).
// ===========================================================================
struct LayerUniforms {            // layout must match Swift `LayerCompositor.LayerUniforms` (stride 32)
    float2 center;                // layer anchor in comp pixels
    float2 halfSize;              // half of the scaled texture size in comp pixels
    float2 compSize;              // comp size in pixels
    float  rotation;              // radians, clockwise on screen
    float  opacity;               // 0...1
};

struct LayerOut {
    float4 position [[position]];
    float2 uv;
};

vertex LayerOut layer_vertex(uint vid [[vertex_id]],
                             constant LayerUniforms& U [[buffer(0)]]) {
    // Triangle strip: (-1,-1) (1,-1) (-1,1) (1,1); y = -1 is the top edge of the layer.
    float2 c = float2((vid & 1u) ? 1.0 : -1.0, (vid & 2u) ? 1.0 : -1.0);
    float2 p = c * U.halfSize;
    float cs = cos(U.rotation), sn = sin(U.rotation);
    p = float2(p.x * cs - p.y * sn, p.x * sn + p.y * cs) + U.center;

    LayerOut o;
    o.position = float4(p.x / U.compSize.x * 2.0 - 1.0, 1.0 - p.y / U.compSize.y * 2.0, 0.0, 1.0);
    o.uv = c * 0.5 + 0.5;         // texture origin is top-left, y down
    return o;
}

fragment float4 layer_fragment(LayerOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               sampler smp [[sampler(0)]],
                               constant LayerUniforms& U [[buffer(0)]]) {
    return tex.sample(smp, in.uv) * U.opacity;     // premultiplied * opacity
}

// ===========================================================================
// Content fill: push-pull diffusion inpainting (see Fill.swift for the method).
// Level textures store premultiplied colour: (rgb * weight, weight). Weight 1 = known pixel.
// ===========================================================================
struct FillParams {               // layout must match Swift `FillParams` (stride 40)
    float2 center;                // region centre in comp pixels
    float2 halfSize;              // half extents in comp pixels (already scaled)
    float  rotation;              // radians
    float  feather;               // soft edge in pixels
    float  grain;                 // 0...1
    uint   shape;                 // 0 rectangle, 1 rounded rectangle, 2 ellipse
    float  seed;
    float  pad;
};

static inline float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Signed distance to the region in pixels: negative inside, positive outside.
static inline float fillSDF(float2 p, constant FillParams& F) {
    float2 d = p - F.center;
    float c = cos(-F.rotation);
    float s = sin(-F.rotation);
    d = float2(d.x * c - d.y * s, d.x * s + d.y * c);
    if (F.shape == 2u) {
        float2 h = max(F.halfSize, float2(1.0));
        return (length(d / h) - 1.0) * min(h.x, h.y);
    }
    float r = (F.shape == 1u) ? min(F.halfSize.x, F.halfSize.y) * 0.14 : 0.0;
    float2 q = abs(d) - (F.halfSize - r);
    return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

// Known pixels are those outside the region grown by `feather`; the soft edge is blended later.
kernel void fill_prepare(texture2d<float, access::read>  comp [[texture(0)]],
                         texture2d<float, access::write> lvl0 [[texture(1)]],
                         constant FillParams&            F    [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= lvl0.get_width() || gid.y >= lvl0.get_height()) return;
    float4 c = comp.read(gid);
    float d = fillSDF(float2(gid) + 0.5, F);
    float w = (d > max(F.feather, 1.0)) ? 1.0 : 0.0;
    lvl0.write(float4(c.rgb * w, w), gid);
}

kernel void fill_down(texture2d<float, access::read>  src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    uint W = dst.get_width();
    uint H = dst.get_height();
    if (gid.x >= W || gid.y >= H) return;
    uint sw = src.get_width();
    uint sh = src.get_height();
    float4 acc = float4(0.0);
    for (uint j = 0; j < 2; ++j) {
        for (uint i = 0; i < 2; ++i) {
            uint2 p = uint2(min(gid.x * 2 + i, sw - 1), min(gid.y * 2 + j, sh - 1));
            acc += src.read(p);
        }
    }
    dst.write(acc * 0.25, gid);       // premultiplied average: weight becomes the known fraction
}

kernel void fill_up(texture2d<float, access::read>   own    [[texture(0)]],
                    texture2d<float, access::sample> coarse [[texture(1)]],
                    texture2d<float, access::write>  dst    [[texture(2)]],
                    uint2 gid [[thread_position_in_grid]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    uint W = dst.get_width();
    uint H = dst.get_height();
    if (gid.x >= W || gid.y >= H) return;
    float4 o = own.read(gid);
    float2 uv = (float2(gid) + 0.5) / float2(W, H);
    float4 c = coarse.sample(s, uv);
    float3 coarseColor = c.rgb / max(c.a, 1e-4);
    float3 ownColor = (o.a > 1e-5) ? o.rgb / o.a : coarseColor;
    float3 col = mix(coarseColor, ownColor, clamp(o.a, 0.0, 1.0));
    dst.write(float4(col, 1.0), gid);
}

kernel void fill_composite(texture2d<float, access::read>  orig   [[texture(0)]],
                           texture2d<float, access::read>  filled [[texture(1)]],
                           texture2d<float, access::write> dst    [[texture(2)]],
                           constant FillParams&            F      [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 o = orig.read(gid);
    float4 f = filled.read(gid);
    float d = fillSDF(float2(gid) + 0.5, F);
    float m = 1.0 - smoothstep(0.0, max(F.feather, 1.0), d);      // 1 inside, fades out over the feather
    float n = hash12(float2(gid) + float2(F.seed * 17.0, F.seed * 5.0)) - 0.5;
    float3 fc = f.rgb + n * F.grain * 0.08;                       // grain so the patch doesn't look plastic
    dst.write(mix(o, float4(fc, 1.0), m), gid);
}

// ===========================================================================
// Effect library: one kernel, many effects. `kernelID` picks the branch (numbers match EffectDefs.swift).
// Layer textures are premultiplied; colour effects work on straight colour `c` and re-premultiply.
// Sliders arrive in p0.x, p0.y, p0.z, p0.w, p1.x ... and colours in c0, c1 ... in the order the effect lists them.
// ===========================================================================
struct EffectParams {             // layout must match Swift `EffectGPUParams` (stride 160)
    float4 p0;
    float4 p1;
    float4 p2;
    float4 p3;
    float4 c0;
    float4 c1;
    float4 c2;
    float4 c3;
    float2 size;
    float  time;
    uint   kernelID;
    float4 pass;                  // dir.x, dir.y, pass index, radius slot
};

static inline float fxLuma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

static inline float3 fxRgb2Hsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

static inline float3 fxHsv2Rgb(float3 c) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

#define SAMP(u) src.sample(sm, (u))

kernel void effect_apply(texture2d<float, access::sample> src  [[texture(0)]],
                         texture2d<float, access::write>  dst  [[texture(1)]],
                         texture2d<float, access::sample> orig [[texture(2)]],
                         constant EffectParams&           P    [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    uint W = dst.get_width();
    uint H = dst.get_height();
    if (gid.x >= W || gid.y >= H) return;
    constexpr sampler sm(coord::normalized, address::clamp_to_zero, filter::linear);

    const float2 size = float2(W, H);
    const float2 px = float2(gid) + 0.5;
    const float2 uv = px / size;
    const float4 s = SAMP(uv);
    const float a = s.a;
    const float3 c = (a > 1e-5) ? s.rgb / a : float3(0.0);
    float4 outv = s;

    switch (P.kernelID) {
        case 1: {   // Brightness & Contrast: brightness, contrast
            float3 res = (c - 0.18) * (1.0 + P.p0.y * 0.01) + 0.18 + P.p0.x * 0.005;
            outv = float4(max(res, 0.0) * a, a);
            break;
        }
        case 2: {   // Hue/Saturation: hue, saturation, lightness
            float3 hsv = fxRgb2Hsv(c);
            hsv.x = fract(hsv.x + P.p0.x / 360.0);
            hsv.y = clamp(hsv.y * (1.0 + P.p0.y * 0.01), 0.0, 1.0);
            hsv.z = max(hsv.z * (1.0 + P.p0.z * 0.01), 0.0);
            outv = float4(fxHsv2Rgb(hsv) * a, a);
            break;
        }
        case 3: {   // Exposure: exposure, offset, gamma
            float3 res = pow(max(c * exp2(P.p0.x) + P.p0.y, 0.0), float3(1.0 / max(P.p0.z, 0.01)));
            outv = float4(res * a, a);
            break;
        }
        case 4: {   // Levels: inBlack, inWhite, gamma, outBlack, outWhite
            float3 t = clamp((c - P.p0.x) / max(P.p0.y - P.p0.x, 1e-4), 0.0, 1.0);
            t = pow(t, float3(1.0 / max(P.p0.z, 0.01)));
            float3 res = P.p0.w + t * (P.p1.x - P.p0.w);
            outv = float4(res * a, a);
            break;
        }
        case 5: {   // Invert: blend
            float3 res = mix(c, float3(1.0) - clamp(c, 0.0, 1.0), clamp(P.p0.x, 0.0, 1.0));
            outv = float4(res * a, a);
            break;
        }
        case 6: {   // Tint: amount; c0 black, c1 white
            float l = clamp(fxLuma(c), 0.0, 1.0);
            float3 res = mix(c, mix(P.c0.rgb, P.c1.rgb, l), clamp(P.p0.x, 0.0, 1.0));
            outv = float4(res * a, a);
            break;
        }
        case 7: {   // Tritone: blend; c0 shadows, c1 mids, c2 highlights
            float l = clamp(fxLuma(c), 0.0, 1.0);
            float3 tri = (l < 0.5) ? mix(P.c0.rgb, P.c1.rgb, l * 2.0) : mix(P.c1.rgb, P.c2.rgb, (l - 0.5) * 2.0);
            float3 res = mix(c, tri, clamp(P.p0.x, 0.0, 1.0));
            outv = float4(res * a, a);
            break;
        }
        case 8: {   // Vibrance: vibrance
            float mx = max(max(c.r, c.g), c.b);
            float mn = min(min(c.r, c.g), c.b);
            float sat = clamp(mx - mn, 0.0, 1.0);
            float amt = P.p0.x * 0.01 * (1.0 - sat);
            float3 res = mix(float3(fxLuma(c)), c, 1.0 + amt);
            outv = float4(max(res, 0.0) * a, a);
            break;
        }
        case 9: {   // Black & White: amount
            float3 res = mix(c, float3(fxLuma(c)), clamp(P.p0.x, 0.0, 1.0));
            outv = float4(res * a, a);
            break;
        }
        case 10: {  // Photo Filter: density; c0 filter colour
            float3 f = P.c0.rgb / max(fxLuma(P.c0.rgb), 0.05);
            float3 res = mix(c, c * f, clamp(P.p0.x, 0.0, 1.0));
            outv = float4(res * a, a);
            break;
        }
        case 11: {  // Gamma/Pedestal/Gain: gamma, pedestal, gain
            float3 res = pow(max(c * P.p0.z + P.p0.y, 0.0), float3(1.0 / max(P.p0.x, 0.01)));
            outv = float4(res * a, a);
            break;
        }
        case 12: {  // Gaussian blur, one direction: radius from p0[radius slot]
            float radius = P.p0[uint(P.pass.w)];
            float2 dir = P.pass.xy;
            float sigma = max(radius * 0.5, 0.0001);
            float stepPx = max(radius * 1.5 / 24.0, 1.0);
            float4 acc = float4(0.0);
            float wsum = 0.0;
            for (int k = -24; k <= 24; ++k) {
                float dd = float(k) * stepPx;
                float w = exp(-0.5 * dd * dd / (sigma * sigma));
                acc += SAMP(uv + dir * dd / size) * w;
                wsum += w;
            }
            outv = acc / wsum;
            break;
        }
        case 13: {  // Box blur, one direction
            float radius = P.p0[uint(P.pass.w)];
            float2 dir = P.pass.xy;
            float stepPx = max(radius / 24.0, 1.0);
            float4 acc = float4(0.0);
            float wsum = 0.0;
            for (int k = -24; k <= 24; ++k) {
                float dd = float(k) * stepPx;
                float w = (abs(dd) <= radius + 0.001) ? 1.0 : 0.0;
                acc += SAMP(uv + dir * dd / size) * w;
                wsum += w;
            }
            outv = acc / max(wsum, 1.0);
            break;
        }
        case 14: {  // Directional Blur: angle, length
            float ang = P.p0.x * 0.0174533;
            float2 dir = float2(cos(ang), sin(ang)) / size;
            float4 acc = float4(0.0);
            for (int i = -12; i <= 12; ++i) {
                acc += SAMP(uv + dir * (float(i) / 12.0) * 0.5 * P.p0.y);
            }
            outv = acc / 25.0;
            break;
        }
        case 15: {  // Radial Blur: amount, centre x, centre y
            float2 ctr = float2(P.p0.y, P.p0.z);
            float amt = P.p0.x * 0.01;
            float4 acc = float4(0.0);
            for (int i = 0; i < 24; ++i) {
                float k = 1.0 - amt * float(i) / 24.0;
                acc += SAMP(ctr + (uv - ctr) * k);
            }
            outv = acc / 24.0;
            break;
        }
        case 16: {  // Sharpen: amount
            float2 d1 = 1.0 / size;
            float4 nb = SAMP(uv + float2(d1.x, 0.0)) + SAMP(uv - float2(d1.x, 0.0))
                      + SAMP(uv + float2(0.0, d1.y)) + SAMP(uv - float2(0.0, d1.y));
            float3 res = s.rgb + (s.rgb - 0.25 * nb.rgb) * (P.p0.x * 0.01);
            outv = float4(max(res, 0.0), a);
            break;
        }
        case 17: {  // Unsharp Mask: amount, radius
            float4 acc = s;
            for (int i = 0; i < 8; ++i) {
                float ang = float(i) * 0.785398;
                acc += SAMP(uv + float2(cos(ang), sin(ang)) * P.p0.y / size);
            }
            float4 bl = acc / 9.0;
            float3 res = s.rgb + (s.rgb - bl.rgb) * (P.p0.x * 0.01);
            outv = float4(max(res, 0.0), a);
            break;
        }
        case 18: {  // Glow, step 1: keep what is brighter than the threshold
            float k = clamp((fxLuma(c) - P.p0.x) / max(1.0 - P.p0.x, 0.01), 0.0, 1.0);
            outv = s * k;
            break;
        }
        case 19: {  // Glow, step 3: add the blurred highlights to the original
            float4 o = orig.sample(sm, uv);
            outv = float4(o.rgb + s.rgb * P.p0.z * P.c0.rgb, max(o.a, min(s.a * P.p0.z, 1.0)));
            break;
        }
        case 20: {  // Mosaic: horizontal blocks, vertical blocks
            float2 blocks = max(P.p0.xy, float2(1.0));
            outv = SAMP((floor(uv * blocks) + 0.5) / blocks);
            break;
        }
        case 21: {  // Find Edges: invert, blend
            float2 d1 = 1.0 / size;
            float ntl = fxLuma(SAMP(uv + float2(-d1.x, -d1.y)).rgb);
            float nt  = fxLuma(SAMP(uv + float2(0.0, -d1.y)).rgb);
            float ntr = fxLuma(SAMP(uv + float2(d1.x, -d1.y)).rgb);
            float nl  = fxLuma(SAMP(uv + float2(-d1.x, 0.0)).rgb);
            float nr  = fxLuma(SAMP(uv + float2(d1.x, 0.0)).rgb);
            float nbl = fxLuma(SAMP(uv + float2(-d1.x, d1.y)).rgb);
            float nb  = fxLuma(SAMP(uv + float2(0.0, d1.y)).rgb);
            float nbr = fxLuma(SAMP(uv + float2(d1.x, d1.y)).rgb);
            float gx = (ntr + 2.0 * nr + nbr) - (ntl + 2.0 * nl + nbl);
            float gy = (nbl + 2.0 * nb + nbr) - (ntl + 2.0 * nt + ntr);
            float g = clamp(length(float2(gx, gy)), 0.0, 1.0);
            float v = (P.p0.x > 0.5) ? g : 1.0 - g;
            float3 res = mix(float3(v), c, clamp(P.p0.y, 0.0, 1.0));
            outv = float4(res * a, a);
            break;
        }
        case 22: {  // Emboss: direction, relief, blend
            float ang = P.p0.x * 0.0174533;
            float2 off = float2(cos(ang), -sin(ang)) / size;
            float d = fxLuma(SAMP(uv + off).rgb) - fxLuma(SAMP(uv - off).rgb);
            float3 res = mix(float3(0.5 + d * P.p0.y * 2.0), c, clamp(P.p0.z, 0.0, 1.0));
            outv = float4(res * a, a);
            break;
        }
        case 23: {  // Posterize: level
            float lv = max(P.p0.x, 2.0);
            float3 res = min(floor(clamp(c, 0.0, 1.0) * (lv - 0.001)) / (lv - 1.0), float3(1.0));
            outv = float4(res * a, a);
            break;
        }
        case 24: {  // Threshold: level
            float3 res = float3(fxLuma(c) >= P.p0.x ? 1.0 : 0.0);
            outv = float4(res * a, a);
            break;
        }
        case 25: {  // Vignette: amount, start, feather
            float rr = length((uv - 0.5) * 2.0);
            float v = smoothstep(P.p0.y, P.p0.y + max(P.p0.z, 0.01), rr);
            outv = float4(c * (1.0 - v * P.p0.x) * a, a);
            break;
        }
        case 26: {  // Bulge: amount, radius, centre x, centre y
            float asp = size.x / size.y;
            float2 ctr = float2(P.p0.z, P.p0.w);
            float2 d = (uv - ctr) * float2(asp, 1.0);
            float rr = length(d);
            float R = max(P.p0.y, 0.01);
            float2 suv = uv;
            if (rr < R && rr > 1e-5) {
                float k = rr / R;
                float srcR = rr * mix(1.0, k, P.p0.x);
                suv = ctr + (d / rr * srcR) / float2(asp, 1.0);
            }
            outv = SAMP(suv);
            break;
        }
        case 27: {  // Twirl: angle, radius, centre x, centre y
            float asp = size.x / size.y;
            float2 ctr = float2(P.p0.z, P.p0.w);
            float2 d = (uv - ctr) * float2(asp, 1.0);
            float rr = length(d);
            float R = max(P.p0.y, 0.01);
            float2 suv = uv;
            if (rr < R) {
                float t = 1.0 - rr / R;
                float ang = P.p0.x * 0.0174533 * t * t;
                float cs = cos(ang);
                float sn = sin(ang);
                float2 rd = float2(d.x * cs - d.y * sn, d.x * sn + d.y * cs);
                suv = ctr + rd / float2(asp, 1.0);
            }
            outv = SAMP(suv);
            break;
        }
        case 28: {  // Spherize: amount, radius, centre x, centre y
            float asp = size.x / size.y;
            float2 ctr = float2(P.p0.z, P.p0.w);
            float2 d = (uv - ctr) * float2(asp, 1.0);
            float rr = length(d);
            float R = max(P.p0.y, 0.01);
            float2 suv = uv;
            if (rr < R && rr > 1e-5) {
                float k = clamp(rr / R, 0.0, 1.0);
                float srcR = mix(rr, R * asin(k) / 1.5708, P.p0.x);
                suv = ctr + (d / rr * srcR) / float2(asp, 1.0);
            }
            outv = SAMP(suv);
            break;
        }
        case 29: {  // Mirror: centre x, centre y, angle
            float ang = P.p0.z * 0.0174533;
            float2 nrm = float2(cos(ang), sin(ang));
            float2 cp = float2(P.p0.x, P.p0.y) * size;
            float2 p = px;
            float dd = dot(p - cp, nrm);
            if (dd < 0.0) { p -= 2.0 * dd * nrm; }
            outv = SAMP(p / size);
            break;
        }
        case 30: {  // Ripple: centre x, centre y, wavelength, amplitude, speed
            float2 d = px - float2(P.p0.x, P.p0.y) * size;
            float rr = length(d);
            float off = sin(rr / max(P.p0.z, 1.0) * 6.28318 - P.time * P.p1.x * 6.28318) * P.p0.w;
            float2 dirn = (rr > 1e-4) ? d / rr : float2(0.0);
            outv = SAMP((px + dirn * off) / size);
            break;
        }
        case 31: {  // Wave Warp: height, wavelength, direction, speed
            float ang = P.p0.z * 0.0174533;
            float2 dirw = float2(cos(ang), sin(ang));
            float2 perp = float2(-dirw.y, dirw.x);
            float ph = dot(px, dirw) / max(P.p0.y, 1.0) * 6.28318 - P.time * P.p0.w * 6.28318;
            outv = SAMP((px + perp * sin(ph) * P.p0.x) / size);
            break;
        }
        case 32: {  // Polar Coordinates: interpolation, type
            float2 suv;
            if (P.p0.y < 0.5) {
                float2 d = uv - 0.5;
                suv = float2(atan2(d.y, d.x) / 6.28318 + 0.5, length(d) * 2.0);
            } else {
                float th = uv.x * 6.28318;
                suv = 0.5 + 0.5 * uv.y * float2(cos(th), sin(th));
            }
            outv = SAMP(mix(uv, suv, clamp(P.p0.x, 0.0, 1.0)));
            break;
        }
        case 33: {  // Offset: shift x, shift y (wraps)
            outv = SAMP(fract(uv - P.p0.xy / size));
            break;
        }
        case 34: {  // Magnify: scale, size, centre x, centre y
            float asp = size.x / size.y;
            float2 ctr = float2(P.p0.z, P.p0.w);
            float rr = length((uv - ctr) * float2(asp, 1.0));
            float R = max(P.p0.y, 0.01);
            float sc = max(P.p0.x * 0.01, 1.0);
            float inside = 1.0 - smoothstep(R * 0.9, R, rr);
            outv = SAMP(ctr + (uv - ctr) / mix(1.0, sc, inside));
            break;
        }
        case 35: {  // Turbulent Displace: amount, size, evolution, animate speed
            float3 q = float3(px / max(P.p0.y, 1.0), P.p0.z + P.time * P.p0.w);
            float2 dsp = float2(fbm(q), fbm(q + float3(31.7, 11.3, 7.1))) * P.p0.x;
            outv = SAMP((px + dsp) / size);
            break;
        }
        case 36: {  // Noise: amount, monochrome
            float n1 = hash12(px + P.time * 61.0);
            float n2 = hash12(px + 17.1 + P.time * 61.0);
            float n3 = hash12(px + 91.7 + P.time * 61.0);
            float3 nz = (P.p0.y > 0.5) ? float3(n1) : float3(n1, n2, n3);
            float3 res = max(c + (nz - 0.5) * P.p0.x, 0.0);
            outv = float4(res * a, a);
            break;
        }
        case 37: {  // Fractal Noise: contrast, scale, opacity, animate speed
            float3 q = float3(px / max(P.p0.y, 1.0), P.time * P.p0.w);
            float n = fbm(q) * 0.5 + 0.5;
            n = clamp((n - 0.5) * P.p0.x + 0.5, 0.0, 1.0);
            float op = clamp(P.p0.z, 0.0, 1.0);
            float oa = max(a, op);
            outv = float4(mix(c, float3(n), op) * oa, oa);
            break;
        }
        case 38: {  // Fill: opacity; c0 colour
            float3 res = mix(c, P.c0.rgb, clamp(P.p0.x, 0.0, 1.0));
            outv = float4(res * a, a);
            break;
        }
        case 39: {  // Gradient Ramp: start x, start y, end x, end y, blend; c0 start, c1 end
            float2 a0 = float2(P.p0.x, P.p0.y) * size;
            float2 b0 = float2(P.p0.z, P.p0.w) * size;
            float2 ab = b0 - a0;
            float t = clamp(dot(px - a0, ab) / max(dot(ab, ab), 1e-3), 0.0, 1.0);
            float3 g = mix(P.c0.rgb, P.c1.rgb, t);
            outv = mix(s, float4(g, 1.0), clamp(P.p1.x, 0.0, 1.0));
            break;
        }
        case 40: {  // 4-Color Gradient: blend; c0 top-left, c1 top-right, c2 bottom-left, c3 bottom-right
            float3 g = mix(mix(P.c0.rgb, P.c1.rgb, uv.x), mix(P.c2.rgb, P.c3.rgb, uv.x), uv.y);
            outv = mix(s, float4(g, 1.0), clamp(P.p0.x, 0.0, 1.0));
            break;
        }
        case 41: {  // Checkerboard: size, opacity; c0 colour
            float2 cell = floor(px / max(P.p0.x, 1.0));
            bool on = fmod(cell.x + cell.y, 2.0) > 0.5;
            float op = clamp(P.p0.y, 0.0, 1.0);
            float oa = on ? max(a, op) : a;
            float3 res = on ? mix(c, P.c0.rgb, op) : c;
            outv = float4(res * oa, oa);
            break;
        }
        case 42: {  // Grid: size, border, opacity; c0 colour
            float cellSize = max(P.p0.x, 1.0);
            float2 f = float2(fmod(px.x, cellSize), fmod(px.y, cellSize));
            bool on = (f.x < P.p0.y) || (f.y < P.p0.y);
            float op = clamp(P.p0.z, 0.0, 1.0);
            float oa = on ? max(a, op) : a;
            float3 res = on ? mix(c, P.c0.rgb, op) : c;
            outv = float4(res * oa, oa);
            break;
        }
        case 43: {  // Linear Color Key: tolerance, softness; c0 key colour
            float dist = length(c - P.c0.rgb);
            outv = s * smoothstep(P.p0.x, P.p0.x + max(P.p0.y, 0.001), dist);
            break;
        }
        case 44: {  // Simple Choker: amount (positive shrinks the matte, negative grows it)
            float rad = abs(P.p0.x);
            bool erode = P.p0.x > 0.0;
            float4 best = s;
            float m = a;
            for (int i = 0; i < 8; ++i) {
                float ang = float(i) * 0.785398;
                float4 nb = SAMP(uv + float2(cos(ang), sin(ang)) * rad / size);
                if (erode) { m = min(m, nb.a); }
                else if (nb.a > best.a) { best = nb; }
            }
            outv = erode ? ((a > 1e-4) ? s * (m / a) : s) : best;
            break;
        }
        case 45: {  // Linear Wipe: completion, angle, feather
            float ang = P.p0.y * 0.0174533;
            float2 dirw = float2(sin(ang), -cos(ang));
            float proj = dot(px - 0.5 * size, dirw);
            float ext = 0.5 * (abs(size.x * dirw.x) + abs(size.y * dirw.y));
            float fe = max(P.p0.z, 1.0);
            float edge = mix(-ext - fe, ext + fe, clamp(P.p0.x, 0.0, 1.0));
            outv = s * clamp((proj - edge) / fe + 0.5, 0.0, 1.0);
            break;
        }
        case 46: {  // Radial Wipe: completion, start angle, feather
            float2 d = px - 0.5 * size;
            float ang = atan2(d.x, -d.y);
            float nrm = fract((ang - P.p0.y * 0.0174533) / 6.28318);
            float fe = max(P.p0.z, 0.001);
            outv = s * smoothstep(P.p0.x - fe, P.p0.x + fe, nrm);
            break;
        }
        case 47: {  // Iris Wipe: completion, feather
            float R = (1.0 - clamp(P.p0.x, 0.0, 1.0)) * 0.5 * length(size);
            float fe = max(P.p0.y, 1.0);
            outv = s * (1.0 - smoothstep(R - fe, R + fe, length(px - 0.5 * size)));
            break;
        }
        case 48: {  // Venetian Blinds: completion, direction, width, feather
            float ang = P.p0.y * 0.0174533;
            float w = max(P.p0.z, 1.0);
            float cell = fmod(dot(px, float2(cos(ang), sin(ang))), w);
            if (cell < 0.0) { cell += w; }
            cell /= w;
            float fe = P.p0.w / w;
            float edge = 1.0 - clamp(P.p0.x, 0.0, 1.0);
            outv = s * (1.0 - smoothstep(edge - fe, edge + fe + 1e-4, cell));
            break;
        }
        case 49: {  // Block Dissolve: completion, block size, seed
            float2 cell = floor(px / max(P.p0.y, 1.0));
            outv = s * step(P.p0.x, hash12(cell + P.p0.z * 13.0));
            break;
        }
        case 50: {  // Drop Shadow, step 1: shadow from the layer's alpha. distance, direction, opacity; c0 colour
            float ang = P.p0.y * 0.0174533;
            float2 off = float2(sin(ang), -cos(ang)) * P.p0.x;
            float sa = src.sample(sm, uv - off / size).a * clamp(P.p0.z, 0.0, 1.0);
            outv = float4(P.c0.rgb * sa, sa);
            break;
        }
        case 51: {  // Drop Shadow, step 4: layer over its (blurred) shadow
            float4 o = orig.sample(sm, uv);
            outv = o + s * (1.0 - o.a);
            break;
        }
        case 52: {  // Scatter: amount
            float2 off = (float2(hash12(px), hash12(px + 7.3)) - 0.5) * P.p0.x;
            outv = SAMP((px + off) / size);
            break;
        }
        case 53: {  // Motion Tile: tile scale in percent
            outv = SAMP(fract(uv * (100.0 / max(P.p0.x, 1.0))));
            break;
        }
        default:
            break;
    }
    dst.write(outv, gid);
}

// ===========================================================================
// 3D: models and 3D layers. Physically based shading when SceneUniforms.flags bit 0 is set.
// World space: x right, y down (pixels), z into the screen. "Up" in the sky model is therefore -y.
// ===========================================================================
struct SceneUniforms {            // layout must match Swift `SceneGPU` (stride 176)
    float4x4 viewProj;
    float4x4 lightViewProj;
    float4   camPos;              // xyz camera position, w exposure
    float4   params;              // x environment strength, y shadow bias, z shadow softness, w light count
    uint     flags;               // bit 0 realistic, bit 1 shadows active
    uint     pad0;
    uint     pad1;
    uint     pad2;
};

struct ModelUniforms {            // layout must match Swift `ModelGPU` (stride 112)
    float4x4 model;
    float4   baseColor;
    float4   material;            // metallic, roughness, has texture, lit
    float4   extra;               // x opacity
};

struct LightData {                // layout must match Swift `LightGPU` (stride 64)
    float4 positionType;          // xyz position, w type: 0 ambient, 1 parallel, 2 point, 3 spot
    float4 direction;             // xyz direction the light travels, w cos(outer cone)
    float4 color;                 // rgb radiance, w cos(inner cone)
    float4 extra;                 // x: this light uses the shadow map
};

struct MeshIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 uv       [[attribute(2)]];
};

struct MeshOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float2 uv;
};

vertex MeshOut mesh_vertex(MeshIn in [[stage_in]],
                           constant SceneUniforms& S [[buffer(1)]],
                           constant ModelUniforms& M [[buffer(2)]]) {
    MeshOut o;
    float4 wp = M.model * float4(in.position, 1.0);
    o.world = wp.xyz;
    o.normal = (M.model * float4(in.normal, 0.0)).xyz;     // uniform scale + rotation: normalised in the fragment stage
    o.uv = in.uv;
    o.position = S.viewProj * wp;
    return o;
}

vertex float4 shadow_vertex(MeshIn in [[stage_in]],
                            constant float4x4& lightViewProj [[buffer(1)]],
                            constant ModelUniforms& M [[buffer(2)]]) {
    return lightViewProj * (M.model * float4(in.position, 1.0));
}

constant float kPI = 3.14159265;

static inline float3 envColor(float3 dir, float strength) {
    float up = -dir.y;
    float3 sky = mix(float3(0.62, 0.70, 0.82), float3(0.20, 0.38, 0.75), clamp(up, 0.0, 1.0));
    float3 ground = float3(0.10, 0.09, 0.08);
    return mix(ground, sky, smoothstep(-0.15, 0.15, up)) * strength;
}

static inline float distGGX(float NoH, float a) {
    float a2 = a * a;
    float d = NoH * NoH * (a2 - 1.0) + 1.0;
    return a2 / (kPI * d * d + 1e-6);
}

static inline float visSmith(float NoV, float NoL, float a) {
    float k = a * 0.5;
    float gv = NoV / (NoV * (1.0 - k) + k);
    float gl = NoL / (NoL * (1.0 - k) + k);
    return gv * gl;
}

static inline float3 acesTonemap(float3 x) {
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

static inline float shadowFactor(float3 world, float3 N, constant SceneUniforms& S, depth2d<float> shadowMap) {
    if ((S.flags & 2u) == 0u) { return 1.0; }
    float4 lp = S.lightViewProj * float4(world + N * 2.0, 1.0);
    float3 ndc = lp.xyz / lp.w;
    float2 suv = float2(ndc.x * 0.5 + 0.5, -ndc.y * 0.5 + 0.5);
    if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0 || ndc.z > 1.0) { return 1.0; }
    constexpr sampler cs(coord::normalized, filter::linear, address::clamp_to_edge, compare_func::less_equal);
    float texel = 1.0 / float(shadowMap.get_width());
    float soft = max(S.params.z, 0.5);
    float sum = 0.0;
    for (int j = -1; j <= 1; ++j) {
        for (int i = -1; i <= 1; ++i) {
            sum += shadowMap.sample_compare(cs, suv + float2(float(i), float(j)) * texel * soft, ndc.z - S.params.y);
        }
    }
    return sum / 9.0;
}

static inline float3 shadeSurface(float3 world, float3 N, float3 V, float3 albedo, float metallic, float rough,
                                  constant SceneUniforms& S, constant LightData* lights, depth2d<float> shadowMap) {
    uint count = uint(S.params.w + 0.5);
    bool realistic = (S.flags & 1u) != 0u;
    rough = clamp(rough, 0.04, 1.0);
    float a = rough * rough;
    float3 F0 = mix(float3(0.04), albedo, metallic);
    float3 diffuseColor = albedo * (1.0 - metallic);
    float NoV = max(dot(N, V), 1e-3);
    float3 Lo = float3(0.0);

    for (uint i = 0; i < count; ++i) {
        LightData L = lights[i];
        uint type = uint(L.positionType.w + 0.5);
        float3 radiance = L.color.rgb;
        if (type == 0u) {                                         // ambient
            Lo += diffuseColor * radiance;
            continue;
        }
        float3 Ldir;
        float atten = 1.0;
        if (type == 1u) {                                         // parallel
            Ldir = -L.direction.xyz;
        } else {                                                  // point, spot
            float3 toL = L.positionType.xyz - world;
            float d = length(toL);
            Ldir = toL / max(d, 1e-3);
            atten = 360000.0 / (d * d + 360000.0);                // soft inverse-square, 600 px reference distance
            if (type == 3u) {
                float cd = dot(-Ldir, L.direction.xyz);
                atten *= smoothstep(L.direction.w, L.color.w, cd);
            }
        }
        float NoL = max(dot(N, Ldir), 0.0);
        if (NoL <= 0.0) { continue; }
        float sh = (L.extra.x > 0.5) ? shadowFactor(world, N, S, shadowMap) : 1.0;
        float3 spec = float3(0.0);
        if (realistic) {
            float3 H = normalize(Ldir + V);
            float NoH = max(dot(N, H), 0.0);
            float VoH = max(dot(V, H), 0.0);
            float3 F = F0 + (1.0 - F0) * pow(1.0 - VoH, 5.0);
            spec = distGGX(NoH, a) * visSmith(NoV, NoL, a) * F / max(4.0 * NoV * NoL, 1e-3);
        }
        Lo += (diffuseColor / kPI + spec) * radiance * NoL * atten * sh;
    }

    if (realistic) {                                              // sky and ground light
        float env = S.params.x;
        float3 irr = envColor(N, env);
        float3 R = reflect(-V, N);
        float3 spc = mix(envColor(R, env), irr, rough);
        float3 F = F0 + (max(float3(1.0 - rough), F0) - F0) * pow(1.0 - NoV, 5.0);
        Lo += diffuseColor * irr * (1.0 - F) + spc * F;
    }
    return Lo;
}

fragment float4 mesh_fragment(MeshOut in [[stage_in]],
                              texture2d<float> albedoTex [[texture(0)]],
                              depth2d<float> shadowMap [[texture(1)]],
                              constant SceneUniforms& S [[buffer(1)]],
                              constant ModelUniforms& M [[buffer(2)]],
                              constant LightData* lights [[buffer(3)]]) {
    constexpr sampler ts(coord::normalized, filter::linear, address::repeat);
    float3 albedo = M.baseColor.rgb;
    if (M.material.z > 0.5) { albedo *= albedoTex.sample(ts, in.uv).rgb; }
    float3 N = normalize(in.normal);
    float3 V = normalize(S.camPos.xyz - in.world);
    if (dot(N, V) < 0.0) { N = -N; }                              // two-sided
    float3 col = shadeSurface(in.world, N, V, albedo, M.material.x, M.material.y, S, lights, shadowMap);
    if ((S.flags & 1u) != 0u) { col = acesTonemap(col * S.camPos.w); }
    float op = clamp(M.extra.x, 0.0, 1.0);
    return float4(col * op, op);
}

fragment float4 plane_fragment(MeshOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               depth2d<float> shadowMap [[texture(1)]],
                               constant SceneUniforms& S [[buffer(1)]],
                               constant ModelUniforms& M [[buffer(2)]],
                               constant LightData* lights [[buffer(3)]]) {
    constexpr sampler ts(coord::normalized, filter::linear, address::clamp_to_edge);
    float4 t = tex.sample(ts, in.uv);                             // premultiplied
    float a = t.a;
    float3 base = (a > 1e-5) ? t.rgb / a : float3(0.0);
    float3 col = base;
    if (M.material.w > 0.5) {                                     // lit 3D layer
        float3 N = normalize(in.normal);
        float3 V = normalize(S.camPos.xyz - in.world);
        if (dot(N, V) < 0.0) { N = -N; }
        col = shadeSurface(in.world, N, V, base, M.material.x, M.material.y, S, lights, shadowMap);
        if ((S.flags & 1u) != 0u) { col = acesTonemap(col * S.camPos.w); }
    }
    float op = clamp(M.extra.x, 0.0, 1.0);
    return float4(col * a * op, a * op);
}
