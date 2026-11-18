#include <metal_stdlib>
using namespace metal;

[[stitchable]] half4 lyricsViewportFade(
    float2 position,
    half4 color,
    float4 viewportMap,
    float2 bottomEdge
) {
    float viewportY = viewportMap.x + position.y * viewportMap.y;
    float topStart = viewportMap.z;
    float topEnd = viewportMap.w;
    if (viewportY <= topStart || viewportY >= bottomEdge.y) {
        return half4(0.0h);
    }
    float topAlpha = topEnd > topStart ? smoothstep(topStart, topEnd, viewportY) : 1.0f;
    float bottomAlpha = bottomEdge.y > bottomEdge.x ? 1.0f - smoothstep(bottomEdge.x, bottomEdge.y, viewportY) : 1.0f;
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
