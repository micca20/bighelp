#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// Placeholder art for generated media: nine theme colors drift as soft pools
/// of light. `flow` tightens the pools, `grain` adds film noise.
[[ stitchable ]] half4 generatedMediaGradient(
    float2 position,
    half4 color,
    float4 boundingRect,
    float time,
    float speed,
    float flow,
    float grain,
    float brightness,
    half4 color1,
    half4 color2,
    half4 color3,
    half4 color4,
    half4 color5,
    half4 color6,
    half4 color7,
    half4 color8,
    half4 color9
) {
    float2 size = max(boundingRect.zw, float2(1.0));
    float2 uv = position / size;
    uv.x *= size.x / size.y;
    float aspect = size.x / size.y;
    float t = time * speed * 0.12;
    float3 palette[9] = {
        float3(color1.rgb), float3(color2.rgb), float3(color3.rgb),
        float3(color4.rgb), float3(color5.rgb), float3(color6.rgb),
        float3(color7.rgb), float3(color8.rgb), float3(color9.rgb),
    };
    float3 sum = float3(0.0);
    float weight = 0.0;
    for (int i = 0; i < 9; i++) {
        float fi = float(i);
        float2 center = float2(
            aspect * (0.5 + 0.45 * sin(t * (0.61 + 0.07 * fi) + fi * 2.39)),
            0.5 + 0.45 * cos(t * (0.53 + 0.05 * fi) + fi * 1.71)
        );
        float2 offset = uv - center;
        float w = exp(-dot(offset, offset) * (1.8 + flow * 0.45));
        sum += palette[i] * w;
        weight += w;
    }
    float3 result = sum / max(weight, 1e-4) * brightness;
    float noise = fract(sin(dot(position, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
    result += noise * grain * 0.04;
    return half4(half3(clamp(result, 0.0, 1.0)), 1.0);
}
