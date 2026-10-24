#include <metal_stdlib>
using namespace metal;

// Layouts match TerminalUniforms and GlyphInstance in Swift: keep them in sync.
struct Uniforms {
    float2 viewport;
    float2 cellSize;
    float2 padding;
    uint2 grid;
    float4 background;
    float4 cursorColor;
    float4 cursorTextColor;
    float4 cursorRect;
    float cursorAlpha;
    uint cursorStyle;
    float scrollOffset;
};

struct GlyphInstance {
    ushort2 grid;
    short2 offset;
    ushort2 size;
    ushort2 atlas;
    uchar4 color;
    uchar texture;
    uchar flags;
    ushort padding;
};

constant uint solidFlag = 1;
constant uint cursorGlyphFlag = 2;

// Backgrounds, selection and cursor in one fullscreen triangle: no per-cell geometry.
vertex float4 backgroundVertex(uint vid [[vertex_id]]) {
    float2 position = float2((vid << 1) & 2, vid & 2);
    return float4(position * 2.0 - 1.0, 0.0, 1.0);
}

fragment half4 backgroundFragment(float4 position [[position]],
                                  const device uint *cells [[buffer(0)]],
                                  constant Uniforms &u [[buffer(1)]]) {
    half4 color = half4(u.background);
    float2 point = position.xy - u.padding - float2(0.0, u.scrollOffset);
    // Row slots start one row above the viewport: slot 0 is the overscan row.
    int2 cell = int2(floor(point / u.cellSize)) + int2(0, 1);
    // The overscan rows only slide in while scrolling: the padding never shows them.
    bool inGrid = position.y >= u.padding.y && position.y < u.padding.y + float(u.grid.y) * u.cellSize.y;
    if (inGrid && all(cell >= 0) && cell.x < int(u.grid.x) && cell.y < int(u.grid.y) + 2) {
        uint packed = cells[cell.y * int(u.grid.x) + cell.x];
        if (packed >> 24) {
            color = half4(unpack_unorm4x8_to_half(packed).rgb, 1.0h);
        }
    }
    float4 r = u.cursorRect;
    bool inside = all(position.xy >= r.xy) && all(position.xy < r.xy + r.zw);
    if (inside && u.cursorAlpha > 0.0) {
        // Style 3 is the hollow block: only a frame of the rectangle is painted.
        float edge = max(1.0, floor(u.cellSize.y / 16.0));
        bool frame = any(position.xy < r.xy + edge) || any(position.xy >= r.xy + r.zw - edge);
        if (u.cursorStyle != 3 || frame) {
            color = mix(color, half4(u.cursorColor), half(u.cursorAlpha));
        }
    }
    return color;
}

struct TextVertex {
    float4 position [[position]];
    float2 atlas;
    half4 color;
    uint texture [[flat]];
    uint flags [[flat]];
};

vertex TextVertex textVertex(uint vid [[vertex_id]],
                             uint iid [[instance_id]],
                             const device GlyphInstance *instances [[buffer(0)]],
                             constant Uniforms &u [[buffer(1)]]) {
    GlyphInstance glyph = instances[iid];
    float2 corner = float2(vid & 1, vid >> 1);
    float2 slot = float2(glyph.grid) - float2(0.0, 1.0);
    float2 topLeft = u.padding + slot * u.cellSize + float2(glyph.offset) + float2(0.0, u.scrollOffset);
    float2 pixel = topLeft + corner * float2(glyph.size);
    TextVertex out;
    out.position = float4(pixel / u.viewport * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    out.atlas = float2(glyph.atlas) + corner * float2(glyph.size);
    half4 color = half4(glyph.color) / 255.0h;
    if ((glyph.flags & cursorGlyphFlag) && u.cursorStyle == 0) {
        color.rgb = mix(color.rgb, half3(u.cursorTextColor.rgb), half(u.cursorAlpha));
    }
    out.color = color;
    out.texture = glyph.texture;
    out.flags = glyph.flags;
    return out;
}

fragment half4 textFragment(TextVertex in [[stage_in]],
                            texture2d<half> gray [[texture(0)]],
                            texture2d<half> colored [[texture(1)]]) {
    constexpr sampler pixels(coord::pixel, filter::nearest, address::clamp_to_edge);
    if (in.flags & solidFlag) {
        return half4(in.color.rgb * in.color.a, in.color.a);
    }
    if (in.texture == 1) {
        return colored.sample(pixels, in.atlas) * in.color.a;
    }
    half coverage = gray.sample(pixels, in.atlas).r * in.color.a;
    return half4(in.color.rgb * coverage, coverage);
}
