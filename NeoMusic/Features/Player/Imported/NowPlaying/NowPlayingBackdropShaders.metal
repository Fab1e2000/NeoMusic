#include <metal_stdlib>
using namespace metal;

struct BackdropVarying {
    float4 position [[position]];
    float2 uv;
};

struct BackdropComposeUniforms {
    // x = time (s), y = aspect (w/h), z = pageMix (0 artwork, 1 lyrics/queue), w = contrastFactor
    float4 timing;
    // x = meanL, y = p10L, z = p85L, w = meanC
    float4 coverStats;
    // x = accentA, y = accentB, z = accentStrength, w = satBoost
    float4 accent;
};

struct BackdropBlurUniforms {
    // x = 1/srcW, y = 1/srcH, z = offsetRadius, w = unused
    float4 texel;
};

struct BackdropConditionUniforms {
    // x = pageMix, y = crossfade (0..1), z = hasFrozen (0/1), w = contrastFactor
    float4 params;
    // x = meanL, y = meanC, z = accentA, w = accentB
    float4 coverStats;
    // x = targetCenterL, y = lSpreadScale, z = accentStrength, w = reserved
    float4 tone;
};

struct BackdropPresentUniforms {
    // x = pageMix, y = topShade, z = bottomShade, w = ditherScale
    float4 params;
};

vertex BackdropVarying backdropVertex(uint id [[vertex_id]]) {
    float2 positions[] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 coordinates[] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
    return { float4(positions[id], 0, 1), coordinates[id] };
}

static inline float3 linearToOklab(float3 rgb) {
    float3 c = max(rgb, float3(0.0));
    float l = 0.4122214708f * c.x + 0.5363325363f * c.y + 0.0514459929f * c.z;
    float m = 0.2119034982f * c.x + 0.6806995451f * c.y + 0.1073969566f * c.z;
    float s = 0.0883024619f * c.x + 0.2817188376f * c.y + 0.6299787005f * c.z;
    float l_ = pow(max(l, 0.0f), 1.0f / 3.0f);
    float m_ = pow(max(m, 0.0f), 1.0f / 3.0f);
    float s_ = pow(max(s, 0.0f), 1.0f / 3.0f);
    return float3(
        0.2104542553f * l_ + 0.7936177850f * m_ - 0.0040720468f * s_,
        1.9779984951f * l_ - 2.4285922050f * m_ + 0.4505937099f * s_,
        0.0259040371f * l_ + 0.7827717662f * m_ - 0.8086757660f * s_
    );
}

static inline float3 oklabToLinearRaw(float3 lab) {
    float l_ = lab.x + 0.3963377774f * lab.y + 0.2158037573f * lab.z;
    float m_ = lab.x - 0.1055613458f * lab.y - 0.0638541728f * lab.z;
    float s_ = lab.x - 0.0894841775f * lab.y - 1.2914855480f * lab.z;
    float l = l_ * l_ * l_;
    float m = m_ * m_ * m_;
    float s = s_ * s_ * s_;
    return float3(
         4.0767416621f * l - 3.3077115913f * m + 0.2309699292f * s,
        -1.2684380046f * l + 2.6097574011f * m - 0.3413193965f * s,
        -0.0041960863f * l - 0.7034186147f * m + 1.7076147010f * s
    );
}

static inline float3 oklabToLinearSafe(float3 lab) {
    lab.x = clamp(lab.x, 0.0f, 1.0f);
    float3 rgb = oklabToLinearRaw(lab);
    if (all(rgb >= 0.0f) && all(rgb <= 1.0f)) {
        return rgb;
    }
    // Binary search chroma scale toward neutral gray at the same perceptual lightness L.
    float lo = 0.0f;
    float hi = 1.0f;
    for (int i = 0; i < 6; ++i) {
        float mid = 0.5f * (lo + hi);
        float3 candidate = oklabToLinearRaw(float3(lab.x, lab.y * mid, lab.z * mid));
        if (all(candidate >= 0.0f) && all(candidate <= 1.0f)) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    return clamp(oklabToLinearRaw(float3(lab.x, lab.y * lo, lab.z * lo)), 0.0f, 1.0f);
}

static inline float2 rotate2D(float2 p, float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return float2(p.x * c - p.y * s, p.x * s + p.y * c);
}

static inline float2 warpLayerUV(float2 p, float t, float phase) {
    float2 q = p;
    float r = length(q);
    // Gentle polar twist that melts sharp cover edges into organic blobs.
    float twist = sin(t * 0.13f + phase) * 0.42f * exp(-r * 1.35f);
    q = rotate2D(q, twist);
    // Low-frequency smooth curl displacement.
    q.x += sin(q.y * 3.1f + t * 0.27f + phase) * 0.065f
         + cos((q.x + q.y) * 2.2f - t * 0.19f) * 0.040f;
    q.y += cos(q.x * 3.3f - t * 0.23f + phase * 0.7f) * 0.065f
         + sin((q.x - q.y) * 2.5f + t * 0.21f) * 0.040f;
    return q;
}

static inline float3 sampleArtworkOklab(
    texture2d<float> artwork,
    sampler s,
    float2 uv,
    float satBoost,
    float highlightCap
) {
    float3 lin = artwork.sample(s, uv).rgb;
    float3 lab = linearToOklab(lin);
    // Softly compress outlier white logos/text so they don't wash out nearby dark regions,
    // without crushing saturated mid-luminance colors on dark covers.
    if (lab.x > highlightCap) {
        lab.x = highlightCap + (lab.x - highlightCap) * 0.45f;
    }
    lab.yz *= satBoost;
    return lab;
}

fragment float4 fluidBackdropComposeFragment(
    BackdropVarying in [[stage_in]],
    texture2d<float> artwork [[texture(0)]],
    constant BackdropComposeUniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::mirrored_repeat);
    float t = u.timing.x;
    float aspect = max(u.timing.y, 0.25f);
    float highlightCap = max(clamp(u.coverStats.z, 0.15f, 0.95f), 0.62f);
    float satBoost = u.accent.w * 1.08f;

    // Aspect-corrected centered coordinates: y in [-0.5, 0.5], x in [-aspect*0.5, aspect*0.5].
    float2 p = (in.uv - 0.5f) * float2(aspect, 1.0f);

    // Layer 0: Broad base canvas (covers entire viewport, slow rotation).
    float2 p0 = warpLayerUV(rotate2D(p, t * 0.032f + 0.18f) / 1.35f, t, 0.0f);
    float3 lab0 = sampleArtworkOklab(artwork, s, p0 + 0.5f, satBoost, highlightCap);

    // Layer 1: Upper primary glow / color mass.
    float2 c1 = float2(0.08f * cos(t * 0.10f + 0.8f), -0.18f + 0.09f * sin(t * 0.08f + 0.3f));
    float2 d1 = p - c1;
    float2 p1 = warpLayerUV(rotate2D(d1, -t * 0.055f + 1.05f) / 0.98f, t, 1.7f);
    float3 lab1 = sampleArtworkOklab(artwork, s, p1 + 0.5f, satBoost * 1.06f, highlightCap);
    float w1 = exp(-dot(d1, d1) * 3.4f) * 0.90f;

    // Layer 2: Highlight / mid-upper accent swatch (brightens upper-right / upper-left blobs).
    float2 c2 = float2(-0.04f + 0.16f * sin(t * 0.13f + 2.1f), -0.06f + 0.18f * cos(t * 0.09f + 0.9f));
    float2 d2 = p - c2;
    float2 p2 = warpLayerUV(rotate2D(d2, t * 0.075f - 0.72f) / 0.78f, t, 3.1f);
    float3 lab2 = sampleArtworkOklab(artwork, s, p2 + 0.5f, satBoost * 1.12f, highlightCap);
    float w2 = exp(-dot(d2, d2) * 4.4f) * 0.72f;

    // Layer 3: Lower counterweight swatch (adds depth & darker lower balance).
    float2 c3 = float2(0.11f * sin(t * 0.09f + 3.6f), 0.20f + 0.12f * cos(t * 0.11f + 2.2f));
    float2 d3 = p - c3;
    float2 p3 = warpLayerUV(rotate2D(d3, -t * 0.048f + 2.35f) / 0.86f, t, 4.9f);
    float3 lab3 = sampleArtworkOklab(artwork, s, p3 + 0.5f, satBoost * 0.96f, highlightCap);
    float w3 = exp(-dot(d3, d3) * 3.8f) * 0.75f;

    float w0 = 1.0f;
    float totalW = w0 + w1 + w2 + w3;
    float3 blended = (lab0 * w0 + lab1 * w1 + lab2 * w2 + lab3 * w3) / totalW;

    // Preserve linear light before Kawase pyramid blur.
    return float4(oklabToLinearSafe(blended), 1.0f);
}

fragment float4 kawaseDownsampleFragment(
    BackdropVarying in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    constant BackdropBlurUniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 hp = u.texel.xy * u.texel.z;
    float3 sum = source.sample(s, in.uv).rgb * 4.0f;
    sum += source.sample(s, in.uv - hp).rgb;
    sum += source.sample(s, in.uv + hp).rgb;
    sum += source.sample(s, in.uv + float2(hp.x, -hp.y)).rgb;
    sum += source.sample(s, in.uv + float2(-hp.x, hp.y)).rgb;
    return float4(sum / 8.0f, 1.0f);
}

fragment float4 kawaseUpsampleFragment(
    BackdropVarying in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    constant BackdropBlurUniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 hp = u.texel.xy * u.texel.z;
    float3 sum = 0.0f;
    sum += source.sample(s, in.uv + float2(-hp.x * 2.0f, 0.0f)).rgb;
    sum += source.sample(s, in.uv + float2( hp.x * 2.0f, 0.0f)).rgb;
    sum += source.sample(s, in.uv + float2(0.0f, -hp.y * 2.0f)).rgb;
    sum += source.sample(s, in.uv + float2(0.0f,  hp.y * 2.0f)).rgb;
    sum += source.sample(s, in.uv + float2(-hp.x,  hp.y)).rgb * 2.0f;
    sum += source.sample(s, in.uv + float2( hp.x,  hp.y)).rgb * 2.0f;
    sum += source.sample(s, in.uv + float2(-hp.x, -hp.y)).rgb * 2.0f;
    sum += source.sample(s, in.uv + float2( hp.x, -hp.y)).rgb * 2.0f;
    return float4(sum / 12.0f, 1.0f);
}

fragment float4 fluidBackdropConditionFragment(
    BackdropVarying in [[stage_in]],
    texture2d<float> blurred [[texture(0)]],
    texture2d<float> globalAvg [[texture(1)]],
    texture2d<float> frozen [[texture(2)]],
    constant BackdropConditionUniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float crossfade = clamp(u.params.y, 0.0f, 1.0f);
    float hasFrozen = u.params.z;
    float contrastFactor = u.params.w;

    float3 localLin = blurred.sample(s, in.uv).rgb;
    float3 avgLin = globalAvg.sample(s, float2(0.5f, 0.5f)).rgb;

    // Unified gentle pull toward ambient average: stays calm on Artwork while preserving organic 2D clouds on Lyrics/Queue.
    float3 mixedLin = mix(localLin, avgLin, 0.22f);

    float3 lab = linearToOklab(mixedLin);
    float3 avgLab = linearToOklab(avgLin);

    // Center perceptual lightness around the cover's calibrated target with balanced local contrast.
    float targetCenterL = u.tone.x;
    float spread = u.tone.y * 0.96f * contrastFactor;
    float finalL = clamp(targetCenterL + (lab.x - avgLab.x) * spread, 0.14f, 0.74f);

    // Boost chroma subtly in Oklab on rich covers, while softening stray color wash on mostly-white covers.
    float chromaScale = mix(1.18f, 0.75f, clamp((avgLab.x - 0.70f) / 0.20f, 0.0f, 1.0f));
    float2 ab = lab.yz * chromaScale;
    float localC = length(ab);
    float accentStrength = u.tone.z;
    float2 accentAB = u.coverStats.zw;
    float accentC = length(accentAB);
    if (accentStrength > 0.08f && accentC > 0.004f) {
        float2 accentDir = accentAB / accentC;
        float floorC = min(accentC, 0.11f) * 0.52f * accentStrength * clamp((0.78f - avgLab.x) / 0.18f, 0.0f, 1.0f);
        if (localC < floorC) {
            ab += accentDir * (floorC - localC);
        }
    }

    float3 conditioned = oklabToLinearSafe(float3(finalL, ab.x, ab.y));

    if (hasFrozen > 0.5f && crossfade < 0.999f) {
        float3 prev = frozen.sample(s, in.uv).rgb;
        // Standard easeInOut cubic Bezier approximation (0.42, 0, 0.58, 1).
        float eased = crossfade * crossfade * (3.0f - 2.0f * crossfade);
        conditioned = mix(prev, conditioned, eased);
    }

    return float4(conditioned, 1.0f);
}

static inline float3 linearToSRGB(float3 c) {
    float3 lo = c * 12.92f;
    float3 hi = 1.055f * pow(max(c, float3(0.0031308f)), float3(1.0f / 2.4f)) - 0.055f;
    return select(hi, lo, c <= 0.0031308f);
}

static inline float ignNoise(float2 pos) {
    float3 magic = float3(0.06711056f, 0.00583715f, 52.9829189f);
    return fract(magic.z * fract(dot(pos, magic.xy)));
}

fragment float4 fluidBackdropPresentFragment(
    BackdropVarying in [[stage_in]],
    texture2d<float> conditioned [[texture(0)]],
    constant BackdropPresentUniforms &u [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 lin = conditioned.sample(s, in.uv).rgb;

    // Fast hue-exact perceptual vertical vignette in linear space (equivalent to Oklab L *= shade without per-pixel gamut search).
    float vRamp = smoothstep(0.10f, 0.96f, in.uv.y);
    float shade = mix(u.params.y, u.params.z, vRamp);
    float3 finalLinear = clamp(lin * (shade * shade * shade), 0.0f, 1.0f);
    float3 srgb = linearToSRGB(finalLinear);

    // Triangular PDF dithering (1 LSB) to eliminate dark-region banding on OLED displays.
    float n1 = ignNoise(in.position.xy);
    float n2 = ignNoise(in.position.xy + float2(17.0f, 31.0f));
    float dither = (n1 + n2 - 1.0f) * u.params.w;
    return float4(clamp(srgb + dither, 0.0f, 1.0f), 1.0f);
}

[[stitchable]] half4 lyricsViewportFade(
    float2 position,
    half4 color,
    float4 viewportMap,
    float bottomEnd
) {
    float viewportY = viewportMap.x + position.y * viewportMap.y;
    if (viewportY <= 0.0f || viewportY >= bottomEnd) {
        return half4(0.0h);
    }
    float topEnd = viewportMap.z;
    float bottomStart = viewportMap.w;
    float topAlpha = topEnd > 0.0f ? clamp(viewportY / topEnd, 0.0f, 1.0f) : 1.0f;
    float bottomSpan = bottomEnd - bottomStart;
    float bottomAlpha = bottomSpan > 0.0f ? clamp((bottomEnd - viewportY) / bottomSpan, 0.0f, 1.0f) : 1.0f;
    return color * half(min(topAlpha, bottomAlpha));
}

[[stitchable]] half4 trackSwipeHorizontalFade(
    float2 position,
    half4 color,
    float4 edgeBounds,
    float rightEnd
) {
    // edgeBounds: (slotOffsetX, leftStart, fadeInEnd, fadeOutStart)
    float x = position.x + edgeBounds.x;
    if (x <= edgeBounds.y || x >= rightEnd) {
        return half4(0.0h);
    }
    float leadSpan = edgeBounds.z - edgeBounds.y;
    float trailSpan = rightEnd - edgeBounds.w;
    float leadAlpha = leadSpan > 0.0f ? clamp((x - edgeBounds.y) / leadSpan, 0.0f, 1.0f) : 1.0f;
    float trailAlpha = trailSpan > 0.0f ? clamp((rightEnd - x) / trailSpan, 0.0f, 1.0f) : 1.0f;
    return color * half(min(leadAlpha, trailAlpha));
}
