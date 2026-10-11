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
