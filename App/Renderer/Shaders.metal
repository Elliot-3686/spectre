#include <metal_stdlib>
using namespace metal;

// MARK: - Shared structures (mirrored in RendererTypes.swift — scalars only, no padding surprises)

struct FrameUniforms {
    float viewW, viewH;
    float time, dt;
    float columns, mode;
    float opacity, layerCount;
    float glow, trailStrength;
    float fluidity, dither;
    float plotL, plotB, plotR, plotT;
    float vignette, crest;
    float spectroHead, spectroWidth;
    float bandCount, showHold;
    float pointSize, particleCount;
    float pixelScale, heightScale;
    float trailDecay, surfaceAlpha;
};

struct SimUniforms {
    float dt, columns, fluidity, substeps;
    float bypass, blur, sandCount, duneColumns;
    float gravity, time, kick, grainHeight;
    float head, pad0, pad1, pad2;
};

struct Grain { float2 p; float2 v; };

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

// MARK: - Colour (OKLab, sRGB, dithering)

static inline float3 oklabToLinear(float3 lab) {
    float l_ = lab.x + 0.3963377774f * lab.y + 0.2158037573f * lab.z;
    float m_ = lab.x - 0.1055613458f * lab.y - 0.0638541728f * lab.z;
    float s_ = lab.x - 0.0894841775f * lab.y - 1.2914855480f * lab.z;
    float l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_;
    return float3( 4.0767416621f * l - 3.3077115913f * m + 0.2309699292f * s,
                  -1.2684380046f * l + 2.6097574011f * m - 0.3413193965f * s,
                  -0.0041960863f * l - 0.7034186147f * m + 1.7076147010f * s);
}

static inline float3 srgbToLinear(float3 c) {
    return select(pow((c + 0.055f) / 1.055f, 2.4f), c / 12.92f, c <= 0.04045f);
}

static inline float3 linearToSrgb(float3 c) {
    c = clamp(c, 0.0f, 1.0f);
    return select(1.055f * pow(c, 1.0f / 2.4f) - 0.055f, 12.92f * c, c <= 0.0031308f);
}

static inline float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031f);
    p3 += dot(p3, p3.yzx + 33.33f);
    return fract((p3.x + p3.y) * p3.z);
}

static inline float3 lutLab(device const float4 *lut, float u) {
    float x = clamp(u, 0.0f, 1.0f) * 255.0f;
    int i = min(int(x), 254);
    float t = x - float(i);
    return mix(lut[i].xyz, lut[i + 1].xyz, t);
}

// Mirrors Palette.shade in SpectreCore: silence → very dark, peaks lighter, never white.
static inline float3 shadeLinear(device const float4 *lut, float u, float amp) {
    float3 lab = lutLab(lut, u);
    float a = clamp(amp, 0.0f, 1.0f);
    float L = 0.16f + (min(lab.x + 0.10f, 0.84f) - 0.16f) * pow(a, 0.85f);
    float chroma = 0.35f + 0.70f * a;
    return clamp(oklabToLinear(float3(L, lab.y * chroma, lab.z * chroma)), 0.0f, 1.0f);
}

// #07080B (top) → #0C0E13 (bottom), light vignette. Returns linear RGB.
static inline float3 background(float2 uv, constant FrameUniforms &u) {
    float3 top = float3(7.0f, 8.0f, 11.0f) / 255.0f;
    float3 bottom = float3(12.0f, 14.0f, 19.0f) / 255.0f;
    float3 c = srgbToLinear(mix(bottom, top, uv.y));
    float2 d = (uv - 0.5f) * float2(u.viewW / max(u.viewH, 1.0f), 1.0f);
    float v = smoothstep(0.35f, 1.15f, length(d) * 1.1f);
    return c * (1.0f - u.vignette * v);
}

// Dither in sRGB space (triangular, ±1 LSB) then back to linear: the sRGB
// render target re-encodes to exactly the dithered value → no banding.
static inline float4 finish(float3 lin, float2 px, constant FrameUniforms &u) {
    float3 s = linearToSrgb(lin);
    float n = hash12(px) + hash12(px + 17.31f) - 1.0f;
    s += n * (u.dither / 255.0f);
    return float4(srgbToLinear(clamp(s, 0.0f, 1.0f)), 1.0f);
}

// MARK: - Fullscreen triangle

vertex VOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o;
    o.pos = float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
    o.uv = p;
    return o;
}

// MARK: - Physics: damped springs coupled by a 1-D wave equation (one threadgroup)

kernel void liquidStep(device float *h [[buffer(0)]],
                       device float *v [[buffer(1)]],
                       device const float *target [[buffer(2)]],
                       device const float4 *params [[buffer(3)]],
                       device float4 *layersOut [[buffer(4)]],
                       device float *surfVel [[buffer(5)]],
                       device atomic_uint *energy [[buffer(6)]],
                       constant SimUniforms &s [[buffer(7)]],
                       uint i [[thread_position_in_threadgroup]]) {
    threadgroup float th[512];
    const int C = int(s.columns);
    const bool valid = int(i) < C;
    float hi = valid ? h[i] : 0.0f;
    float vi = valid ? v[i] : 0.0f;
    const float t = valid ? target[i] : 0.0f;
    const float4 p = valid ? params[i] : float4(0.0f);
    const float h0 = hi;
    const int steps = max(int(s.substeps), 1);
    const float dt = s.dt / float(steps);

    for (int k = 0; k < steps; k++) {
        th[i] = hi;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (valid) {
            float l = th[max(int(i) - 1, 0)];
            float r = th[min(int(i) + 1, C - 1)];
            float w0 = p.x;
            float acc = w0 * w0 * (t - hi) + p.z * (l + r - 2.0f * hi) - 2.0f * p.y * w0 * vi;
            vi += acc * dt;
            hi += vi * dt;
            hi = clamp(hi, -0.05f, 1.25f);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (s.bypass > 0.5f) {
        vi = (t - h0) / max(s.dt, 1e-3f);
        hi = t;
    }
    // Fluidity: 0 = raw data, 1 = full simulation.
    th[i] = valid ? mix(t, hi, s.fluidity) : 0.0f;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (!valid) return;

    const float b = max(s.blur, 0.25f);
    const float s1 = 2.0f * b, s2 = 5.0f * b, s3 = 9.0f * b;
    const int radius = min(int(ceil(s3 * 2.2f)), 24);
    float l1 = 0, l2 = 0, l3 = 0, w1 = 0, w2 = 0, w3 = 0;
    for (int k = -radius; k <= radius; k++) {
        int j = clamp(int(i) + k, 0, C - 1);
        float x = th[j];
        float kk = float(k * k);
        float a1 = exp(-kk / (2.0f * s1 * s1));
        float a2 = exp(-kk / (2.0f * s2 * s2));
        float a3 = exp(-kk / (2.0f * s3 * s3));
        l1 += x * a1; w1 += a1;
        l2 += x * a2; w2 += a2;
        l3 += x * a3; w3 += a3;
    }
    layersOut[i] = float4(th[i], l1 / w1, l2 / w2, l3 / w3);
    h[i] = hi;
    v[i] = vi;
    surfVel[i] = mix(0.0f, vi, s.fluidity) + (1.0f - s.fluidity) * (t - h0) / max(s.dt, 1e-3f);
    float e = abs(vi) + abs(t - hi) + t;
    atomic_fetch_max_explicit(energy, uint(clamp(e, 0.0f, 4000.0f) * 1.0e6f), memory_order_relaxed);
}

// MARK: - Spline sampling

static inline void catmull4(device const float4 *L, float c, int C, thread float4 &val, thread float4 &der) {
    int i = int(floor(c));
    float t = c - float(i);
    float4 p0 = L[clamp(i - 1, 0, C - 1)];
    float4 p1 = L[clamp(i, 0, C - 1)];
    float4 p2 = L[clamp(i + 1, 0, C - 1)];
    float4 p3 = L[clamp(i + 2, 0, C - 1)];
    float4 a = -0.5f * p0 + 1.5f * p1 - 1.5f * p2 + 0.5f * p3;
    float4 b = p0 - 2.5f * p1 + 2.0f * p2 - 0.5f * p3;
    float4 cc = -0.5f * p0 + 0.5f * p2;
    val = ((a * t + b) * t + cc) * t + p1;
    der = (3.0f * a * t + 2.0f * b) * t + cc;
}

static inline float2 catmull1(device const float *L, float c, int C) {
    int i = int(floor(c));
    float t = c - float(i);
    float p0 = L[clamp(i - 1, 0, C - 1)], p1 = L[clamp(i, 0, C - 1)];
    float p2 = L[clamp(i + 1, 0, C - 1)], p3 = L[clamp(i + 2, 0, C - 1)];
    float a = -0.5f * p0 + 1.5f * p1 - 1.5f * p2 + 0.5f * p3;
    float b = p0 - 2.5f * p1 + 2.0f * p2 - 0.5f * p3;
    float cc = -0.5f * p0 + 0.5f * p2;
    return float2(((a * t + b) * t + cc) * t + p1, (3.0f * a * t + 2.0f * b) * t + cc);
}

// MARK: - Liquid / curve (mode 0, 2) and sand background (mode 1)

constant float kLayerAlpha[4] = {0.92f, 0.50f, 0.32f, 0.20f};
constant float kLayerBright[4] = {1.0f, 0.78f, 0.60f, 0.45f};

fragment float4 fragLiquid(VOut in [[stage_in]],
                           constant FrameUniforms &u [[buffer(0)]],
                           device const float4 *layers [[buffer(1)]],
                           device const float4 *lut [[buffer(2)]],
                           device const float *hold [[buffer(3)]],
                           texture2d<float> trail [[texture(0)]],
                           sampler smp [[sampler(0)]]) {
    float2 uv = in.uv;
    float2 px = uv * float2(u.viewW, u.viewH);
    float3 col = background(uv, u);
    float plotW = u.plotR - u.plotL, plotH = u.plotT - u.plotB;
    float x = (uv.x - u.plotL) / plotW;
    float alpha = u.opacity * u.surfaceAlpha;

    if (u.trailStrength > 0.0f) {
        col += trail.sample(smp, float2(uv.x, 1.0f - uv.y)).rgb * u.trailStrength * u.opacity;
    }

    if (x >= 0.0f && x <= 1.0f && uv.y >= u.plotB - 0.002f) {
        const int C = int(u.columns);
        float c = x * float(C - 1);
        float4 hv, dv;
        catmull4(layers, c, C, hv, dv);
        float colPx = plotW * u.viewW / float(C - 1);
        float plotPx = plotH * u.viewH * u.heightScale;
        float yPx = (uv.y - u.plotB) * u.viewH;
        const int L = int(u.layerCount);
        const float aa = 0.8f * u.pixelScale;

        for (int j = 3; j >= 0; j--) {
            if (j > 0 && j >= L) continue;
            float hgt = clamp(hv[j], 0.0f, 1.0f);
            float surf = hgt * plotPx;
            float slope = dv[j] * plotPx / colPx;
            float d = (yPx - surf) * rsqrt(1.0f + slope * slope);   // > 0 above the surface
            float inside = 1.0f - smoothstep(-aa, aa, d);
            float depth = clamp((surf - yPx) / max(surf, 1.0f), 0.0f, 1.0f);
            float3 fill = shadeLinear(lut, x, hgt * kLayerBright[j]);
            fill *= mix(1.0f, 0.14f, pow(depth, 0.55f));
            col = mix(col, fill, inside * kLayerAlpha[j] * alpha);
            if (j <= 1) {
                float w = (j == 0 ? 1.1f : 2.2f) * u.pixelScale;
                float line = exp(-d * d / (2.0f * w * w));
                float3 crestCol = shadeLinear(lut, x, min(1.0f, hgt * 1.15f + 0.12f));
                col += crestCol * line * u.crest * (j == 0 ? 0.50f : 0.16f) * alpha;
            }
            if (j == 0 && d > 0.0f && u.glow > 0.0f) {
                float g = exp(-d / (24.0f * u.pixelScale)) * hgt;
                col += shadeLinear(lut, x, hgt) * u.glow * 0.28f * g * alpha;
            }
        }

        if (u.showHold > 0.5f) {
            float2 hh = catmull1(hold, c, C);
            float surf = clamp(hh.x, 0.0f, 1.0f) * plotPx;
            float slope = hh.y * plotPx / colPx;
            float d = (yPx - surf) * rsqrt(1.0f + slope * slope);
            float w = 0.8f * u.pixelScale;
            float line = exp(-d * d / (2.0f * w * w));
            col += shadeLinear(lut, x, 0.55f) * line * 0.35f * u.opacity * step(0.004f, hh.x);
        }
    }
    return finish(col, px, u);
}

// Persistence ("ink in water"): quarter-resolution ping-pong texture.
fragment float4 fragTrail(VOut in [[stage_in]],
                          constant FrameUniforms &u [[buffer(0)]],
                          device const float4 *layers [[buffer(1)]],
                          device const float4 *lut [[buffer(2)]],
                          texture2d<float> prev [[texture(0)]],
                          sampler smp [[sampler(0)]]) {
    float2 uv = in.uv;
    float2 tc = float2(uv.x, 1.0f - uv.y);
    float2 texel = 1.0f / float2(prev.get_width(), prev.get_height());
    float2 src = tc + float2(0.0f, texel.y * 0.55f);   // slow upward drift
    float3 p = prev.sample(smp, src).rgb * 0.5f
             + (prev.sample(smp, src + float2(texel.x, 0)).rgb + prev.sample(smp, src - float2(texel.x, 0)).rgb) * 0.25f;
    float3 ink = float3(0.0f);
    float plotW = u.plotR - u.plotL, plotH = u.plotT - u.plotB;
    float x = (uv.x - u.plotL) / plotW;
    if (x >= 0.0f && x <= 1.0f) {
        const int C = int(u.columns);
        float4 hv, dv;
        catmull4(layers, x * float(C - 1), C, hv, dv);
        float hgt = clamp(hv.x, 0.0f, 1.0f);
        float plotPx = plotH * u.viewH * u.heightScale;
        float d = (uv.y - u.plotB) * u.viewH - hgt * plotPx;
        float w = 5.0f * u.pixelScale;
        ink = shadeLinear(lut, x, hgt) * exp(-d * d / (2.0f * w * w)) * hgt;
    }
    return float4(p * u.trailDecay + ink * (1.0f - u.trailDecay) * 1.6f, 1.0f);
}

// MARK: - 31-band RTA (mode 3)

fragment float4 fragBars(VOut in [[stage_in]],
                         constant FrameUniforms &u [[buffer(0)]],
                         device const float *bands [[buffer(1)]],
                         device const float4 *lut [[buffer(2)]],
                         device const float *bandHold [[buffer(3)]]) {
    float2 uv = in.uv;
    float2 px = uv * float2(u.viewW, u.viewH);
    float3 col = background(uv, u);
    float plotW = u.plotR - u.plotL, plotH = u.plotT - u.plotB;
    float x = (uv.x - u.plotL) / plotW;
    if (x >= 0.0f && x < 1.0f && uv.y >= u.plotB) {
        const float N = u.bandCount;
        int i = min(int(x * N), int(N) - 1);
        float local = x * N - float(i);
        float bandPx = plotW * u.viewW / N;
        float plotPx = plotH * u.viewH * u.heightScale;
        float yPx = (uv.y - u.plotB) * u.viewH;
        float hgt = clamp(bands[i], 0.0f, 1.0f);
        float halfW = 0.34f * bandPx;
        float radius = min(halfW, 7.0f * u.pixelScale);
        float top = max(hgt * plotPx, 0.0f);
        // Rounded-top rectangle SDF
        float2 q = float2(abs((local - 0.5f) * bandPx), yPx - top * 0.5f);
        float2 bsz = float2(halfW, top * 0.5f + radius);
        float2 dq = abs(q) - bsz + radius;
        float sd = length(max(dq, 0.0f)) + min(max(dq.x, dq.y), 0.0f) - radius;
        float aa = 0.8f * u.pixelScale;
        float inside = (1.0f - smoothstep(-aa, aa, sd)) * step(0.002f, hgt);
        float ub = (float(i) + 0.5f) / N;
        float depth = clamp((top - yPx) / max(top, 1.0f), 0.0f, 1.0f);
        float3 fill = shadeLinear(lut, ub, hgt) * mix(1.0f, 0.18f, pow(depth, 0.6f));
        col = mix(col, fill, inside * u.opacity);
        float above = yPx - top;
        if (above > 0.0f && abs(q.x) < halfW + 6.0f * u.pixelScale && u.glow > 0.0f) {
            col += shadeLinear(lut, ub, hgt) * u.glow * 0.18f * hgt * exp(-above / (18.0f * u.pixelScale))
                 * (1.0f - smoothstep(halfW, halfW + 6.0f * u.pixelScale, abs(q.x))) * u.opacity;
        }
        if (u.showHold > 0.5f) {
            float hold = clamp(bandHold[i], 0.0f, 1.0f) * plotPx;
            float w = 0.9f * u.pixelScale;
            float line = exp(-(yPx - hold) * (yPx - hold) / (2.0f * w * w)) * (1.0f - smoothstep(halfW - aa, halfW + aa, abs(q.x)));
            col += shadeLinear(lut, ub, 0.6f) * line * 0.45f * u.opacity * step(0.004f, bandHold[i]);
        }
    }
    return finish(col, px, u);
}

// MARK: - Scrolling spectrogram (mode 4)

kernel void spectroWrite(texture2d<float, access::write> tex [[texture(0)]],
                         device const float *target [[buffer(0)]],
                         constant SimUniforms &s [[buffer(1)]],
                         uint r [[thread_position_in_grid]]) {
    const uint R = tex.get_height();
    if (r >= R) return;
    const int C = int(s.columns);
    float c = float(r) / float(R - 1) * float(C - 1);
    int i = int(c);
    float t = c - float(i);
    float v = mix(target[i], target[min(i + 1, C - 1)], t);
    tex.write(float4(v, 0, 0, 1), uint2(uint(s.head), r));
}

fragment float4 fragSpectro(VOut in [[stage_in]],
                            constant FrameUniforms &u [[buffer(0)]],
                            device const float4 *lut [[buffer(2)]],
                            texture2d<float> spec [[texture(0)]],
                            sampler smp [[sampler(0)]]) {
    float2 uv = in.uv;
    float2 px = uv * float2(u.viewW, u.viewH);
    float3 col = background(uv, u);
    float x = (uv.x - u.plotL) / (u.plotR - u.plotL);
    float y = (uv.y - u.plotB) / (u.plotT - u.plotB);
    if (x >= 0.0f && x <= 1.0f && y >= 0.0f && y <= 1.0f) {
        float W = u.spectroWidth;
        float idx = u.spectroHead + 1.0f + x * (W - 1.0f);
        float v = spec.sample(smp, float2((idx + 0.5f) / W, y)).r;
        float fadeOld = smoothstep(0.0f, 0.12f, x);   // oldest columns dissolve
        float3 c = shadeLinear(lut, y, v);
        col = mix(col, c, smoothstep(0.02f, 0.75f, v) * u.opacity * fadeOld);
    }
    return finish(col, px, u);
}

// MARK: - Sand (mode 1): grains on the spectrum surface, Chladni-like

static inline float rnd(uint id, float t, float salt) {
    return hash12(float2(float(id % 4096u) * 0.731f + salt, float(id / 4096u) * 1.37f + t * 61.7f));
}

kernel void sandStep(device Grain *grains [[buffer(0)]],
                     device const float4 *layers [[buffer(1)]],
                     device const float *surfVel [[buffer(2)]],
                     device const float *dune [[buffer(3)]],
                     device atomic_uint *counts [[buffer(4)]],
                     device atomic_uint *moving [[buffer(5)]],
                     constant SimUniforms &s [[buffer(6)]],
                     uint id [[thread_position_in_grid]]) {
    if (id >= uint(s.sandCount)) return;
    Grain g = grains[id];
    const int C = int(s.columns);
    const int D = int(s.duneColumns);
    const float dt = s.dt;
    float cx = clamp(g.p.x, 0.0f, 1.0f) * float(C - 1);
    int ci = min(int(cx), C - 2);
    float ft = cx - float(ci);
    float surf = mix(layers[ci].x, layers[ci + 1].x, ft) * 0.92f;
    float sv = mix(surfVel[ci], surfVel[ci + 1], ft) * 0.92f;
    int di = clamp(int(g.p.x * float(D)), 0, D - 1);
    float ground = surf + dune[di];

    g.v.y -= s.gravity * dt;
    g.v *= (1.0f - 0.9f * dt);
    g.p += g.v * dt;

    bool resting = false;
    if (g.p.y <= ground) {
        g.p.y = ground;
        float r1 = rnd(id, s.time, 0.0f), r2 = rnd(id, s.time, 7.0f);
        if (sv > 0.08f) {
            // The band's energy throws the grain upward.
            g.v.y = sv * (0.9f + 0.9f * r1) + s.kick * r1 * surf;
            g.v.x = (r2 - 0.5f) * 0.10f * (0.4f + sv);
        } else {
            float slope = (dune[min(di + 1, D - 1)] - dune[max(di - 1, 0)]) * float(D) * 0.5f;
            g.v.x = g.v.x * 0.55f - slope * 0.015f;
            g.v.y = 0.0f;
            resting = abs(g.v.x) < 0.003f;
        }
    }
    if (g.p.x < 0.0f) { g.p.x = -g.p.x; g.v.x = abs(g.v.x) * 0.5f; }
    if (g.p.x > 1.0f) { g.p.x = 2.0f - g.p.x; g.v.x = -abs(g.v.x) * 0.5f; }
    if (g.p.y > 1.3f) { g.v.y = min(g.v.y, 0.0f); }
    grains[id] = g;
    if (g.p.y <= ground + 0.003f) atomic_fetch_add_explicit(&counts[di], 1u, memory_order_relaxed);
    if (!resting) atomic_fetch_add_explicit(moving, 1u, memory_order_relaxed);
}

kernel void duneUpdate(device atomic_uint *counts [[buffer(0)]],
                       device float *dune [[buffer(1)]],
                       constant SimUniforms &s [[buffer(2)]],
                       uint i [[thread_position_in_grid]]) {
    const int D = int(s.duneColumns);
    if (int(i) >= D) return;
    float cl = float(atomic_load_explicit(&counts[max(int(i) - 1, 0)], memory_order_relaxed));
    float cc = float(atomic_load_explicit(&counts[i], memory_order_relaxed));
    float cr = float(atomic_load_explicit(&counts[min(int(i) + 1, D - 1)], memory_order_relaxed));
    float target = (0.25f * cl + 0.5f * cc + 0.25f * cr) * s.grainHeight;
    dune[i] = mix(dune[i], target, 0.2f);
}

struct PointOut {
    float4 pos [[position]];
    float size [[point_size]];
    float4 color;
};

vertex PointOut grainVertex(uint vid [[vertex_id]],
                            constant FrameUniforms &u [[buffer(0)]],
                            device const Grain *grains [[buffer(1)]],
                            device const float4 *lut [[buffer(2)]]) {
    Grain g = grains[vid];
    float x = u.plotL + g.p.x * (u.plotR - u.plotL);
    float y = u.plotB + g.p.y * (u.plotT - u.plotB) * u.heightScale;
    PointOut o;
    o.pos = float4(x * 2.0f - 1.0f, y * 2.0f - 1.0f, 0.0f, 1.0f);
    float speed = length(g.v);
    float lift = smoothstep(0.0f, 0.35f, speed);
    float amp = clamp(0.30f + 0.45f * lift + 0.35f * g.p.y, 0.0f, 1.0f);
    float3 c = shadeLinear(lut, g.p.x, amp) * (0.62f + 0.38f * lift);   // resting grains darker
    o.color = float4(c, 0.85f * u.opacity);
    o.size = u.pointSize;
    return o;
}

fragment float4 grainFragment(PointOut in [[stage_in]], float2 pc [[point_coord]]) {
    float r = length(pc - 0.5f) * 2.0f;
    float a = in.color.a * (1.0f - smoothstep(0.55f, 1.0f, r));
    return float4(in.color.rgb, a);
}
