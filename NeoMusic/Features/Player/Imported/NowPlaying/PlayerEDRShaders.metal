#include <metal_stdlib>
using namespace metal;

struct PlayerEDRVarying { float4 position [[position]]; float2 uv; };

vertex PlayerEDRVarying playerEDRVertex(uint id [[vertex_id]]) {
    float2 positions[] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
    float2 coordinates[] = { float2(0,1), float2(1,1), float2(0,0), float2(1,0) };
    return { float4(positions[id], 0, 1), coordinates[id] };
}

fragment float4 playerEDRFragment(PlayerEDRVarying in [[stage_in]],
    texture2d<float> mask [[texture(0)]], texture2d<float> backdrop [[texture(1)]],
    constant float4 &rect [[buffer(0)]], constant float2 &options [[buffer(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float alpha = mask.sample(s, in.uv).a;
    float3 background = backdrop.sample(s, rect.xy + in.uv * rect.zw).rgb;
    float3 color = options.y > 0.5 ? float3(1.0) : float3(1.0) + background * 0.65;
    return float4(color * (2.0 * options.x) * alpha, alpha);
}
