#include <metal_stdlib>

using namespace metal;

#include "shader_types.h"

constant float EPSILON = 0.00001;

// Vertex shader outputs and fragment shader inputs
struct RectFragmentData
{
    float4 position [[position]];
    float2 pixel_position [[pixel_position]];
    float2 rect_origin;
    float2 rect_size;
    float2 rect_center;
    float2 rect_corner;
    float border_top;
    float border_right;
    float border_bottom;
    float border_left;
    float corner_radius_top_left;
    float corner_radius_top_right;
    float corner_radius_bottom_left;
    float corner_radius_bottom_right;
    float2 background_start;
    float2 background_end;
    float4 background_start_color;
    float4 background_end_color;
    float2 border_start;
    float2 border_end;
    float4 border_start_color;
    float4 border_end_color;
    float2 texture_coordinate;
    bool is_icon;
    float4 icon_color;
    float2 drop_shadow_offsets;
    float4 drop_shadow_color;
    float drop_shadow_sigma;
    float drop_shadow_padding_factor;
    float dash_length;
    float2 gap_lengths;
};

struct GlyphFragmentData
{
    float4 position [[position]];
    float2 rect_center;
    float2 rect_corner;
    float2 texture_coordinate;
    float fade_alpha;
    float4 color;
    bool is_emoji;
};


float distance_from_rect(vector_float2 pixel_pos, vector_float2 rect_center, vector_float2 rect_corner, float corner_radius) {
    vector_float2 p = pixel_pos - rect_center;
    vector_float2 q = abs(p) - rect_corner + corner_radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - corner_radius;
}

float4 derive_color(float2 pixel_pos, float2 start, float2 end, float4 start_color, float4 end_color) {
    float2 adjusted_end = end - start;
    float h = dot(pixel_pos - start, adjusted_end) / dot(adjusted_end, adjusted_end);
    return mix(start_color, end_color, h);
}

vertex RectFragmentData
rect_vertex_shader(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    constant float2 *vertices [[buffer(0)]],
    constant PerRectUniforms *glyph_uniforms [[buffer(1)]],
    constant Uniforms *uniforms [[buffer(2)]])
{
    const constant PerRectUniforms *rect = &glyph_uniforms[instance_id];

    float2 pixel_pos = vertices[vertex_id] * rect->size + rect->origin;
    float2 device_pos = pixel_pos / uniforms->viewport_size * float2(2.0, -2.0) + float2(-1.0, 1.0);

    RectFragmentData out;
    out.position = float4(device_pos, 0.0, 1.0);
    out.pixel_position = pixel_pos;
    out.rect_origin = rect->origin;
    out.rect_size = rect->size;
    out.rect_corner = rect->size / 2.0;
    out.rect_center = rect->origin + out.rect_corner;
    out.border_top = rect->border_top;
    out.border_right = rect->border_right;
    out.border_bottom = rect->border_bottom;
    out.border_left = rect->border_left;
    out.corner_radius_top_left = rect->corner_radius_top_left;
    out.corner_radius_top_right = rect->corner_radius_top_right;
    out.corner_radius_bottom_left = rect->corner_radius_bottom_left;
    out.corner_radius_bottom_right = rect->corner_radius_bottom_right;
    out.background_start = rect->background_start * rect->size + rect->origin;
    out.background_end = rect->background_end * rect->size + rect->origin;
    out.background_start_color = rect->background_start_color;
    out.background_end_color = rect->background_end_color;
    out.border_start = rect->border_start * rect->size + rect->origin;
    out.border_end = rect->border_end * rect->size + rect->origin;
    out.border_start_color = rect->border_start_color;
    out.border_end_color = rect->border_end_color;
    out.texture_coordinate = vertices[vertex_id];
    out.is_icon = rect->is_icon;
    out.icon_color = rect->icon_color;
    out.drop_shadow_offsets = rect->drop_shadow_offsets;
    out.drop_shadow_color = rect->drop_shadow_color;
    out.drop_shadow_sigma = rect->drop_shadow_sigma;
    out.drop_shadow_padding_factor = rect->drop_shadow_padding_factor;
    out.dash_length = rect->dash_length;
    out.gap_lengths = rect->gap_lengths;
    return out;
}

// Drop shadow code *heavily* inspired by this post:
// http://madebyevan.com/shaders/fast-rounded-rectangle-shadows/

// A standard gaussian function, used for weighting samples
float gaussian(float x, float sigma) {
  const float pi = 3.141592653589793;
  return exp(-(x * x) / (2.0 * sigma * sigma)) / (sqrt(2.0 * pi) * sigma);
}

// This approximates the error function, needed for the gaussian integral
float2 erf(float2 x) {
  float2 s = sign(x), a = abs(x);
  x = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
  x *= x;
  return s - s / (x * x);
}

// Return the blurred mask along the x dimension
float roundedBoxShadowX(float x, float y, float sigma, float corner, float2 halfSize) {
  float delta = min(halfSize.y - corner - abs(y), 0.0);
  float curved = halfSize.x - corner + sqrt(max(0.0, corner * corner - delta * delta));
  float2 integral = 0.5 + 0.5 * erf((x + float2(-curved, curved)) * (sqrt(0.5) / sigma));
  return integral.y - integral.x;
}

// Return the mask for the shadow of a box from lower to upper
float roundedBoxShadow(float2 lower, float2 upper, float2 point, float sigma, float corner) {
  // Center everything to make the math easier
  float2 center = (lower + upper) * 0.5;
  float2 halfSize = (upper - lower) * 0.5;
  point -= center;

  // The signal is only non-zero in a limited range, so don't waste samples
  float low = point.y - halfSize.y;
  float high = point.y + halfSize.y;
  float start = clamp(-3.0 * sigma, low, high);
  float end = clamp(3.0 * sigma, low, high);

  // Accumulate samples (we can get away with surprisingly few samples)
  float step = (end - start) / 4.0;
  float y = start + step * 0.5;
  float value = 0.0;
  for (int i = 0; i < 4; i++) {
    value += roundedBoxShadowX(point.x, point.y - y, sigma, corner, halfSize) * gaussian(y, sigma) * step;
    y += step;
  }

  return value;
}

fragment float4 rect_fragment_shader(
    RectFragmentData in [[stage_in]],
    constant Uniforms *uniforms [[buffer(0)]])
{
    float outer_distance;
    float inner_distance;
    // There are actually two different radii at play here - the inner
    // (background) and outer (shape) radii.  The inner radius is equal to the
    // outer radius minus the border width, in order for the two curves to
    // maintain a constant distance from each other.
    float outer_corner_radius;
    float inner_corner_radius;

    // Length along the perimeter of (rounded) rectangle, starting from top left.
    float length_along = 0.;
    float2 pos_from_origin = in.position.xy - in.rect_origin;

    float2 border_inner_corner = in.rect_corner;
    if (in.position.y >= in.rect_center.y) {
        // Bottom half
        border_inner_corner.y -= in.border_bottom;
        if (in.position.x >= in.rect_center.x) {
            // Bottom right quadrant
            border_inner_corner.x -= in.border_right;
            outer_corner_radius = in.corner_radius_bottom_right;
            inner_corner_radius = max(0.0, outer_corner_radius - in.border_bottom);
        } else {
            // Bottom left quadrant
            border_inner_corner.x -= in.border_left;
            outer_corner_radius = in.corner_radius_bottom_left;
            inner_corner_radius = max(0.0, outer_corner_radius - in.border_bottom);
        }
    } else {
        // Top half
        border_inner_corner.y -= in.border_top;
        if (in.position.x >= in.rect_center.x) {
            // Top right quadrant
            border_inner_corner.x -= in.border_right;
            outer_corner_radius = in.corner_radius_top_right;
            inner_corner_radius = max(0.0, outer_corner_radius - in.border_top);
        } else {
            // Top left quadrant
            border_inner_corner.x -= in.border_left;
            outer_corner_radius = in.corner_radius_top_left;
            inner_corner_radius = max(0.0, outer_corner_radius - in.border_top);
        }
    }

    float2 rect_bottom_right = in.rect_origin + in.rect_size;

    outer_distance = distance_from_rect(in.position.xy, in.rect_center, in.rect_corner, outer_corner_radius);
    inner_distance = distance_from_rect(in.position.xy, in.rect_center, border_inner_corner, inner_corner_radius);

    float4 color;
    if (in.drop_shadow_sigma > 0) {
        color = in.drop_shadow_color;
        // When we are rendering a drop shadow we need to pass in the positions
        // of the original rect, so we figure them out from the padding.
        // Note we subtract twice the padding, because the padding is specified
        // in terms of padding on a single side.
        float2 shadowed_rect_origin = in.rect_origin + in.drop_shadow_padding_factor;
        float2 shadowed_rect_size = in.rect_size - 2 * in.drop_shadow_padding_factor;
        color.a *= roundedBoxShadow(
                    shadowed_rect_origin,
                    shadowed_rect_origin + shadowed_rect_size,
                    in.pixel_position,
                    in.drop_shadow_sigma,
                    outer_corner_radius);
    } else {
        // Solid fill case (not a drop shadow)
        float4 background_color = derive_color(in.position.xy, in.background_start, in.background_end, in.background_start_color, in.background_end_color);
        float4 border_color = derive_color(in.position.xy, in.border_start, in.border_end, in.border_start_color, in.border_end_color);

        // Adjust the opacity of the border color based on where the pixel lies
        // between the background and the border.
        border_color.a *= saturate(inner_distance + 0.5);

        // Force the alpha value to 0 (fully transparent) if the pixel is
        // outside the border.
        //
        // When we are outside the border, outer_distance is a larger positive
        // value than inner_distance.  When we are inside the border itself,
        // outer_distance is negative and inner_distance is positive.  When we
        // are inside the inner border edge, outer_distance is more negative
        // than inner_distance.
        border_color.a *= inner_distance > outer_distance;

        // Masks for pixels outside of inner rectangle or on border
        bool is_horizontal_border = (in.position.y <= in.rect_origin.y + in.border_top) || (in.position.y >= rect_bottom_right.y - in.border_bottom);
        bool is_vertical_border = (in.position.x <= in.rect_origin.x + in.border_left) || (in.position.x >= rect_bottom_right.x - in.border_right);

        // Get length along the dash and gap segment and determine if pixel is in dash or gap
        float length_on_dash_and_gap_segment_x = fmod(pos_from_origin.x, in.dash_length + in.gap_lengths.x);
        float length_on_dash_and_gap_segment_y = fmod(pos_from_origin.y, in.dash_length + in.gap_lengths.y);
        bool is_horizontal_dash = is_horizontal_border && (length_on_dash_and_gap_segment_x < in.dash_length);
        bool is_vertical_dash = is_vertical_border && (length_on_dash_and_gap_segment_y < in.dash_length);

        // Mask out any gaps in the border
        border_color.a *= in.dash_length <= 0 || (is_horizontal_dash || is_vertical_dash);

        // Perform proper alpha blending on the two colors, avoiding a
        // divide-by-zero if both colors are fully transparent.
        //
        // See formula for "over" compositing here: https://en.wikipedia.org/wiki/Alpha_compositing#Alpha_blending
        float alpha = border_color.a + background_color.a * (1.0 - border_color.a);
        color.rgb = (border_color.rgb * border_color.a + background_color.rgb * background_color.a * (1.0 - border_color.a)) / (alpha + EPSILON);
        color.a = alpha;
    }

    // If there's a corner radius we need to do some anti aliasing to smooth out the rounded corner effect.
    if (outer_corner_radius > 0) {
        color.a *= 1.0 - saturate(outer_distance + 0.5);
    }

    return color;
}

fragment float4 image_fragment_shader(
    RectFragmentData in [[stage_in]],
    texture2d<half> color_texture [[ texture(0) ]])
{
    constexpr sampler texture_sampler (mag_filter::linear,
                                       min_filter::linear);

    // Sample the texture to obtain a color
    const half4 color_sample = color_texture.sample(texture_sampler, in.texture_coordinate);

    float4 color;
    // If the image is an icon, use the provided icon_color instead of sampling from texture
    if (in.is_icon) {
        vector_float4 in_color = in.icon_color;
        in_color.a *= color_sample.r;
        color = float4(in_color);
    } else {
        color = float4(color_sample);
        color.a *= in.icon_color.a;
    }

    float outer_corner_radius;

    if (in.position.y >= in.rect_center.y) {
        // Bottom half
        if (in.position.x >= in.rect_center.x) {
            // Bottom right quadrant
            outer_corner_radius = in.corner_radius_bottom_right;
        } else {
            // Bottom left quadrant
            outer_corner_radius = in.corner_radius_bottom_left;
        }
    } else {
        // Top half
        if (in.position.x >= in.rect_center.x) {
            // Top right quadrant
            outer_corner_radius = in.corner_radius_top_right;
        } else {
            // Top left quadrant
            outer_corner_radius = in.corner_radius_top_left;
        }
    }

    float outer_distance = distance_from_rect(in.position.xy, in.rect_center, in.rect_corner, outer_corner_radius);

    // If there's a corner radius we need to do some anti aliasing to smooth out the rounded corner effect.
    if (outer_corner_radius > 0) {
        color.a *= 1.0 - saturate(outer_distance + 0.5);
    }
    return color;
}

vertex GlyphFragmentData
glyph_vertex_shader(
        uint vertex_id [[vertex_id]],
        uint instance_id [[instance_id]],
        constant vector_float2 *vertices [[buffer(0)]],
        const device PerGlyphUniforms *glyph_uniforms [[buffer(1)]],
        constant Uniforms *uniforms [[buffer(2)]])
{
    const device PerGlyphUniforms *glyph = &glyph_uniforms[instance_id];

    float2 pixel_pos = vertices[vertex_id] * glyph->size + glyph->origin;
    // Use floor here to vertically align the glyph to the pixel grid.
    // If it's not aligned to the grid, the fragment shader will do its
    // own interpolation, which makes it so we don't use the anti-aliasing
    // from core text, which is what we want.  We don't force the glyph to a
    // horizontal pixel position because we rasterize the glyph at multiple
    // subpixel positions, and so the very slight linear interpolation here
    // won't produce a fuzzy glyph, just a correctly-positioned one.
    pixel_pos = float2(pixel_pos.x, floor(pixel_pos.y));

    // Evaluating the glyphs fade effect. Note that the fade may go in two different directions:
    // - Right to left (default) - where the opaque side is on the right, and transparent on the left
    //   (in this case, the start_fade < end_fade; start is where the fade is transparent)
    // - Left to right - where the opaque side is on the left, and it fades towards the right side.
    //   In this case, start_fade > end_fade, and the opaque side is on the left (end_fade).
    // To clarify: fade_start is ALWAYS where the fade is transparent, and fade_end is ALWAYS where
    // the opaque part is, this is reflected in how we compute width, dist, and alpha.
    float fade_width = fabs(glyph->fade_end - glyph->fade_start);
    float fade_dist = pixel_pos.x - fmin(glyph->fade_start, glyph->fade_end);

    float fade_alpha;
    if (glyph->fade_end < glyph->fade_start) { // left-to-right case
      fade_alpha = fade_dist / fade_width;
    } else { // right-to-left case
      fade_alpha = 1 - fade_dist / fade_width;
    }

    vector_float2 device_pos = pixel_pos / uniforms->viewport_size * vector_float2(2.0, -2.0) + vector_float2(-1.0, 1.0);

    vector_float2 texture_coordinate  = vector_float2(glyph->uv_left, glyph->uv_top) + vertices[vertex_id] * vector_float2(glyph->uv_width, glyph->uv_height);

    GlyphFragmentData out;
    out.position = vector_float4(device_pos, 0.0, 1.0);
    out.rect_corner = glyph->size / 2.0;
    out.rect_center = glyph->origin + out.rect_corner;
    out.texture_coordinate = texture_coordinate;
    out.fade_alpha = fade_alpha;
    out.color = glyph->color;
    out.is_emoji = glyph->is_emoji;
    return out;
}

fragment float4 glyph_fragment_shader(
    GlyphFragmentData in [[stage_in]],
    texture2d<half> color_texture [[ texture(0) ]]
) {
    // Sample the texture to obtain a color.
    constexpr sampler texture_sampler (mag_filter::linear, min_filter::linear);
    const float4 color_sample = float4(color_texture.sample(texture_sampler, in.texture_coordinate));
    // Use the input color for non-emoji, and the sampled color for emoji.
    float4 color = mix(in.color, color_sample, float(in.is_emoji));
    // Multiply alpha by the sampled color's red channel for non-emoji.
    color.a *= max(color_sample.r, float(in.is_emoji));
    // Apply the fade.
    color.a *= saturate(in.fade_alpha);
    return color;
}

// ============================================================================
// Animated background shader
//
// A full-screen procedural background drawn once, before any rects/images/
// glyphs, so terminal content composites on top of it. This shader is a Metal
// port of the "mesh gradient" effect from paper.design's shader library
// (https://github.com/paper-design/shaders, Apache-2.0): a flowing composition
// of colored spots warped by organic noise and a vortex swirl. The GLSL source
// was translated to Metal Shading Language; the math is otherwise unchanged.
// ============================================================================

struct BackgroundFragmentData
{
    float4 position [[position]];
    // UV centered at (0,0), aspect-corrected so the pattern isn't stretched.
    float2 uv;
};

vertex BackgroundFragmentData
background_vertex_shader(
    uint vertex_id [[vertex_id]],
    constant float2 *vertices [[buffer(0)]],
    constant BackgroundUniforms *uniforms [[buffer(2)]])
{
    // `vertices` is the shared unit quad: (0,0), (1,0), (0,1), (1,1).
    float2 v = vertices[vertex_id];

    BackgroundFragmentData out;
    // Map the unit quad to the full clip-space rectangle [-1, 1].
    out.position = float4(v * 2.0 - 1.0, 0.0, 1.0);

    // Center the UV and correct for aspect ratio so circular features stay
    // circular on wide windows.
    float2 uv = v - 0.5;
    float aspect = uniforms->viewport_size.x / max(uniforms->viewport_size.y, 1.0);
    uv.x *= aspect;
    out.uv = uv;
    return out;
}

// --- helpers (ported from paper.design shader-utils.ts) ---

static float2 bg_rotate(float2 uv, float th) {
    // GLSL mat2(cos, sin, -sin, cos) is column-major: col0=(cos,sin),
    // col1=(-sin,cos). Metal float2x2 takes columns, so this matches exactly.
    return float2x2(float2(cos(th), sin(th)), float2(-sin(th), cos(th))) * uv;
}

static float bg_hash21(float2 p) {
    p = fract(p * float2(0.3183099, 0.3678794)) + 0.1;
    p += dot(p, p + 19.19);
    return fract(p.x * p.y);
}

static float bg_value_noise(float2 st) {
    float2 i = floor(st);
    float2 f = fract(st);
    float a = bg_hash21(i);
    float b = bg_hash21(i + float2(1.0, 0.0));
    float c = bg_hash21(i + float2(0.0, 1.0));
    float d = bg_hash21(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    float x1 = mix(a, b, u.x);
    float x2 = mix(c, d, u.x);
    return mix(x1, x2, u.y);
}

static float2 bg_get_position(int i, float t) {
    float a = float(i) * 0.37;
    float b = 0.6 + fract(float(i) / 3.0) * 0.9;
    float c = 0.8 + fract(float(i + 1) / 4.0);
    float x = sin(t * b + a);
    float y = cos(t * c + a * 1.5);
    return 0.5 + 0.5 * float2(x, y);
}

fragment float4 background_mesh_gradient_fragment_shader(
    BackgroundFragmentData in [[stage_in]],
    constant BackgroundUniforms *uniforms [[buffer(0)]])
{
    const float distortion = 0.85;
    const float swirl = 0.6;
    const float grain_mixer = 0.25;
    const float grain_overlay = 0.10;

    float2 uv = in.uv;
    uv += 0.5;
    float2 grain_uv = uv * 1000.0;

    float grain = bg_value_noise(grain_uv);
    float mixer_grain = 0.4 * grain_mixer * (grain - 0.5);

    const float first_frame_offset = 41.5;
    float t = 0.5 * (uniforms->time + first_frame_offset);

    float radius = smoothstep(0.0, 1.0, length(uv - 0.5));
    float center = 1.0 - radius;
    for (float i = 1.0; i <= 2.0; i++) {
        uv.x += distortion * center / i * sin(t + i * 0.4 * smoothstep(0.0, 1.0, uv.y)) * cos(0.2 * t + i * 2.4 * smoothstep(0.0, 1.0, uv.y));
        uv.y += distortion * center / i * cos(t + i * 2.0 * smoothstep(0.0, 1.0, uv.x));
    }

    float2 uv_rotated = uv - float2(0.5);
    float angle = 3.0 * swirl * radius;
    uv_rotated = bg_rotate(uv_rotated, -angle);
    uv_rotated += float2(0.5);

    float3 color = float3(0.0);
    float total_weight = 0.0;
    for (int i = 0; i < 8; i++) {
        if (i >= uniforms->colors_count) { break; }
        float2 pos = bg_get_position(i, t) + mixer_grain;
        float4 c = uniforms->colors[i];
        float3 color_fraction = c.rgb * c.a;
        float dist = length(uv_rotated - pos);
        dist = pow(dist, 3.5);
        float weight = 1.0 / (dist + 1e-3);
        color += color_fraction * weight;
        total_weight += weight;
    }
    color /= max(1e-4, total_weight);

    // Subtle black/white grain overlay.
    float grain_ov = bg_value_noise(bg_rotate(grain_uv, 1.0) + float2(3.0));
    grain_ov = mix(grain_ov, bg_value_noise(bg_rotate(grain_uv, 2.0) + float2(-1.0)), 0.5);
    grain_ov = pow(grain_ov, 1.3);
    float grain_overlay_v = grain_ov * 2.0 - 1.0;
    float3 grain_overlay_color = float3(step(0.0, grain_overlay_v));
    float grain_overlay_strength = grain_overlay * abs(grain_overlay_v);
    grain_overlay_strength = pow(grain_overlay_strength, 0.8);
    color = mix(color, grain_overlay_color, 0.35 * grain_overlay_strength);

    // Fully opaque: the background establishes the base color that the
    // terminal's own (semi-transparent) surfaces composite over.
    return float4(color, 1.0);
}

// ============================================================================
// Additional background shader effects, ported from paper.design's shader
// library (https://github.com/paper-design/shaders, Apache-2.0). Each effect
// keeps its helpers behind a unique prefix and exposes one fragment function
// named background_<effect>_fragment_shader.
// ============================================================================

// ---- swirl ----
// Metal port of paper.design's "swirl" shader
// (https://github.com/paper-design/shaders, Apache-2.0): animated bands of
// color twisting and bending around a center point, producing spirals, arcs,
// and flowing circular / ripple patterns. Math translated 1:1 from the GLSL
// source; only the color/uniform plumbing was adapted to Warp's
// BackgroundUniforms contract. All helpers are prefixed "swirl_" and this
// file is fully self-contained (no shared bg_* helpers reused).

// --- helpers (ported from paper.design shader-utils.ts: simplexNoise) ---

// GLSL's `mod(x, y)` keeps the sign of `y` (unlike Metal/HLSL `fmod`, which
// keeps the sign of `x`). All call sites below only ever see non-negative
// operands in practice, but we implement true GLSL semantics to be safe.
static float2 swirl_glsl_mod(float2 x, float y) {
    return x - y * floor(x / y);
}
static float3 swirl_glsl_mod(float3 x, float y) {
    return x - y * floor(x / y);
}

static float3 swirl_permute(float3 x) {
    return swirl_glsl_mod(((x * 34.0) + 1.0) * x, 289.0);
}

// Ashima Arts simplex noise (2D), ported verbatim.
static float swirl_snoise(float2 v) {
    const float4 C = float4(0.211324865405187, 0.366025403784439,
        -0.577350269189626, 0.024390243902439);
    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = swirl_glsl_mod(i, 289.0);
    float3 p = swirl_permute(swirl_permute(i.y + float3(0.0, i1.y, 1.0))
        + i.x + float3(0.0, i1.x, 1.0));
    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy),
        dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;
    float3 x = 2.0 * fract(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

fragment float4 background_swirl_fragment_shader(
    BackgroundFragmentData in [[stage_in]],
    constant BackgroundUniforms *uniforms [[buffer(0)]])
{
    // --- baked tunables: paper.design swirl "Default" preset values ---
    // (packages/shaders-react/src/shaders/swirl.tsx defaultPreset.params)
    const float band_count = 4.0;             // u_bandCount, 0-15 (ceil'd, like source)
    const float twist_amount = 0.1;           // u_twist, 0-1
    const float center_param = 0.2;           // u_center, 0-1
    const float proportion_param = 0.5;       // u_proportion, 0-1
    const float softness_param = 0.0;         // u_softness, 0-1
    const float noise_amount = 0.2;           // u_noise, 0-1
    const float noise_frequency_param = 0.4;  // u_noiseFrequency, 0-1

    int colors_count = uniforms->colors_count;
    if (colors_count < 1) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    // --- color mapping ---
    // uniforms->colors[0]          -> u_colorBack (background fill color)
    // uniforms->colors[1..count-1] -> u_colors[0..] (ordered swirl stripe palette)
    // (source shader's u_colors array is distinct from u_colorBack; since our
    // uniform contract has a single flat colors[8] array, slot 0 is reserved
    // for the background and the remaining slots feed the stripe palette,
    // capped at 7 stripe colors.)
    float4 color_back = uniforms->colors[0];
    int stripe_count = min(max(0, colors_count - 1), 7);

    float2 shape_uv = in.uv;

    float l = length(shape_uv);
    l = max(1e-4, l);

    float t = uniforms->time;

    // GLSL's atan(y, x) is the two-argument arctangent == Metal's atan2(y, x).
    float angle = ceil(band_count) * atan2(shape_uv.y, shape_uv.x) + t;
    // 6.28318530718 == 2*PI (source's TWO_PI constant).
    float angle_norm = angle / 6.28318530718;

    float twist = 3.0 * clamp(twist_amount, 0.0, 1.0);
    float offset = pow(l, -twist) + angle_norm;

    float shape = fract(offset);
    shape = 1.0 - abs(2.0 * shape - 1.0);
    shape += noise_amount * swirl_snoise(15.0 * pow(noise_frequency_param, 2.0) * shape_uv);

    float mid = smoothstep(0.2, 0.2 + 0.8 * center_param, pow(l, twist));
    shape = mix(0.0, shape, mid);

    float proportion = clamp(proportion_param, 0.0, 1.0);
    float exponent = mix(0.25, 1.0, proportion * 2.0);
    exponent = mix(exponent, 10.0, max(0.0, proportion * 2.0 - 1.0));
    shape = pow(shape, exponent);

    float mixer = shape * float(stripe_count);
    float outer_shape = 0.0;
    float4 gradient = float4(0.0);

    if (stripe_count > 0) {
        gradient = uniforms->colors[1];
        gradient.rgb *= gradient.a;

        for (int i = 1; i <= stripe_count; i++) {
            float m = clamp(mixer - float(i - 1), 0.0, 1.0);
            float aa = fwidth(m);
            m = smoothstep(0.5 - 0.5 * softness_param - aa, 0.5 + 0.5 * softness_param + aa, m);

            if (i == 1) {
                outer_shape = m;
            }

            float4 c = uniforms->colors[i];
            c.rgb *= c.a;
            gradient = mix(gradient, c, m);
        }
    }

    float mid_aa = 0.1 * fwidth(pow(l, -twist));
    float outer_mid = smoothstep(0.2, 0.2 + mid_aa, pow(l, twist));
    outer_shape = mix(0.0, outer_shape, outer_mid);

    float3 color = gradient.rgb * outer_shape;
    float opacity = gradient.a * outer_shape;

    float3 bg_rgb = color_back.rgb * color_back.a;
    color = color + bg_rgb * (1.0 - opacity);
    // Kept for parity with the source's premultiplied composite math, even
    // though the background is always returned fully opaque below.
    opacity = opacity + color_back.a * (1.0 - opacity);
    (void)opacity;

    // Dither to fight banding (source's colorBandingFix), using window-space
    // fragment position in place of gl_FragCoord.
    color += 1.0 / 256.0 * (fract(sin(dot(0.014 * in.position.xy, float2(12.9898, 78.233))) * 43758.5453123) - 0.5);

    // Fully opaque: the background establishes the base color that the
    // terminal's own (semi-transparent) surfaces composite over.
    return float4(color, 1.0);
}

// ---- warp ----
// Metal port of paper.design's "Warp" shader
// (https://github.com/paper-design/shaders, Apache-2.0).
//
// Animated color field warped by noise and swirl, applied over a base
// pattern (checks / stripes / edge). Blends up to 8 colors along the
// pattern with adjustable proportion/softness.
//
// All helpers are prefixed warp_ and this snippet is fully self-contained
// (it does not reuse bg_* helpers from other ported shaders).

static float warp_hash21(float2 p) {
    p = fract(p * float2(0.3183099, 0.3678794)) + 0.1;
    p += dot(p, p + 19.19);
    return fract(p.x * p.y);
}

static float warp_value_noise(float2 st) {
    float2 i = floor(st);
    float2 f = fract(st);
    float a = warp_hash21(i);
    float b = warp_hash21(i + float2(1.0, 0.0));
    float c = warp_hash21(i + float2(0.0, 1.0));
    float d = warp_hash21(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    float x1 = mix(a, b, u.x);
    float x2 = mix(c, d, u.x);
    return mix(x1, x2, u.y);
}

fragment float4 background_warp_fragment_shader(
    BackgroundFragmentData in [[stage_in]],
    constant BackgroundUniforms *uniforms [[buffer(0)]])
{
    // Baked defaults, taken from paper.design's Warp "Default" preset
    // (params not exposed on BackgroundUniforms are frozen at these values).
    const float warp_proportion = 0.45;
    const float warp_softness = 1.0;
    const float warp_distortion = 0.25;
    const float warp_swirl_strength = 0.8;
    const int warp_swirl_iterations = 10;
    const float warp_shape_scale = 0.1;
    const int warp_shape = 0; // 0 = checks, 1 = stripes, 2 = edge

    // in.uv is centered at (0,0) and aspect-corrected already; the GLSL's
    // v_patternUV (pattern-space UV with global sizing applied) is not
    // shifted by +0.5 the way mesh-gradient's v_objectUV was, so we mirror
    // that here: just scale, no re-centering.
    float2 uv = in.uv;
    uv *= 0.5;

    const float first_frame_offset = 118.0;
    float t = 0.0625 * (uniforms->time + first_frame_offset);

    float n1 = warp_value_noise(uv * 1.0 + t);
    float n2 = warp_value_noise(uv * 2.0 - t);
    float angle = n1 * 6.28318530718;
    uv.x += 4.0 * warp_distortion * n2 * cos(angle);
    uv.y += 4.0 * warp_distortion * n2 * sin(angle);

    // GLSL loop was `for (i = 1; i <= 20; i++) { if (i >= swirlIterations)
    // break; ... }`, i.e. the body runs for i = 1 .. swirlIterations - 1.
    // With swirlIterations baked as a compile-time constant we can express
    // that directly as a bounded for-loop.
    float swirl = warp_swirl_strength;
    for (int i = 1; i < warp_swirl_iterations; i++) {
        float i_f = float(i);
        uv.x += swirl / i_f * cos(t + i_f * 1.5 * uv.y);
        uv.y += swirl / i_f * cos(t + i_f * 1.0 * uv.x);
    }

    float proportion = clamp(warp_proportion, 0.0, 1.0);

    float shape = 0.0;
    if (warp_shape == 0) {
        // checks
        float2 checks_uv = uv * (0.5 + 3.5 * warp_shape_scale);
        shape = 0.5 + 0.5 * sin(checks_uv.x) * cos(checks_uv.y);
        shape += 0.48 * sign(proportion - 0.5) * pow(abs(proportion - 0.5), 0.5);
    } else if (warp_shape == 1) {
        // stripes
        float2 stripes_uv = uv * (2.0 * warp_shape_scale);
        float f = fract(stripes_uv.y);
        shape = smoothstep(0.0, 0.55, f) * (1.0 - smoothstep(0.45, 1.0, f));
        shape += 0.48 * sign(proportion - 0.5) * pow(abs(proportion - 0.5), 0.5);
    } else {
        // edge
        float shape_scaling = 5.0 * (1.0 - warp_shape_scale);
        float e0 = 0.45 - shape_scaling;
        float e1 = 0.55 + shape_scaling;
        shape = smoothstep(min(e0, e1), max(e0, e1), 1.0 - uv.y + 0.3 * (proportion - 0.5));
    }

    int colors_count = uniforms->colors_count;
    float mixer = shape * (float(colors_count) - 1.0);
    float4 gradient = uniforms->colors[0];
    gradient.rgb *= gradient.a;
    float aa = fwidth(shape);
    for (int i = 1; i < 8; i++) {
        if (i >= colors_count) { break; }
        float m = clamp(mixer - float(i - 1), 0.0, 1.0);

        float local_mixer_start = floor(m);
        float softness = 0.5 * warp_softness + fwidth(m);
        float smoothed = smoothstep(max(0.0, 0.5 - softness - aa), min(1.0, 0.5 + softness + aa), m - local_mixer_start);
        float stepped = local_mixer_start + smoothed;

        m = mix(stepped, m, warp_softness);

        float4 c = uniforms->colors[i];
        c.rgb *= c.a;
        gradient = mix(gradient, c, m);
    }

    float3 color = gradient.rgb;

    // Dither to avoid banding (ported from paper.design's colorBandingFix).
    color += (1.0 / 256.0) * (fract(sin(dot(0.014 * in.position.xy, float2(12.9898, 78.233))) * 43758.5453123) - 0.5);

    // Fully opaque: the background establishes the base color that the
    // terminal's own (semi-transparent) surfaces composite over.
    return float4(color, 1.0);
}

// ---- neuro_noise ----
// Metal port of the "neuro-noise" fragment shader from paper.design's
// shader library (https://github.com/paper-design/shaders, Apache-2.0):
// a glowing, web-like structure of fluid lines and soft intersections
// built from a rotating layered cosine-wave accumulator.
// Original algorithm: https://x.com/zozuar/status/1625182758745128981/

// --- helpers (self-contained; do not share with other ported shaders) ---

static float2 neuro_noise_rotate(float2 uv, float th) {
    // GLSL mat2(cos, sin, -sin, cos) is column-major: col0=(cos,sin),
    // col1=(-sin,cos). Metal float2x2 takes columns, so this matches exactly.
    return float2x2(float2(cos(th), sin(th)), float2(-sin(th), cos(th))) * uv;
}

static float neuro_noise_shape(float2 uv, float t) {
    float2 sine_acc = float2(0.0);
    float2 res = float2(0.0);
    float scale = 8.0;

    for (int j = 0; j < 15; j++) {
        uv = neuro_noise_rotate(uv, 1.0);
        sine_acc = neuro_noise_rotate(sine_acc, 1.0);
        float2 layer = uv * scale + float(j) + sine_acc - t;
        sine_acc += sin(layer);
        res += (0.5 + 0.5 * cos(layer)) / scale;
        scale *= 1.2;
    }
    return res.x + res.y;
}

fragment float4 background_neuro_noise_fragment_shader(
    BackgroundFragmentData in [[stage_in]],
    constant BackgroundUniforms *uniforms [[buffer(0)]])
{
    // Baked tunables from paper.design's NeuroNoise `defaultPreset`
    // (packages/shaders-react/src/shaders/neuro-noise.tsx).
    const float brightness = 0.05;
    const float contrast = 0.3;

    // in.uv is centered at (0,0) and aspect-corrected, roughly [-0.5, 0.5]
    // on the short axis. The original GLSL's v_patternUV is canvas-normalized
    // around (0.5, 0.5) (fit: 'none' pattern sizing), so shift to match,
    // matching the mesh-gradient reference port's `uv += 0.5` convention.
    float2 shape_uv = in.uv;
    shape_uv += 0.5;
    shape_uv *= 0.13;

    float t = 0.5 * uniforms->time;

    float noise = neuro_noise_shape(shape_uv, t);

    noise = (1.0 + brightness) * noise * noise;
    noise = pow(noise, 0.7 + 6.0 * contrast);
    noise = min(1.4, noise);

    float blend = smoothstep(0.7, 1.4, noise);

    // Color mapping (documented in port notes):
    //   colors[0] -> u_colorFront (graphics highlight color)
    //   colors[1] -> u_colorMid   (graphics main color)
    //   colors[2] -> u_colorBack  (background color)
    // Falls back gracefully when fewer than 3 colors are configured.
    float4 front_c = uniforms->colors_count > 0 ? uniforms->colors[0] : float4(1.0, 1.0, 1.0, 1.0);
    float4 mid_c = uniforms->colors_count > 1 ? uniforms->colors[1] : front_c;
    float4 back_c = uniforms->colors_count > 2 ? uniforms->colors[2] : float4(0.0, 0.0, 0.0, 1.0);

    front_c.rgb *= front_c.a;
    mid_c.rgb *= mid_c.a;
    float4 blend_front = mix(mid_c, front_c, blend);

    float safe_noise = max(noise, 0.0);
    float3 color = blend_front.rgb * safe_noise;
    float opacity = clamp(blend_front.a * safe_noise, 0.0, 1.0);

    float3 bg_color = back_c.rgb * back_c.a;
    color = color + bg_color * (1.0 - opacity);
    opacity = opacity + back_c.a * (1.0 - opacity);
    // `opacity` above mirrors the source GLSL's straight-alpha compositing
    // math (kept for fidelity) but is not needed further: the background is
    // always drawn fully opaque, so only `color` (which already has the
    // background blended in) is returned below.

    // colorBandingFix: subtle dither to avoid banding in smooth gradients.
    color += 1.0 / 256.0 * (fract(sin(dot(0.014 * in.position.xy, float2(12.9898, 78.233))) * 43758.5453123) - 0.5);

    return float4(color, 1.0);
}

// ---- perlin_noise ----
// ============================================================================
// Perlin Noise background shader
//
// Metal port of the "perlin-noise" effect from paper.design's shader library
// (https://github.com/paper-design/shaders, Apache-2.0): classic animated 3D
// Perlin noise (https://www.shadertoy.com/view/NlSGDz) thresholded into a
// soft two-color pattern. The GLSL source was translated to Metal Shading
// Language; the math is otherwise unchanged. All helpers are prefixed
// perlin_noise_ and are self-contained (no dependency on bg_* helpers or
// helpers from other ported shaders).
// ============================================================================

// --- helpers (ported from paper.design perlin-noise.ts) ---

static float perlin_noise_hash31(float3 p) {
    p = fract(p * 0.3183099) + 0.1;
    p += dot(p, p.yzx + 19.19);
    return fract(p.x * (p.y + p.z));
}

static float3 perlin_noise_gradient_predefined(float hash) {
    int idx = int(hash * 12.0) % 12;

    if (idx == 0) return float3(1, 1, 0);
    if (idx == 1) return float3(-1, 1, 0);
    if (idx == 2) return float3(1, -1, 0);
    if (idx == 3) return float3(-1, -1, 0);
    if (idx == 4) return float3(1, 0, 1);
    if (idx == 5) return float3(-1, 0, 1);
    if (idx == 6) return float3(1, 0, -1);
    if (idx == 7) return float3(-1, 0, -1);
    if (idx == 8) return float3(0, 1, 1);
    if (idx == 9) return float3(0, -1, 1);
    if (idx == 10) return float3(0, 1, -1);
    return float3(0, -1, -1); // idx == 11
}

static float perlin_noise_interpolate_safe(
    float v000, float v001, float v010, float v011,
    float v100, float v101, float v110, float v111, float3 t)
{
    t = clamp(t, 0.0, 1.0);

    float v00 = mix(v000, v100, t.x);
    float v01 = mix(v001, v101, t.x);
    float v10 = mix(v010, v110, t.x);
    float v11 = mix(v011, v111, t.x);

    float v0 = mix(v00, v10, t.y);
    float v1 = mix(v01, v11, t.y);

    return mix(v0, v1, t.z);
}

static float3 perlin_noise_fade(float3 t) {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

// Classic animated 3D Perlin noise sample at `position`, offset by `seed` so
// different octaves sample decorrelated regions of the same lattice.
static float perlin_noise_sample(float3 position, float seed) {
    position += float3(seed * 127.1, seed * 311.7, seed * 74.7);

    float3 i = floor(position);
    float3 f = fract(position);
    float h000 = perlin_noise_hash31(i);
    float h001 = perlin_noise_hash31(i + float3(0, 0, 1));
    float h010 = perlin_noise_hash31(i + float3(0, 1, 0));
    float h011 = perlin_noise_hash31(i + float3(0, 1, 1));
    float h100 = perlin_noise_hash31(i + float3(1, 0, 0));
    float h101 = perlin_noise_hash31(i + float3(1, 0, 1));
    float h110 = perlin_noise_hash31(i + float3(1, 1, 0));
    float h111 = perlin_noise_hash31(i + float3(1, 1, 1));
    float3 g000 = perlin_noise_gradient_predefined(h000);
    float3 g001 = perlin_noise_gradient_predefined(h001);
    float3 g010 = perlin_noise_gradient_predefined(h010);
    float3 g011 = perlin_noise_gradient_predefined(h011);
    float3 g100 = perlin_noise_gradient_predefined(h100);
    float3 g101 = perlin_noise_gradient_predefined(h101);
    float3 g110 = perlin_noise_gradient_predefined(h110);
    float3 g111 = perlin_noise_gradient_predefined(h111);
    float v000 = dot(g000, f - float3(0, 0, 0));
    float v001 = dot(g001, f - float3(0, 0, 1));
    float v010 = dot(g010, f - float3(0, 1, 0));
    float v011 = dot(g011, f - float3(0, 1, 1));
    float v100 = dot(g100, f - float3(1, 0, 0));
    float v101 = dot(g101, f - float3(1, 0, 1));
    float v110 = dot(g110, f - float3(1, 1, 0));
    float v111 = dot(g111, f - float3(1, 1, 1));

    float3 u = perlin_noise_fade(f);
    return perlin_noise_interpolate_safe(v000, v001, v010, v011, v100, v101, v110, v111, u);
}

// Fractal sum (fBm) of `perlin_noise_sample` across `octave_count` octaves.
static float perlin_noise_fbm(float3 position, int octave_count, float persistence, float lacunarity) {
    float value = 0.0;
    float amplitude = 1.0;
    float frequency = 10.0;
    octave_count = clamp(octave_count, 1, 8);

    for (int i = 0; i < octave_count; i++) {
        float seed = float(i) * 0.7319;
        value += perlin_noise_sample(position * frequency, seed) * amplitude;
        amplitude *= persistence;
        frequency *= lacunarity;
    }
    return value;
}

// Theoretical maximum |amplitude| sum for the fBm above, used to normalize
// the raw noise value into [0, 1] regardless of octave/persistence settings.
static float perlin_noise_get_max_amp(float persistence, float octave_count) {
    persistence = clamp(persistence * 0.999, 0.0, 0.999);
    octave_count = clamp(octave_count, 1.0, 8.0);

    if (abs(persistence - 1.0) < 0.001) {
        return octave_count;
    }

    return (1.0 - pow(persistence, octave_count)) / max(1e-4, (1.0 - persistence));
}

fragment float4 background_perlin_noise_fragment_shader(BackgroundFragmentData in [[stage_in]], constant BackgroundUniforms *uniforms [[buffer(0)]]) {
    // Baked defaults, taken from paper.design's PerlinNoise defaultPreset
    // (packages/shaders-react/src/shaders/perlin-noise.tsx):
    //   proportion: 0.35, softness: 0.1, octaveCount: 1,
    //   persistence: 1, lacunarity: 1.5
    const float k_proportion = 0.35;
    const float k_softness = 0.1;
    const int k_octave_count = 1;
    const float k_persistence = 1.0;
    const float k_lacunarity = 1.5;

    // in.uv is already centered at (0,0) and aspect-corrected, i.e. the same
    // "pattern space" role as the GLSL's v_patternUV. Unlike mesh-gradient,
    // this algorithm has no dependency on a [0,1]-range coordinate system
    // (it just samples a 3D noise field at an arbitrary position), so no
    // "+= 0.5" recentering is needed here -- we mirror the GLSL's "uv *= .5"
    // directly.
    float2 uv = in.uv * 0.5;

    float t = 0.2 * uniforms->time;
    float3 p = float3(uv, t);

    float noise = perlin_noise_fbm(p, k_octave_count, k_persistence, k_lacunarity);

    float max_amp = perlin_noise_get_max_amp(k_persistence, float(k_octave_count));
    float noise_normalized = clamp((noise + max_amp) / max(1e-4, (2.0 * max_amp)) + (k_proportion - 0.5), 0.0, 1.0);
    float sharpness = clamp(k_softness, 0.0, 1.0);
    float smooth_w = 0.5 * max(fwidth(noise_normalized), 0.001);
    float res = smoothstep(
        0.5 - 0.5 * sharpness - smooth_w,
        0.5 + 0.5 * sharpness + smooth_w,
        noise_normalized);

    // Color mapping: this effect is semantically a 2-color threshold
    // (u_colorFront / u_colorBack in the original), not an N-blob blend like
    // mesh-gradient, so instead of looping over every entry we take the two
    // endpoints of the active palette: colors[0] -> front (the "res"-shaped
    // foreground, i.e. high-noise regions) and colors[colors_count-1] ->
    // back (low-noise regions). Any colors in between (when colors_count > 2)
    // are intentionally unused. colors_count == 1 degenerates to a flat
    // color (front == back); colors_count == 0 falls back to opaque black.
    int colors_count = uniforms->colors_count;
    float4 front_color = (colors_count > 0) ? uniforms->colors[0] : float4(0.0, 0.0, 0.0, 1.0);
    float4 back_color = (colors_count > 1) ? uniforms->colors[colors_count - 1] : front_color;

    float3 fg_rgb = front_color.rgb * front_color.a;
    float fg_opacity = front_color.a;
    float3 bg_rgb = back_color.rgb * back_color.a;
    float bg_opacity = back_color.a;

    float3 color = fg_rgb * res;
    float opacity = fg_opacity * res;

    color += bg_rgb * (1.0 - opacity);
    opacity += bg_opacity * (1.0 - opacity);

    // colorBandingFix, ported verbatim: dithers out visible banding in the
    // smooth gradient by adding a tiny per-pixel noise offset. gl_FragCoord.xy
    // -> in.position.xy (window-space pixel position from the rasterizer).
    color += 1.0 / 256.0 * (fract(sin(dot(0.014 * in.position.xy, float2(12.9898, 78.233))) * 43758.5453123) - 0.5);

    // Fully opaque: the background establishes the base color that the
    // terminal's own (semi-transparent) surfaces composite over. Note: if a
    // configured color has alpha < 1, `opacity` above ends up < 1 and this
    // return implicitly composites the pattern over solid black (since
    // `color` is already premultiplied and we don't divide by `opacity`).
    return float4(color, 1.0);
}

// ---- color_panels ----
// ============================================================================
// "Color Panels" background shader
//
// Metal port of paper.design's "Color Panels" shader
// (https://github.com/paper-design/shaders, Apache-2.0): pseudo-3D
// semi-transparent panels rotating around a central axis. The GLSL source
// was translated to Metal Shading Language; the math is otherwise unchanged.
//
// Uniform mapping notes:
// - u_time            -> uniforms->time (speed already applied CPU-side)
// - u_colors[]         -> uniforms->colors[0..colors_count-1] (straight RGBA,
//                         premultiplied locally, exactly as the GLSL does)
// - u_colorsCount      -> uniforms->colors_count
// - u_colorBack        -> baked constant, opaque black (matches the shader's
//                         default preset colorBack = '#000000'); there is no
//                         spare uniform slot for a separate backdrop color
// - u_scale            -> baked constant 0.8 (default preset's `scale`); only
//                         used here for the panel-edge anti-aliasing width,
//                         not for any vertex-side sizing
// - u_density          -> baked constant 3.0   (default preset)
// - u_angle1           -> baked constant 0.0   (default preset)
// - u_angle2           -> baked constant 0.0   (default preset)
// - u_length           -> baked constant 1.1   (default preset)
// - u_edges            -> baked constant false (default preset)
// - u_blur             -> baked constant 0.0   (default preset)
// - u_fadeIn           -> baked constant 1.0   (default preset)
// - u_fadeOut          -> baked constant 0.3   (default preset)
// - u_gradient         -> baked constant 0.0   (default preset)
// - u_scale/u_rotation/u_offsetX/u_fit/u_worldWidth/... (vertex sizing)
//                      -> ignored; our fullscreen vertex shader already
//                         provides the final (centered, aspect-corrected) uv
// ============================================================================

constant float color_panels_scale       = 0.8;
constant float color_panels_density     = 3.0;
constant float color_panels_angle1      = 0.0;
constant float color_panels_angle2      = 0.0;
constant float color_panels_length      = 1.1;
constant bool  color_panels_edges       = false;
constant float color_panels_blur        = 0.0;
constant float color_panels_fade_in     = 1.0;
constant float color_panels_fade_out    = 0.3;
constant float color_panels_gradient    = 0.0;
constant float4 color_panels_color_back = float4(0.0, 0.0, 0.0, 1.0);

constant float color_panels_z_limit = 0.5;
constant float color_panels_two_pi  = 6.28318530718;
constant float color_panels_pi      = 3.14159265358979323846;

// Returns (panel_mask, panel_map) for one panel at the given rotation angle.
static float2 color_panels_get_panel(float angle, float2 uv, float inv_length, float aa) {
    float sin_a = sin(angle);
    float cos_a = cos(angle);

    float denom = sin_a - uv.y * cos_a;
    if (abs(denom) < 0.01) return float2(0.0);

    float z = uv.y / denom;
    if (z <= 0.0 || z > color_panels_z_limit) return float2(0.0);

    float z_ratio = z / color_panels_z_limit;
    float panel_map = 1.0 - z_ratio;
    float x = uv.x * (cos_a * z + 1.0) * inv_length;

    float z_offset = z_ratio - 0.5;
    float left = -0.5 + z_offset * color_panels_angle1;
    float right = 0.5 - z_offset * color_panels_angle2;
    float blur_x = aa + 2.0 * panel_map * color_panels_blur;

    float left_edge1 = left - blur_x;
    float left_edge2 = left + 0.25 * blur_x;
    float right_edge1 = right - 0.25 * blur_x;
    float right_edge2 = right + blur_x;

    float panel = smoothstep(left_edge1, left_edge2, x) * (1.0 - smoothstep(right_edge1, right_edge2, x));
    panel *= mix(0.0, panel, smoothstep(0.0, 0.01 / max(color_panels_scale, 1e-6), panel_map));

    float mid_screen = abs(sin_a);
    if (color_panels_edges) {
        panel_map = mix(0.99, panel_map, panel * clamp(panel_map / (0.15 * (1.0 - pow(mid_screen, 0.1))), 0.0, 1.0));
    } else if (mid_screen < 0.07) {
        panel *= (mid_screen * 15.0);
    }

    return float2(panel, panel_map);
}

// Fades a premultiplied panel color based on its depth (panel_map), then
// applies the panel coverage mask.
static float4 color_panels_blend_color(float4 color_a, float panel_mask, float panel_map) {
    float fade = 1.0 - smoothstep(0.97 - 0.97 * color_panels_fade_in, 1.0, panel_map);
    fade *= smoothstep(-0.2 * (1.0 - color_panels_fade_out), color_panels_fade_out, panel_map);

    float3 blended_rgb = mix(float3(0.0), color_a.rgb, fade);
    float blended_alpha = mix(0.0, color_a.a, fade);

    return float4(blended_rgb, blended_alpha) * panel_mask;
}

fragment float4 background_color_panels_fragment_shader(
    BackgroundFragmentData in [[stage_in]],
    constant BackgroundUniforms *uniforms [[buffer(0)]])
{
    float2 uv = in.uv;
    uv *= 1.25;
    // in.uv is aspect-corrected; normalize x back to canvas space so the
    // panel stage spans the full window width instead of a centered square.
    uv.x /= max(uniforms->viewport_size.x / max(uniforms->viewport_size.y, 1.0), 0.001);

    float t = 0.02 * uniforms->time;
    t = fract(t);
    bool reverse_time = (t < 0.5);

    float3 color = float3(0.0);
    float opacity = 0.0;

    float aa = 0.005 / color_panels_scale;

    int colors_count = uniforms->colors_count;
    colors_count = clamp(colors_count, 1, 8);

    float4 premultiplied_colors[8];
    for (int i = 0; i < 8; i++) {
        if (i >= colors_count) break;
        float4 c = uniforms->colors[i];
        c.rgb *= c.a;
        premultiplied_colors[i] = c;
    }

    float inv_length = 1.5 / max(color_panels_length, 0.001);

    int panels_number = 12;
    float density_normalizer = 1.0;
    if (colors_count == 4) {
        panels_number = 16;
        density_normalizer = 1.34;
    } else if (colors_count == 5) {
        panels_number = 20;
        density_normalizer = 1.67;
    } else if (colors_count == 7) {
        panels_number = 14;
        density_normalizer = 1.17;
    }

    float f_panels_number = float(panels_number);
    float panel_grad = 1.0 - clamp(color_panels_gradient, 0.0, 1.0);

    for (int set = 0; set < 2; set++) {
        bool is_forward = (set == 0 && !reverse_time) || (set == 1 && reverse_time);
        if (!is_forward) continue;

        for (int i = 0; i <= 20; i++) {
            if (i >= panels_number) break;

            int idx = panels_number - 1 - i;
            float offset = float(idx) / f_panels_number;
            if (set == 1) offset += 0.5;

            float density_fract = density_normalizer * fract(t + offset);
            float angle_norm = density_fract / color_panels_density;
            if (density_fract >= 0.5 || angle_norm >= 0.3) continue;

            float smooth_density = clamp((0.5 - density_fract) / 0.1, 0.0, 1.0) * clamp(density_fract / 0.01, 0.0, 1.0);
            float smooth_angle = clamp((0.3 - angle_norm) / 0.05, 0.0, 1.0);
            if (smooth_density * smooth_angle < 0.001) continue;

            if (angle_norm > 0.5) angle_norm = 0.5;

            float2 panel = color_panels_get_panel(angle_norm * color_panels_two_pi + color_panels_pi, uv, inv_length, aa);
            if (panel.x <= 0.001) continue;
            float panel_mask = panel.x * smooth_density * smooth_angle;
            float panel_map = panel.y;

            int color_idx = idx % colors_count;
            int next_color_idx = (idx + 1) % colors_count;

            float4 color_a = premultiplied_colors[color_idx];
            float4 color_b = premultiplied_colors[next_color_idx];

            color_a = mix(color_a, color_b, max(0.0, smoothstep(0.0, 0.45, panel_map) - panel_grad));
            float4 blended = color_panels_blend_color(color_a, panel_mask, panel_map);
            color = blended.rgb + color * (1.0 - blended.a);
            opacity = blended.a + opacity * (1.0 - blended.a);
        }

        for (int i = 0; i <= 20; i++) {
            if (i >= panels_number) break;

            int idx = panels_number - 1 - i;
            float offset = float(idx) / f_panels_number;
            if (set == 0) offset += 0.5;

            float density_fract = density_normalizer * fract(-t + offset);
            float angle_norm = -density_fract / color_panels_density;
            if (density_fract >= 0.5 || angle_norm < -0.3) continue;

            float smooth_density = clamp((0.5 - density_fract) / 0.1, 0.0, 1.0) * clamp(density_fract / 0.01, 0.0, 1.0);
            float smooth_angle = clamp((angle_norm + 0.3) / 0.05, 0.0, 1.0);
            if (smooth_density * smooth_angle < 0.001) continue;

            float2 panel = color_panels_get_panel(angle_norm * color_panels_two_pi + color_panels_pi, uv, inv_length, aa);
            float panel_mask = panel.x * smooth_density * smooth_angle;
            if (panel_mask <= 0.001) continue;
            float panel_map = panel.y;

            int color_idx = (colors_count - (idx % colors_count)) % colors_count;
            if (color_idx < 0) color_idx += colors_count;
            int next_color_idx = (color_idx + 1) % colors_count;

            float4 color_a = premultiplied_colors[color_idx];
            float4 color_b = premultiplied_colors[next_color_idx];

            color_a = mix(color_a, color_b, max(0.0, smoothstep(0.0, 0.45, panel_map) - panel_grad));
            float4 blended = color_panels_blend_color(color_a, panel_mask, panel_map);
            color = blended.rgb + color * (1.0 - blended.a);
            opacity = blended.a + opacity * (1.0 - blended.a);
        }
    }

    float3 bg_color = color_panels_color_back.rgb * color_panels_color_back.a;
    color = color + bg_color * (1.0 - opacity);
    opacity = opacity + color_panels_color_back.a * (1.0 - opacity);

    // Color banding fix (dither), ported from paper.design's colorBandingFix.
    color += 1.0 / 256.0 * (fract(sin(dot(0.014 * in.position.xy, float2(12.9898, 78.233))) * 43758.5453123) - 0.5);

    return float4(color, 1.0);
}

// ---- metaballs ----
// ---- metaballs ----
// Metal port of paper.design's "Metaballs" shader
// (https://github.com/paper-design/shaders, Apache-2.0): up to 20 colored
// gooey balls wandering around the center and merging into smooth organic
// shapes via a soft-threshold blend. Math translated 1:1 from the GLSL
// source; only the color/uniform plumbing and the noise-texture lookup were
// adapted. All helpers are prefixed "metaballs_" and this file is fully
// self-contained (no shared bg_*/swirl_*/warp_* helpers from other ports are
// reused).

// --- helpers ---

// Procedural 2D hash (ported from paper.design shader-utils.ts's
// proceduralHash21), used in place of the source's noise-texture sample.
static float metaballs_hash21(float2 p) {
    p = fract(p * float2(0.3183099, 0.3678794)) + 0.1;
    p += dot(p, p + 19.19);
    return fract(p.x * p.y);
}

// The GLSL source's `randomR(p)` sampled a pre-baked random texture at
// `floor(p) / 100 + 0.5`; since `p` is always integer-valued here (called as
// vec2(i, 0.0) / vec2(i+1.0, 0.0) from `metaballs_noise` below), that remap
// existed only to map lattice points into the texture's [0,1] UV space. We
// replace the texture lookup with a procedural hash of the same lattice
// point directly.
static float metaballs_random(float2 p) {
    return metaballs_hash21(floor(p));
}

// 1D value noise built from the 2D hash above (ported 1:1 from the GLSL
// source's `noise(float x)`).
static float metaballs_noise(float x) {
    float i = floor(x);
    float f = fract(x);
    float u = f * f * (3.0 - 2.0 * f);
    float2 p0 = float2(i, 0.0);
    float2 p1 = float2(i + 1.0, 0.0);
    return mix(metaballs_random(p0), metaballs_random(p1), u);
}

// Radial falloff for a single ball (ported 1:1 from the GLSL source's
// `getBallShape`).
static float metaballs_get_ball_shape(float2 uv, float2 c, float p) {
    float s = 0.5 * length(uv - c);
    s = 1.0 - clamp(s, 0.0, 1.0);
    s = pow(s, p);
    return s;
}

fragment float4 background_metaballs_fragment_shader(
    BackgroundFragmentData in [[stage_in]],
    constant BackgroundUniforms *uniforms [[buffer(0)]])
{
    // --- baked tunables: paper.design metaballs "Default" preset values ---
    // (packages/shaders-react/src/shaders/metaballs.tsx defaultPreset.params)
    const float ball_count = 10.0;      // u_count, 1-20
    const float ball_size = 0.83;       // u_size, 0-1
    const int max_balls_count = 20;     // metaballsMeta.maxBallsCount (loop cap)
    // Note: the source also declares a `u_sizeRange` uniform, but it is never
    // referenced anywhere in the fragment main() body, so there is nothing to
    // bake or port for it.

    int colors_count = uniforms->colors_count;
    if (colors_count < 1) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    // --- color mapping ---
    // uniforms->colors[0]          -> u_colorBack (background fill color)
    // uniforms->colors[1..count-1] -> u_colors[0..] (ball color palette,
    // cycled round-robin across the active balls via `i % ball_colors_count`,
    // exactly like the source's `i % int(u_colorsCount + 0.5)`).
    // (mirrors the "swirl"/"warp" ports' convention: slot 0 is reserved for
    // the background, remaining slots feed the per-element palette, capped
    // at 7 entries since our flat colors[8] array holds both.)
    float4 color_back = uniforms->colors[0];
    int ball_colors_count = min(max(0, colors_count - 1), 7);

    float2 shape_uv = in.uv;
    shape_uv += 0.5;

    const float first_frame_offset = 2503.4;
    float t = 0.2 * (uniforms->time + first_frame_offset);

    float3 total_color = float3(0.0);
    float total_shape = 0.0;
    float total_opacity = 0.0;

    if (ball_colors_count > 0) {
        int ball_bound = min(max_balls_count, int(ceil(ball_count)));
        for (int i = 0; i < max_balls_count; i++) {
            if (i >= ball_bound) break;

            float idx_fract = float(i) / float(max_balls_count);
            float angle = 6.28318530718 * idx_fract; // TWO_PI

            float speed = 1.0 - 0.2 * idx_fract;
            float noise_x = metaballs_noise(angle * 10.0 + float(i) + t * speed);
            float noise_y = metaballs_noise(angle * 20.0 + float(i) - t * speed);

            float2 pos = float2(0.5) + 1e-4 + 0.9 * (float2(noise_x, noise_y) - 0.5);
            // The source confines balls to a unit square (centered on wide
            // windows); stretch the position range horizontally to the
            // window's aspect ratio so balls roam the full width while
            // staying circular.
            float mb_aspect = uniforms->viewport_size.x / max(uniforms->viewport_size.y, 1.0);
            pos.x = 0.5 + (pos.x - 0.5) * max(mb_aspect, 0.001);

            int safe_index = i % ball_colors_count;
            float4 ball_color = uniforms->colors[1 + safe_index];
            ball_color.rgb *= ball_color.a;

            float size_frac = 1.0;
            if (float(i) > floor(ball_count - 1.0)) {
                size_frac *= fract(ball_count);
            }

            float shape = metaballs_get_ball_shape(shape_uv, pos, 45.0 - 30.0 * ball_size * size_frac);
            shape *= pow(ball_size, 0.2);
            shape = smoothstep(0.0, 1.0, shape);

            total_color += ball_color.rgb * shape;
            total_shape += shape;
            total_opacity += ball_color.a * shape;
        }
    }

    total_color /= max(total_shape, 1e-4);
    total_opacity /= max(total_shape, 1e-4);

    float edge_width = fwidth(total_shape);
    float final_shape = smoothstep(0.4, 0.4 + edge_width, total_shape);

    float3 color = total_color * final_shape;
    float opacity = total_opacity * final_shape;

    float3 bg_rgb = color_back.rgb * color_back.a;
    color = color + bg_rgb * (1.0 - opacity);
    // Kept for parity with the source's premultiplied composite math, even
    // though the background is always returned fully opaque below.
    opacity = opacity + color_back.a * (1.0 - opacity);
    (void)opacity;

    // Dither to fight banding (source's colorBandingFix), using window-space
    // fragment position in place of gl_FragCoord.
    color += 1.0 / 256.0 * (fract(sin(dot(0.014 * in.position.xy, float2(12.9898, 78.233))) * 43758.5453123) - 0.5);

    // Fully opaque: the background establishes the base color that the
    // terminal's own (semi-transparent) surfaces composite over.
    return float4(color, 1.0);
}

// ---- liquid_metal ----
// Metal port of paper.design's "liquid-metal" shader
// (https://github.com/paper-design/shaders, Apache-2.0): a futuristic brushed
// chrome / liquid metal material made of animated stripes that bend and
// disperse (chromatic aberration) around a soft, screen-filling "shape" mask.
// Math translated 1:1 from the GLSL source's no-image / shape:'none'
// (full-canvas fill) code path; only the color/uniform plumbing was adapted
// to Warp's BackgroundUniforms contract. All helpers are prefixed
// "liquid_metal_" and this file is fully self-contained (no shared bg_*/
// other-shader helpers reused).
//
// Source uniforms this port deliberately does NOT implement:
// - u_image / u_imageAspectRatio / u_isImage: this background never has a
//   source image or logo to key off; u_isImage is permanently baked false,
//   which statically prunes the source's `if (u_isImage == true)` branches
//   (image sampling, edge-texture blur, image frame masking).
// - u_shape: baked to `none` (0), i.e. the source's "full-fill on canvas"
//   branch — the only shape mode designed for a screen-filling background
//   (see fullScreenPreset below). The circle / daisy / diamond / metaballs
//   branches are dropped entirely.
// - Vertex-side sizing uniforms (u_scale/u_rotation/u_offset*/u_fit/
//   u_worldWidth/u_worldHeight/u_origin*): Warp's fullscreen vertex shader
//   already provides the final `in.uv`, so these never applied here.

// --- helpers (ported from paper.design shader-utils.ts: simplexNoise) ---

// GLSL's `mod(x, y)` keeps the sign of `y` (unlike Metal/HLSL `fmod`, which
// keeps the sign of `x`). `snoise`'s internal `floor(v + dot(...))` can go
// negative, so true GLSL semantics are implemented to be safe.
static float2 liquid_metal_glsl_mod(float2 x, float y) {
    return x - y * floor(x / y);
}
static float3 liquid_metal_glsl_mod(float3 x, float y) {
    return x - y * floor(x / y);
}

static float3 liquid_metal_permute(float3 x) {
    return liquid_metal_glsl_mod(((x * 34.0) + 1.0) * x, 289.0);
}

// Ashima Arts simplex noise (2D), ported verbatim.
static float liquid_metal_snoise(float2 v) {
    const float4 C = float4(0.211324865405187, 0.366025403784439,
        -0.577350269189626, 0.024390243902439);
    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = liquid_metal_glsl_mod(i, 289.0);
    float3 p = liquid_metal_permute(liquid_metal_permute(i.y + float3(0.0, i1.y, 1.0))
        + i.x + float3(0.0, i1.x, 1.0));
    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy),
        dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;
    float3 x = 2.0 * fract(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

// GLSL `mat2(cos,sin,-sin,cos) * uv` is column-major: col0=(cos,sin),
// col1=(-sin,cos). Metal float2x2 takes columns, so this matches exactly
// (same convention as the mesh-gradient/swirl ports' `bg_rotate`/rotation).
static float2 liquid_metal_rotate(float2 uv, float th) {
    return float2x2(float2(cos(th), sin(th)), float2(-sin(th), cos(th))) * uv;
}

// Ported 1:1 from the source's `getColorChanges`. `tint_alpha` is passed in
// explicitly (the source reads the global `u_colorTint.a` uniform directly);
// the source's `if (u_isImage == true) { bump = smoothstep(.2,.8,bump); }`
// branch is omitted since u_isImage is permanently false in this port.
static float liquid_metal_get_color_changes(float c1, float c2, float stripe_p, float3 w,
                                             float blur, float bump, float tint, float tint_alpha) {
    float ch = mix(c2, c1, smoothstep(0.0, 2.0 * blur, stripe_p));

    float border = w[0];
    ch = mix(ch, c2, smoothstep(border, border + 2.0 * blur, stripe_p));

    border = w[0] + 0.4 * (1.0 - bump) * w[1];
    ch = mix(ch, c1, smoothstep(border, border + 2.0 * blur, stripe_p));

    border = w[0] + 0.5 * (1.0 - bump) * w[1];
    ch = mix(ch, c2, smoothstep(border, border + 2.0 * blur, stripe_p));

    border = w[0] + w[1];
    ch = mix(ch, c1, smoothstep(border, border + 2.0 * blur, stripe_p));

    float gradient_t = (stripe_p - w[0] - w[1]) / w[2];
    float gradient = mix(c1, c2, smoothstep(0.0, 1.0, gradient_t));
    ch = mix(ch, gradient, smoothstep(border, border + 0.5 * blur, stripe_p));

    // Tint color is applied with color-burn blending.
    ch = mix(ch, 1.0 - min(1.0, (1.0 - ch) / max(tint, 0.0001)), tint_alpha);
    return ch;
}

fragment float4 background_liquid_metal_fragment_shader(
    BackgroundFragmentData in [[stage_in]],
    constant BackgroundUniforms *uniforms [[buffer(0)]])
{
    // --- baked tunables: paper.design liquid-metal "Backdrop" preset values ---
    // (packages/shaders-react/src/shaders/liquid-metal.tsx fullScreenPreset.params)
    // This is the library's only built-in preset using shape:'none', i.e. the
    // full-canvas-fill mode appropriate for a screen-filling background.
    const float repetition_const = 1.5;   // u_repetition, 1-10 (stripe density)
    const float softness_const = 0.05;    // u_softness, 0-1
    const float shift_red_const = 0.3;    // u_shiftRed, -1 to 1 (R dispersion)
    const float shift_blue_const = 0.3;   // u_shiftBlue, -1 to 1 (B dispersion)
    const float distortion_const = 0.1;   // u_distortion, 0-1
    const float contour_const = 0.4;      // u_contour, 0-1
    const float angle_const = 90.0;       // u_angle, degrees 0-360

    int colors_count = uniforms->colors_count;
    if (colors_count < 1) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    // --- color mapping ---
    // uniforms->colors[0] -> u_colorBack (opaque backing color the stripe
    //                        material composites over near the screen edges).
    // uniforms->colors[1] -> u_colorTint (color-burn tint over the chrome
    //                        stripes); if only one color is configured this
    //                        falls back to opaque white, which is a no-op
    //                        tint (matches the source library's own default).
    // Any colors[2..] are unused by this shader (it only has two color
    // roles, unlike the multi-stop gradients in other ported shaders).
    float4 color_back = uniforms->colors[0];
    float4 color_tint = colors_count > 1 ? uniforms->colors[1] : float4(1.0, 1.0, 1.0, 1.0);

    const float first_frame_offset = 2.8;
    float t = 0.3 * (uniforms->time + first_frame_offset);

    // Warp's fullscreen vertex shader gives us a single aspect-corrected,
    // centered UV. The source distinguishes `v_objectUV` (object-box UV)
    // from `v_responsiveUV` (canvas-fill UV) plus `v_responsiveBoxGivenSize`
    // (the canvas pixel size used to compute an edge-vignette thickness in
    // pixels); since we have no separate object/vertex-sizing pass, both
    // map onto the same `in.uv`, and `v_responsiveBoxGivenSize` maps onto
    // the viewport size.
    float2 responsive_box_size = max(uniforms->viewport_size, float2(1.0));
    // `in.uv` is aspect-corrected (x scaled by width/height), but the
    // source's responsive/object UVs are canvas-normalized ([-0.5, 0.5] on
    // both axes) and this shader applies its own aspect handling below —
    // undo the correction here so the effect fills the whole window instead
    // of getting cropped on wide windows.
    float lm_aspect = responsive_box_size.x / responsive_box_size.y;
    float2 canvas_uv = float2(in.uv.x / max(lm_aspect, 0.001), in.uv.y);
    float2 object_uv = canvas_uv;
    float2 responsive_uv = canvas_uv;

    float2 uv = object_uv + 0.5;
    uv.y = 1.0 - uv.y;

    float cycle_width = repetition_const;

    float2 rotated_uv = uv - float2(0.5);
    // 3.14159265358979323846 == PI (source's PI constant).
    float angle = (-angle_const + 70.0) * (3.14159265358979323846 / 180.0);
    float cosA = cos(angle);
    float sinA = sin(angle);
    rotated_uv = float2(
        rotated_uv.x * cosA - rotated_uv.y * sinA,
        rotated_uv.x * sinA + rotated_uv.y * cosA
    ) + float2(0.5);

    // Source's "full-fill on canvas" branch (u_shape < 1.0 / shape:'none').
    float2 border_uv = responsive_uv + 0.5;
    float ratio = responsive_box_size.x / responsive_box_size.y;
    float2 mask = min(border_uv, 1.0 - border_uv);
    float2 pixel_thickness = min(250.0 / responsive_box_size, float2(0.5));
    float maskX = pow(smoothstep(0.0, pixel_thickness.x, mask.x), 0.25);
    float maskY = pow(smoothstep(0.0, pixel_thickness.y, mask.y), 0.25);
    float edge = clamp(1.0 - maskX * maskY, 0.0, 1.0);

    uv = responsive_uv;
    if (ratio > 1.0) {
        uv.y /= ratio;
    } else {
        uv.x *= ratio;
    }
    uv += 0.5;
    uv.y = 1.0 - uv.y;

    cycle_width *= 2.0;

    edge = mix(smoothstep(0.9 - 2.0 * fwidth(edge), 0.9, edge), edge, smoothstep(0.0, 0.4, contour_const));

    // isImage == false: opacity derives from the shape edge, and shape:'none'
    // (< 2.0 in the source's if/else-if chain) always takes the `1.2 * edge`
    // branch.
    float opacity = 1.0 - smoothstep(0.9 - 2.0 * fwidth(edge), 0.9, edge);
    edge = 1.2 * edge;

    float diag_bl_to_tr = rotated_uv.x - rotated_uv.y;
    float diag_tl_to_br = rotated_uv.x + rotated_uv.y;

    float3 color1 = float3(0.98, 0.98, 1.0);
    float3 color2 = float3(0.1, 0.1, 0.1 + 0.1 * smoothstep(0.7, 1.3, diag_tl_to_br));

    float2 grad_uv = uv - 0.5;
    float dist = length(grad_uv + float2(0.0, 0.2 * diag_bl_to_tr));
    grad_uv = liquid_metal_rotate(grad_uv, (0.25 - 0.2 * diag_bl_to_tr) * 3.14159265358979323846);
    float direction = grad_uv.x;

    float bump = pow(1.8 * dist, 1.2);
    bump = 1.0 - bump;
    bump *= pow(uv.y, 0.3);

    float thin_strip_1_ratio = 0.12 / cycle_width * (1.0 - 0.4 * bump);
    float thin_strip_2_ratio = 0.07 / cycle_width * (1.0 + 0.4 * bump);
    float wide_strip_ratio = 1.0 - thin_strip_1_ratio - thin_strip_2_ratio;

    float thin_strip_1_width = cycle_width * thin_strip_1_ratio;
    float thin_strip_2_width = cycle_width * thin_strip_2_ratio;

    float noise = liquid_metal_snoise(uv - t);

    edge += (1.0 - edge) * distortion_const * noise;

    direction += diag_bl_to_tr;
    direction -= 2.0 * noise * diag_bl_to_tr * (smoothstep(0.0, 1.0, edge) * (1.0 - smoothstep(0.0, 1.0, edge)));
    direction *= mix(1.0, 1.0 - edge, smoothstep(0.5, 1.0, contour_const));
    direction -= 1.7 * edge * smoothstep(0.5, 1.0, contour_const);
    direction += 0.2 * pow(contour_const, 4.0) * (1.0 - smoothstep(0.0, 1.0, edge));

    bump *= clamp(pow(uv.y, 0.1), 0.3, 1.0);
    direction *= (0.1 + (1.1 - edge) * bump);

    direction *= (0.4 + 0.6 * (1.0 - smoothstep(0.5, 1.0, edge)));
    direction += 0.18 * (smoothstep(0.1, 0.2, uv.y) * (1.0 - smoothstep(0.2, 0.4, uv.y)));
    direction += 0.03 * (smoothstep(0.1, 0.2, 1.0 - uv.y) * (1.0 - smoothstep(0.2, 0.4, 1.0 - uv.y)));

    direction *= (0.5 + 0.5 * pow(uv.y, 2.0));
    direction *= cycle_width;
    direction -= t;

    float color_dispersion = clamp(1.0 - bump, 0.0, 1.0);
    float dispersion_red = color_dispersion;
    dispersion_red += 0.03 * bump * noise;
    dispersion_red += 5.0 * (smoothstep(-0.1, 0.2, uv.y) * (1.0 - smoothstep(0.1, 0.5, uv.y)))
        * (smoothstep(0.4, 0.6, bump) * (1.0 - smoothstep(0.4, 1.0, bump)));
    dispersion_red -= diag_bl_to_tr;

    float dispersion_blue = color_dispersion;
    dispersion_blue *= 1.3;
    dispersion_blue += (smoothstep(0.0, 0.4, uv.y) * (1.0 - smoothstep(0.1, 0.8, uv.y)))
        * (smoothstep(0.4, 0.6, bump) * (1.0 - smoothstep(0.4, 0.8, bump)));
    dispersion_blue -= 0.2 * edge;

    dispersion_red *= (shift_red_const / 20.0);
    dispersion_blue *= (shift_blue_const / 20.0);

    // isImage == false: blur has no image-only extra terms (softness/small-
    // canvas/red/green extra blur are all part of the `if (u_isImage == true)`
    // branch in the source and are dropped here). The source's local
    // `contour` float is declared but never reassigned on this code path
    // (always 0.0), so `+ 0.3 * contour` contributes nothing — kept as a
    // comment rather than dead code.
    float blur = softness_const / 15.0; // + 0.3 * contour (contour is always 0 here)

    float3 w = float3(thin_strip_1_width, thin_strip_2_width, wide_strip_ratio);
    w[1] -= 0.02 * smoothstep(0.0, 1.0, edge + bump);

    float stripe_r = fract(direction + dispersion_red);
    float r = liquid_metal_get_color_changes(color1.r, color2.r, stripe_r, w,
        blur + fwidth(stripe_r), bump, color_tint.r, color_tint.a);
    float stripe_g = fract(direction);
    float g = liquid_metal_get_color_changes(color1.g, color2.g, stripe_g, w,
        blur + fwidth(stripe_g), bump, color_tint.g, color_tint.a);
    float stripe_b = fract(direction - dispersion_blue);
    float b = liquid_metal_get_color_changes(color1.b, color2.b, stripe_b, w,
        blur + fwidth(stripe_b), bump, color_tint.b, color_tint.a);

    float3 color = float3(r, g, b);
    color *= opacity;

    float3 bg_rgb = color_back.rgb * color_back.a;
    color = color + bg_rgb * (1.0 - opacity);
    // Kept for parity with the source's premultiplied composite math, even
    // though the background is always returned fully opaque below.
    opacity = opacity + color_back.a * (1.0 - opacity);
    (void)opacity;

    // Dither to fight banding (source's colorBandingFix), using window-space
    // fragment position in place of gl_FragCoord.
    color += 1.0 / 256.0 * (fract(sin(dot(0.014 * in.position.xy, float2(12.9898, 78.233))) * 43758.5453123) - 0.5);

    // Fully opaque: the background establishes the base color that the
    // terminal's own (semi-transparent) surfaces composite over.
    return float4(color, 1.0);
}

// ---- god_rays ----
// Metal port of paper.design's "God Rays" shader
// (https://github.com/paper-design/shaders, Apache-2.0): animated rays of
// light radiating from the center, with a soft central glow and a bloom
// overlay tint, blended with up to 5 ray colors. Math translated 1:1 from
// the GLSL source; only the color/uniform plumbing was adapted to Warp's
// BackgroundUniforms contract.
//
// All helpers are prefixed god_rays_ and this snippet is fully
// self-contained (it does not reuse bg_* or other shaders' helpers). The
// GLSL source's texture-based randomizer (u_noiseTexture / randomR) is
// replaced with a procedural hash (god_rays_hash21), matching the pattern
// already used for mesh-gradient/warp's own texture-free noise ports.

static float2 god_rays_rotate(float2 uv, float th) {
    // GLSL mat2(cos, sin, -sin, cos) is column-major: col0=(cos,sin),
    // col1=(-sin,cos). Metal float2x2 takes columns, so this matches exactly.
    return float2x2(float2(cos(th), sin(th)), float2(-sin(th), cos(th))) * uv;
}

// Ported from paper.design shader-utils.ts's proceduralHash11.
static float god_rays_hash11(float p) {
    p = fract(p * 0.3183099) + 0.1;
    p *= p + 19.19;
    return fract(p * p);
}

// Ported from paper.design shader-utils.ts's proceduralHash21. Used in place
// of the GLSL source's texture-backed `randomR`, which looked up a
// pre-computed noise texture keyed by floor(p); a procedural hash on the
// same integer lattice point is visually equivalent for this effect.
static float god_rays_hash21(float2 p) {
    p = fract(p * float2(0.3183099, 0.3678794)) + 0.1;
    p += dot(p, p + 19.19);
    return fract(p.x * p.y);
}

static float god_rays_value_noise(float2 st) {
    float2 i = floor(st);
    float2 f = fract(st);
    float a = god_rays_hash21(i);
    float b = god_rays_hash21(i + float2(1.0, 0.0));
    float c = god_rays_hash21(i + float2(0.0, 1.0));
    float d = god_rays_hash21(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    float x1 = mix(a, b, u.x);
    float x2 = mix(c, d, u.x);
    return mix(x1, x2, u.y);
}

// Ported 1:1 from the GLSL `raysShape`. Note `radius` is accepted but
// unused in the original source too (kept for fidelity to the source
// signature; harmless unused-parameter warning).
static float god_rays_rays_shape(float2 uv, float r, float freq, float intensity, float radius) {
    const float two_pi = 6.28318530718;
    // GLSL's atan(y, x) is the two-argument arctangent == Metal's atan2(y, x).
    float a = atan2(uv.y, uv.x);
    float2 left = float2(a * freq, r);
    float2 right = float2(fract(a / two_pi) * two_pi * freq, r);
    float n_left = pow(god_rays_value_noise(left), intensity);
    float n_right = pow(god_rays_value_noise(right), intensity);
    float shape = mix(n_right, n_left, smoothstep(-0.15, 0.15, uv.x));
    return shape;
}

fragment float4 background_god_rays_fragment_shader(
    BackgroundFragmentData in [[stage_in]],
    constant BackgroundUniforms *uniforms [[buffer(0)]])
{
    // Baked tunables, taken from paper.design's GodRays "Default" preset
    // (packages/shaders-react/src/shaders/god-rays.tsx defaultPreset.params;
    // params not exposed on BackgroundUniforms are frozen at these values).
    const float god_rays_density_param = 0.3;      // u_density, 0-1
    const float god_rays_spotty_param = 0.3;        // u_spotty, 0-1
    const float god_rays_mid_size_param = 0.2;      // u_midSize, 0-1
    const float god_rays_mid_intensity_param = 0.4; // u_midIntensity, 0-1
    const float god_rays_intensity_param = 0.8;     // u_intensity, 0-1
    const float god_rays_bloom_param = 0.4;         // u_bloom, 0-1
    const int god_rays_max_colors = 5;              // godRaysMeta.maxColorCount

    // --- color mapping ---
    // The source GLSL has three distinct color roles (u_colorBack,
    // u_colorBloom, and a separate u_colors[5] ray palette) but our uniform
    // contract exposes a single flat colors[8] array, so fixed low indices
    // are reserved for the two structural roles and the rest feed the ray
    // palette (mirroring the swirl port's "slot 0 = background" convention,
    // extended with a second reserved slot for the bloom tint):
    //   uniforms->colors[0]          -> u_colorBack  (background fill color)
    //   uniforms->colors[1]          -> u_colorBloom (overlay/glow tint)
    //   uniforms->colors[2..count-1] -> u_colors[0..] (ray palette, up to 5)
    int colors_count = uniforms->colors_count;
    if (colors_count < 1) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    float4 color_back = uniforms->colors[0];
    float4 color_bloom = (colors_count >= 2) ? uniforms->colors[1] : float4(0.0);
    int ray_count = clamp(colors_count - 2, 0, god_rays_max_colors);

    // in.uv is already centered at (0,0) and aspect-corrected, matching the
    // GLSL's own v_objectUV convention for this shader: unlike mesh-gradient,
    // the source does NOT do `shape_uv += 0.5` here (it calls
    // `length(shape_uv)` directly, i.e. it wants distance from the screen
    // center, which in.uv already gives us), so no shift is applied.
    float2 shape_uv = in.uv;

    float t = 0.2 * uniforms->time;

    float radius = length(shape_uv);
    float spots = 6.5 * abs(god_rays_spotty_param);

    float ray_intensity = 4.0 - 3.0 * clamp(god_rays_intensity_param, 0.0, 1.0);

    float mid_size = 10.0 * abs(god_rays_mid_size_param);
    float ms_lo = 0.02 * mid_size;
    float ms_hi = max(mid_size, 1e-6);
    float middle_shape = pow(god_rays_mid_intensity_param, 0.3) * (1.0 - smoothstep(ms_lo, ms_hi, 3.0 * radius));
    middle_shape = pow(middle_shape, 5.0);

    float3 accum_color = float3(0.0);
    float accum_alpha = 0.0;

    for (int i = 0; i < god_rays_max_colors; i++) {
        if (i >= ray_count) { break; }

        float2 rotated_uv = god_rays_rotate(shape_uv, float(i) + 1.0);

        float r1 = radius * (1.0 + 0.4 * float(i)) - 3.0 * t;
        float r2 = 0.5 * radius * (1.0 + spots) - 2.0 * t;
        float density_scaled = 6.0 * god_rays_density_param
            + step(0.5, god_rays_density_param) * pow(4.5 * (god_rays_density_param - 0.5), 4.0);
        float f = mix(1.0, 3.0 + 0.5 * float(i), god_rays_hash11(float(i) * 15.0)) * density_scaled;

        float ray = god_rays_rays_shape(rotated_uv, r1, 5.0 * f, ray_intensity, radius);
        ray *= god_rays_rays_shape(rotated_uv, r2, 4.0 * f, ray_intensity, radius);
        ray += (1.0 + 4.0 * ray) * middle_shape;
        ray = clamp(ray, 0.0, 1.0);

        float4 ray_color = uniforms->colors[2 + i];
        float src_alpha = ray_color.a * ray;
        float3 src_color = ray_color.rgb * src_alpha;

        float3 alpha_blend_color = accum_color + (1.0 - accum_alpha) * src_color;
        float alpha_blend_alpha = accum_alpha + (1.0 - accum_alpha) * src_alpha;

        float3 add_blend_color = accum_color + src_color;
        float add_blend_alpha = accum_alpha + src_alpha;

        accum_color = mix(alpha_blend_color, add_blend_color, god_rays_bloom_param);
        accum_alpha = mix(alpha_blend_alpha, add_blend_alpha, god_rays_bloom_param);
    }

    float overlay_alpha = color_bloom.a;
    float3 overlay_color = color_bloom.rgb * overlay_alpha;

    float3 color_with_overlay = accum_color + accum_alpha * overlay_color;
    accum_color = mix(accum_color, color_with_overlay, god_rays_bloom_param);

    float3 bg_color = color_back.rgb * color_back.a;

    float3 color = accum_color + (1.0 - accum_alpha) * bg_color;
    // `opacity` is computed for fidelity with the source's premultiplied
    // composite math, but is unused in the final return: this is the base
    // background layer (nothing beneath it), always returned fully opaque,
    // same reasoning as the other ported background shaders.
    float opacity = accum_alpha + (1.0 - accum_alpha) * color_back.a;
    color = saturate(color);
    opacity = saturate(opacity);
    (void)opacity;

    // Dither to fight banding (ported from paper.design's colorBandingFix),
    // using window-space fragment position in place of gl_FragCoord.
    color += 1.0 / 256.0 * (fract(sin(dot(0.014 * in.position.xy, float2(12.9898, 78.233))) * 43758.5453123) - 0.5);

    // Fully opaque: the background establishes the base color that the
    // terminal's own (semi-transparent) surfaces composite over.
    return float4(color, 1.0);
}

// ---- water ----
// ---- water ----
// Metal port of paper.design's "Water" shader
// (https://github.com/paper-design/shaders, Apache-2.0): water-like surface
// distortion with natural caustic realism, driven by a rotating layered
// sin/cos accumulator (getCausticNoise) modulated by a simplex-noise "waves"
// field. The original shader is designed to work as either an image filter
// or a standalone animated texture; Warp's background has no source image,
// so the image-sampling / edge-frame / caustic-driven-UV-warp path (which
// only ever affects *where the image is resampled from*) is dropped, and the
// shader is used purely in its "standalone animated texture" role: a
// caustic-light highlight overlay animating on top of a flat backing color.
//
// All helpers are prefixed water_ and this snippet is fully self-contained
// (it does not reuse bg_*/swirl_*/warp_* helpers from other ported shaders).

// --- helpers (ported from paper.design shader-utils.ts: simplexNoise) ---

// GLSL's `mod(x, y)` keeps the sign of `y` (unlike Metal/HLSL `fmod`, which
// keeps the sign of `x`). `i`/`i1` coordinates below can be negative, so we
// implement true GLSL semantics rather than reaching for fmod.
static float2 water_glsl_mod(float2 x, float y) {
    return x - y * floor(x / y);
}
static float3 water_glsl_mod(float3 x, float y) {
    return x - y * floor(x / y);
}

static float3 water_permute(float3 x) {
    return water_glsl_mod(((x * 34.0) + 1.0) * x, 289.0);
}

// Ashima Arts simplex noise (2D), ported verbatim.
static float water_snoise(float2 v) {
    const float4 C = float4(0.211324865405187, 0.366025403784439,
        -0.577350269189626, 0.024390243902439);
    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = water_glsl_mod(i, 289.0);
    float3 p = water_permute(water_permute(i.y + float3(0.0, i1.y, 1.0))
        + i.x + float3(0.0, i1.x, 1.0));
    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy),
        dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;
    float3 x = 2.0 * fract(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

// Standard M*v rotation-by-th (matches the reference port's bg_rotate /
// swirl's rotate convention: mat2(cos,sin,-sin,cos) * uv).
static float2 water_rotate2d(float2 uv, float th) {
    return float2x2(float2(cos(th), sin(th)), float2(-sin(th), cos(th))) * uv;
}

// Ported from GLSL's `getCausticNoise`. The source used `uv *= m;` /
// `n *= m;` (vec2 *= mat2), which GLSL evaluates as a row-vector * matrix
// product; for the fixed rotation matrix `m = rotate2D(.5)` that is
// algebraically equal to `transpose(m) * v`, i.e. rotating by the *negative*
// angle when expressed as our standard M*v helper above. We bake that sign
// flip in directly (angle -0.5) so water_rotate2d keeps the same right-hand
// M*v convention used by every other ported shader in this file.
static float water_get_caustic_noise(float2 uv, float t, float scale) {
    float2 n = float2(0.1);
    float2 N = float2(0.1);
    for (int j = 0; j < 6; j++) {
        uv = water_rotate2d(uv, -0.5);
        n = water_rotate2d(n, -0.5);
        float2 q = uv * scale + float(j) + n
            + (0.5 + 0.5 * float(j)) * (fmod(float(j), 2.0) - 1.0) * t;
        n += sin(q);
        N += cos(q) / scale;
        scale *= 1.1;
    }
    return (N.x + N.y + 1.0);
}

fragment float4 background_water_fragment_shader(BackgroundFragmentData in [[stage_in]], constant BackgroundUniforms *uniforms [[buffer(0)]])
{
    // Baked tunables, taken from paper.design's Water "Default" preset
    // (packages/shaders-react/src/shaders/water.tsx defaultPreset.params).
    const float size = 1.0;         // u_size, pattern scale relative to image (0.01-7)
    const float waves = 0.3;        // u_waves, noise-driven warp of the caustic field (0-1)
    const float layering = 0.5;     // u_layering, weight of the 2nd caustic octave (0-1)
    const float highlights = 0.07;  // u_highlights, strength of the caustic highlight overlay (0-1)
    // u_edges (0.8) and u_caustic (0.1) in the source only steer where the
    // source image gets re-sampled from (edge-fade + caustic-driven UV warp)
    // and the border frame mask around it; with no source image to distort
    // or mask, both are structurally unreachable here, so they are omitted
    // rather than baked to an arbitrary constant.

    // in.uv is already centered at (0,0) and aspect-corrected, which is
    // exactly what the GLSL's `patternUV` is after its own `v_imageUV - .5`
    // recenter and `* vec2(u_imageAspectRatio, 1.)` aspect correction — so no
    // extra `+= 0.5` shift is needed here (unlike mesh-gradient).
    float2 pattern_uv = in.uv / (0.01 + 0.09 * size);

    float t = uniforms->time;

    float waves_noise = water_snoise((0.3 + 0.1 * sin(t)) * 0.1 * pattern_uv + float2(0.0, 0.4 * t));

    float caustic_noise = water_get_caustic_noise(pattern_uv + waves * float2(1.0, -1.0) * waves_noise, 2.0 * t, 1.5);
    caustic_noise += layering * water_get_caustic_noise(pattern_uv + 2.0 * waves * float2(1.0, -1.0) * waves_noise, 1.5 * t, 2.0);
    caustic_noise = caustic_noise * caustic_noise;
    caustic_noise = max(-0.2, caustic_noise);

    // --- color mapping ---
    // uniforms->colors[0]          -> u_colorBack (flat backing color)
    // uniforms->colors[1]          -> u_colorHighlight (caustic highlight tint)
    // If fewer than 2 colors are configured, colors[0] is reused for both so
    // the shader still renders a valid (highlight-less) flat color instead
    // of reading past what's meaningful.
    float4 color_back = uniforms->colors[0];
    float4 color_highlight = (uniforms->colors_count >= 2) ? uniforms->colors[1] : uniforms->colors[0];

    float3 back_rgb = color_back.rgb * color_back.a;

    // Source: `hightlight = .025 * u_highlights * causticNoise; hightlight
    // *= u_colorHighlight.a;` then blended into color/opacity twice (once as
    // a straight mix, once as an additive glow modulated by wavesNoise).
    float highlight = 0.025 * highlights * caustic_noise * color_highlight.a;

    float3 color = mix(back_rgb, color_highlight.rgb, 0.05 * highlights * caustic_noise);
    color += highlight * (0.5 + 0.5 * waves_noise);

    // Fully opaque: the background establishes the base color that the
    // terminal's own (semi-transparent) surfaces composite over.
    return float4(color, 1.0);
}

// ---- voronoi ----
// ---- voronoi ----
// Metal port of paper.design's "Voronoi" shader
// (https://github.com/paper-design/shaders, Apache-2.0): anti-aliased
// animated Voronoi cell pattern with a two-pass distance field (cell fill +
// smooth cell-border "gap" + optional radial inner-shadow "glow"), colors
// cycling across cells via a per-cell hash value. Original algorithm:
// https://www.shadertoy.com/view/ldl3W8
//
// All helpers are prefixed voronoi_ and this snippet is fully self-contained
// (it does not reuse bg_*/swirl_*/warp_*/... helpers from other ported
// shaders).
//
// Uniform / param mapping notes:
// - u_time                -> uniforms->time (speed already applied CPU-side)
// - u_colors[]/u_colorsCount -> uniforms->colors[0..colors_count-1] (straight
//                            RGBA, premultiplied locally exactly as the GLSL
//                            does: `c.rgb *= c.a`). colors_count is clamped
//                            to [1, 8] the same way color_panels does.
// - u_colorGap, u_colorGlow  -> baked constants, since BackgroundUniforms has
//                            no spare uniform slot for these extra color
//                            roles (same precedent as color_panels' baked
//                            colorBack). Values taken from paper.design's
//                            Voronoi "Default" preset:
//                              colorGap  = '#2e0000' -> (0.180392, 0.0, 0.0, 1.0)
//                              colorGlow = '#ffffff' -> (1.0, 1.0, 1.0, 1.0)
// - u_stepsPerColor       -> baked constant 3.0   (Default preset)
// - u_distortion          -> baked constant 0.4   (Default preset)
// - u_gap                 -> baked constant 0.04  (Default preset)
// - u_glow                -> baked constant 0.0   (Default preset; the glow
//                            math is kept intact but is inert at 0 — other
//                            paper.design presets, e.g. "Cells"/"Bubbles",
//                            use glow up to 0.8-1.0 for a more luminous look)
// - u_scale               -> baked constant 0.5   (Default preset; only used
//                            here for the cell-edge anti-aliasing width, not
//                            for any vertex-side sizing — same role as
//                            color_panels_scale)
// - u_noiseTexture / randomGB(p) -> replaced with a procedural 2-channel hash
//                            voronoi_hash22 (ported from shader-utils.ts's
//                            proceduralHash22 pattern), the same way
//                            warp_hash21 replaced warp's single-channel
//                            texture randomizer.
// - u_scale/u_rotation/u_offsetX/u_fit/u_worldWidth/... (vertex sizing)
//                         -> ignored; our fullscreen vertex shader already
//                            provides the final (centered, aspect-corrected) uv
//
// The original fragment shader tracks a running (color, opacity) pair meant
// to be alpha-composited over whatever sits behind the canvas. Since this
// background is always fully opaque, and the default color roles above are
// all fully opaque too, we drop the opacity bookkeeping entirely and just
// return the composited color with alpha forced to 1.0 — the same
// simplification the "warp" and "mesh_gradient" ports make.

constant float voronoi_two_pi = 6.28318530718;

constant float voronoi_scale = 0.5;
constant float voronoi_distortion = 0.4;
constant float voronoi_gap = 0.04;
constant float voronoi_glow = 0.0;
constant float voronoi_steps_per_color = 3.0;
constant float4 voronoi_color_glow = float4(1.0, 1.0, 1.0, 1.0);
constant float4 voronoi_color_gap = float4(0.180392, 0.0, 0.0, 1.0);

// --- helpers (ported from paper.design shader-utils.ts: proceduralHash22) ---

static float2 voronoi_hash22(float2 p) {
    p = fract(p * float2(0.3183099, 0.3678794)) + 0.1;
    p += dot(p, p.yx + 19.19);
    return fract(float2(p.x * p.y, p.x + p.y));
}

// Two-pass Voronoi distance field for one point `x` at time `t`.
// Returns (edge_distance, nearest_cell_center_offset.xy, cell_hash).
static float4 voronoi_cell(float2 x, float t) {
    float2 ip = floor(x);
    float2 fp = fract(x);

    float2 mg = float2(0.0);
    float2 mr = float2(0.0);
    float md = 8.0;
    float rand = 0.0;

    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 g = float2(float(i), float(j));
            float2 o = voronoi_hash22(ip + g);
            float raw_hash = o.x;
            o = 0.5 + voronoi_distortion * sin(t + voronoi_two_pi * o);
            float2 r = g + o - fp;
            float d = dot(r, r);

            if (d < md) {
                md = d;
                mr = r;
                mg = g;
                rand = raw_hash;
            }
        }
    }

    md = 8.0;
    for (int j = -2; j <= 2; j++) {
        for (int i = -2; i <= 2; i++) {
            float2 g = mg + float2(float(i), float(j));
            float2 o = voronoi_hash22(ip + g);
            o = 0.5 + voronoi_distortion * sin(t + voronoi_two_pi * o);
            float2 r = g + o - fp;
            if (dot(mr - r, mr - r) > 0.00001) {
                md = min(md, dot(0.5 * (mr + r), normalize(r - mr)));
            }
        }
    }

    return float4(md, mr.x, mr.y, rand);
}

fragment float4 background_voronoi_fragment_shader(BackgroundFragmentData in [[stage_in]], constant BackgroundUniforms *uniforms [[buffer(0)]])
{
    float2 shape_uv = in.uv;
    shape_uv *= 1.25;

    float t = uniforms->time;

    float4 voronoi_res = voronoi_cell(shape_uv, t);

    float shape = clamp(voronoi_res.w, 0.0, 1.0);
    int colors_count = clamp(uniforms->colors_count, 1, 8);
    float f_colors_count = float(colors_count);
    // Note: the original GLSL computes `mixer = shape * (colorsCount - 1)`
    // first and then immediately overwrites it with the line below — the
    // first assignment is dead code there too, so it's omitted here.
    float mixer = (shape - 0.5 / f_colors_count) * f_colors_count;
    float steps = max(1.0, voronoi_steps_per_color);

    float4 gradient = uniforms->colors[0];
    gradient.rgb *= gradient.a;
    for (int i = 1; i < 8; i++) {
        if (i >= colors_count) break;
        float local_t = clamp(mixer - float(i - 1), 0.0, 1.0);
        local_t = round(local_t * steps) / steps;
        float4 c = uniforms->colors[i];
        c.rgb *= c.a;
        gradient = mix(gradient, c, local_t);
    }

    if ((mixer < 0.0) || (mixer > (f_colors_count - 1.0))) {
        float local_t = mixer + 1.0;
        if (mixer > (f_colors_count - 1.0)) {
            local_t = mixer - (f_colors_count - 1.0);
        }
        local_t = round(local_t * steps) / steps;
        float4 c_first = uniforms->colors[0];
        c_first.rgb *= c_first.a;
        float4 c_last = uniforms->colors[colors_count - 1];
        c_last.rgb *= c_last.a;
        gradient = mix(c_last, c_first, local_t);
    }

    float3 cell_color = gradient.rgb;

    float glows = length(float2(voronoi_res.y, voronoi_res.z) * voronoi_glow);
    glows = pow(glows, 1.5);

    float3 color = mix(cell_color, voronoi_color_glow.rgb * voronoi_color_glow.a, voronoi_color_glow.a * glows);

    float edge = voronoi_res.x;
    float smooth_edge = 0.02 / (2.0 * voronoi_scale) * (1.0 + 0.5 * voronoi_gap);
    edge = smoothstep(voronoi_gap - smooth_edge, voronoi_gap + smooth_edge, edge);

    color = mix(voronoi_color_gap.rgb * voronoi_color_gap.a, color, edge);

    // Fully opaque: the background establishes the base color that the
    // terminal's own (semi-transparent) surfaces composite over.
    return float4(color, 1.0);
}

// ---- smoke_ring ----
// ---- smoke-ring ----
// Metal port of paper.design's "Smoke Ring" shader
// (https://github.com/paper-design/shaders, Apache-2.0): a radial multi-
// colored gradient shaped by layered value noise into a soft, smoky ring.
// Math translated 1:1 from the GLSL source; only the color/uniform plumbing
// was adapted to Warp's BackgroundUniforms contract. All helpers are
// prefixed "smoke_ring_" and this file is fully self-contained (no shared
// bg_*/swirl_*/... helpers reused from other ported shaders).
//
// Uniform mapping notes:
// - u_time                    -> uniforms->time (speed already applied CPU-side)
// - u_colorBack (vec4)        -> uniforms->colors[0] (background fill, shown
//                                outside/behind the ring)
// - u_colors[] (vec4[<=10])   -> uniforms->colors[1..colors_count-1] (ring
//                                gradient palette, ordered as in the source;
//                                capped at 7 entries since our flat array
//                                only has 8 slots total and slot 0 is
//                                reserved for the backdrop color)
// - u_colorsCount              -> colors_count - 1 (ring color count)
// - u_noiseTexture/randomR     -> replaced with procedural hash-based value
//                                noise (smoke_ring_hash21 / smoke_ring_value_noise);
//                                no texture sampling available or needed here
// - u_thickness                -> baked constant 0.65 (paper.design "Default"
//                                preset: packages/shaders-react/src/shaders/
//                                smoke-ring.tsx defaultPreset.params.thickness)
// - u_radius                   -> baked constant 0.25 (default preset)
// - u_innerShape                -> baked constant 0.7  (default preset)
// - u_noiseScale                -> baked constant 3.0  (default preset)
// - u_noiseIterations            -> baked constant 8   (default preset; also
//                                the shader's own max, smokeRingMeta.maxNoiseIterations)
// - u_scale/u_rotation/u_offsetX/u_fit/u_worldWidth/... (vertex sizing)
//                              -> ignored; our fullscreen vertex shader
//                                already provides the final (centered,
//                                aspect-corrected) uv
// ============================================================================

constant float smoke_ring_thickness        = 0.65;
constant float smoke_ring_radius           = 0.25;
constant float smoke_ring_inner_shape      = 0.7;
constant float smoke_ring_noise_scale      = 3.0;
constant int   smoke_ring_noise_iterations = 8;
constant int   smoke_ring_max_ring_colors  = 7;

constant float smoke_ring_pi     = 3.14159265358979323846;
constant float smoke_ring_two_pi = 6.28318530718;

// --- helpers (procedural replacement for paper.design's texture-based
// randomizer; ported from shader-utils.ts's proceduralHash21 pattern) ---

static float smoke_ring_hash21(float2 p) {
    p = fract(p * float2(0.3183099, 0.3678794)) + 0.1;
    p += dot(p, p + 19.19);
    return fract(p.x * p.y);
}

static float smoke_ring_value_noise(float2 st) {
    float2 i = floor(st);
    float2 f = fract(st);
    float a = smoke_ring_hash21(i);
    float b = smoke_ring_hash21(i + float2(1.0, 0.0));
    float c = smoke_ring_hash21(i + float2(0.0, 1.0));
    float d = smoke_ring_hash21(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    float x1 = mix(a, b, u.x);
    float x2 = mix(c, d, u.x);
    return mix(x1, x2, u.y);
}

// Two-channel fractal value noise (paper.design's fbm), used to jitter the
// smoke pattern along two independently-scrolling phases.
static float2 smoke_ring_fbm(float2 n0, float2 n1) {
    float2 total = float2(0.0);
    float amplitude = 0.4;
    for (int i = 0; i < 8; i++) {
        if (i >= smoke_ring_noise_iterations) break;
        total.x += smoke_ring_value_noise(n0) * amplitude;
        total.y += smoke_ring_value_noise(n1) * amplitude;
        n0 *= 1.99;
        n1 *= 1.99;
        amplitude *= 0.65;
    }
    return total;
}

static float smoke_ring_get_noise(float2 uv, float2 p_uv, float t) {
    float2 p_uv_left = p_uv + 0.03 * t;
    float period = max(abs(smoke_ring_noise_scale * smoke_ring_two_pi), 1e-6);
    float2 p_uv_right = float2(fract(p_uv.x / period) * period, p_uv.y) + 0.03 * t;
    float2 noise = smoke_ring_fbm(p_uv_left, p_uv_right);
    return mix(noise.y, noise.x, smoothstep(-0.25, 0.25, uv.x));
}

static float smoke_ring_get_ring_shape(float2 uv) {
    float radius = smoke_ring_radius;
    float thickness = smoke_ring_thickness;

    float distance = length(uv);
    float ring_value = 1.0 - smoothstep(radius, radius + thickness, distance);
    ring_value *= smoothstep(radius - pow(smoke_ring_inner_shape, 3.0) * thickness, radius, distance);

    return ring_value;
}

fragment float4 background_smoke_ring_fragment_shader(
    BackgroundFragmentData in [[stage_in]],
    constant BackgroundUniforms *uniforms [[buffer(0)]])
{
    int colors_count = uniforms->colors_count;
    if (colors_count < 1) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    float4 color_back = uniforms->colors[0];
    float3 bg_rgb = color_back.rgb * color_back.a;

    int ring_count = min(max(0, colors_count - 1), smoke_ring_max_ring_colors);
    if (ring_count <= 0) {
        // No ring colors configured beyond the backdrop: just the flat fill.
        return float4(bg_rgb, 1.0);
    }

    float2 shape_uv = in.uv;

    float t = uniforms->time;

    float cycle_duration = 3.0;
    float period2 = 2.0 * cycle_duration;
    float local_time1 = fract((0.1 * t + cycle_duration) / period2) * period2;
    float local_time2 = fract((0.1 * t) / period2) * period2;
    float time_blend = 0.5 + 0.5 * sin(0.1 * t * smoke_ring_pi / cycle_duration - 0.5 * smoke_ring_pi);

    // GLSL's atan(y, x) is the two-argument arctangent == Metal's atan2(y, x).
    float atg = atan2(shape_uv.y, shape_uv.x) + 0.001;
    float l = length(shape_uv);
    // GLSL's inversesqrt == Metal's rsqrt.
    float radial_offset = 0.5 * l - rsqrt(max(1e-4, l));
    float2 polar_uv1 = float2(atg, local_time1 - radial_offset) * smoke_ring_noise_scale;
    float2 polar_uv2 = float2(atg, local_time2 - radial_offset) * smoke_ring_noise_scale;

    float noise1 = smoke_ring_get_noise(shape_uv, polar_uv1, t);
    float noise2 = smoke_ring_get_noise(shape_uv, polar_uv2, t);

    float noise = mix(noise1, noise2, time_blend);

    shape_uv *= (0.8 + 1.2 * noise);

    float ring_shape = smoke_ring_get_ring_shape(shape_uv);

    float mixer = ring_shape * ring_shape * float(ring_count - 1);
    int idx_last = ring_count - 1;
    float4 gradient = uniforms->colors[1 + idx_last];
    gradient.rgb *= gradient.a;
    for (int i = smoke_ring_max_ring_colors - 2; i >= 0; i--) {
        float local_t = clamp(mixer - float(idx_last - i - 1), 0.0, 1.0);
        float4 c = uniforms->colors[1 + i];
        c.rgb *= c.a;
        gradient = mix(gradient, c, local_t);
    }

    float3 color = gradient.rgb * ring_shape;
    float opacity = gradient.a * ring_shape;

    color = color + bg_rgb * (1.0 - opacity);
    // Kept for parity with the source's premultiplied composite math, even
    // though the background is always returned fully opaque below.
    opacity = opacity + color_back.a * (1.0 - opacity);
    (void)opacity;

    // Dither to fight banding (source's colorBandingFix), using window-space
    // fragment position in place of gl_FragCoord.
    color += 1.0 / 256.0 * (fract(sin(dot(0.014 * in.position.xy, float2(12.9898, 78.233))) * 43758.5453123) - 0.5);

    // Fully opaque: the background establishes the base color that the
    // terminal's own (semi-transparent) surfaces composite over.
    return float4(color, 1.0);
}

// ---- spiral ----
// ---- spiral ----
// Metal port of paper.design's "spiral" shader
// (https://github.com/paper-design/shaders, Apache-2.0): a single-colored
// animated spiral that morphs across a wide range of shapes - from crisp,
// thin-lined geometry to flowing whirlpool forms and wavy, abstract rings.
// Math translated 1:1 from the GLSL source; only the color/uniform plumbing
// was adapted to Warp's BackgroundUniforms contract. All helpers are
// prefixed "spiral_" and this file is fully self-contained (no shared bg_*
// helpers, or helpers from other ported shaders, are reused).

// --- helpers (ported from paper.design shader-utils.ts: simplexNoise) ---

// GLSL's `mod(x, y)` keeps the sign of `y` (unlike Metal/HLSL `fmod`, which
// keeps the sign of `x`). All call sites below only ever see non-negative
// operands in practice, but we implement true GLSL semantics to be safe.
static float2 spiral_glsl_mod(float2 x, float y) {
    return x - y * floor(x / y);
}
static float3 spiral_glsl_mod(float3 x, float y) {
    return x - y * floor(x / y);
}

static float3 spiral_permute(float3 x) {
    return spiral_glsl_mod(((x * 34.0) + 1.0) * x, 289.0);
}

// Ashima Arts simplex noise (2D), ported verbatim.
static float spiral_snoise(float2 v) {
    const float4 C = float4(0.211324865405187, 0.366025403784439,
        -0.577350269189626, 0.024390243902439);
    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = spiral_glsl_mod(i, 289.0);
    float3 p = spiral_permute(spiral_permute(i.y + float3(0.0, i1.y, 1.0))
        + i.x + float3(0.0, i1.x, 1.0));
    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy),
        dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;
    float3 x = 2.0 * fract(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

fragment float4 background_spiral_fragment_shader(
    BackgroundFragmentData in [[stage_in]],
    constant BackgroundUniforms *uniforms [[buffer(0)]])
{
    // --- baked tunables: paper.design spiral "Default" preset values ---
    // (packages/shaders-react/src/shaders/spiral.tsx defaultPreset.params)
    const float density_param = 1.0;    // u_density, 0-1 (spacing falloff / perspective)
    const float distortion = 0.0;       // u_distortion, 0-1
    const float stroke_width = 0.5;     // u_strokeWidth, 0-1
    const float stroke_taper = 0.0;     // u_strokeTaper, 0-1
    const float stroke_cap = 0.0;       // u_strokeCap, 0-1
    const float noise_amount = 0.0;     // u_noise, 0-1
    const float noise_frequency = 0.0;  // u_noiseFrequency, 0-1
    const float softness = 0.0;         // u_softness, 0-1

    const float pi = 3.14159265358979323846;
    const float two_pi = 6.28318530718;

    int colors_count = uniforms->colors_count;
    if (colors_count < 1) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    // --- color mapping ---
    // The source GLSL only has two color uniforms (u_colorFront the ink /
    // stroke color, u_colorBack the base fill), a duty-cycle "ink on paper"
    // style pattern, mirroring the "waves" port's convention:
    //   colors[0] -> u_colorFront (the spiral stroke color)
    //   colors[1] -> u_colorBack  (the base / background color)
    // Any colors beyond index 1 are intentionally unused (this effect is
    // inherently two-tone). If fewer than 2 colors are configured, colors[0]
    // is reused for both so the shader still renders a flat, valid color.
    float4 color_front = uniforms->colors[0];
    float4 color_back = (colors_count >= 2) ? uniforms->colors[1] : uniforms->colors[0];

    // GLSL: vec2 uv = 2. * v_patternUV; -- literal scale carried over
    // verbatim. in.uv is already centered at (0,0) and aspect-corrected,
    // matching v_patternUV's convention here, so (unlike mesh-gradient) no
    // `+= 0.5` shift is needed.
    float2 uv = 2.0 * in.uv;

    float t = uniforms->time;
    float l = length(uv);
    float density_c = clamp(density_param, 0.0, 1.0);
    l = pow(max(l, 1e-6), density_c);
    // GLSL's atan(y, x) is the two-argument arctangent == Metal's atan2(y, x).
    float angle = atan2(uv.y, uv.x) - t;
    float angle_normalised = angle / two_pi;

    angle_normalised += 0.125 * noise_amount * spiral_snoise(16.0 * pow(noise_frequency, 3.0) * uv);

    float offset = l + angle_normalised;
    offset -= distortion * (sin(4.0 * l - 0.5 * t) * cos(pi + l + 0.5 * t));
    float stripe = fract(offset);

    float shape = 2.0 * abs(stripe - 0.5);
    float width = 1.0 - clamp(stroke_width, 0.005 * stroke_taper, 1.0);

    float w_cap = mix(width, (1.0 - stripe) * (1.0 - step(0.5, stripe)), (1.0 - clamp(l, 0.0, 1.0)));
    width = mix(width, w_cap, stroke_cap);
    width *= (1.0 - clamp(stroke_taper, 0.0, 1.0) * l);

    float fw = fwidth(offset);
    float fw_mult = 4.0 - 3.0 * (smoothstep(0.05, 0.4, 2.0 * stroke_width) * smoothstep(0.05, 0.4, 2.0 * (1.0 - stroke_width)));
    float pixel_size = mix(fw_mult * fw, fwidth(shape), clamp(fw, 0.0, 1.0));
    pixel_size = mix(pixel_size, 0.002, stroke_cap * (1.0 - clamp(l, 0.0, 1.0)));

    float res = smoothstep(width - pixel_size - softness, width + pixel_size + softness, shape);

    float3 fg_color = color_front.rgb * color_front.a;
    float fg_opacity = color_front.a;
    float3 bg_color = color_back.rgb * color_back.a;
    float bg_opacity = color_back.a;

    float3 color = fg_color * res;
    float opacity = fg_opacity * res;

    color += bg_color * (1.0 - opacity);
    opacity += bg_opacity * (1.0 - opacity);
    // Kept for parity with the source's premultiplied composite math, even
    // though the background is always returned fully opaque below.
    (void)opacity;

    // Dither to fight banding (source's colorBandingFix), using window-space
    // fragment position in place of gl_FragCoord.
    color += 1.0 / 256.0 * (fract(sin(dot(0.014 * in.position.xy, float2(12.9898, 78.233))) * 43758.5453123) - 0.5);

    // Fully opaque: the background establishes the base color that the
    // terminal's own (semi-transparent) surfaces composite over.
    return float4(color, 1.0);
}

// ---- grain_gradient ----
// ---- grain-gradient ----
// Metal port of paper.design's "grain-gradient" shader
// (https://github.com/paper-design/shaders, Apache-2.0): a multi-color
// gradient whose band edges are warped by simplex/value-noise "grain" and
// an fbm distortion field. The source shader exposes 7 selectable band
// shapes (wave / dots / truchet / corners / ripple / blob / sphere); we bake
// the shape selector at its "Default" preset value (corners) since our
// BackgroundUniforms contract has no per-effect shape uniform, but the full
// 1:1-translated branch for every shape is kept so the constant can be
// flipped later to try a different look.
//
// All helpers are prefixed "grain_gradient_" and this snippet is fully
// self-contained (no bg_*/swirl_*/warp_* helpers from other ported shaders
// are reused, even where the math is identical).

// --- helpers (ported from paper.design shader-utils.ts) ---

// GLSL's `mod(x, y)` keeps the sign of `y` (unlike Metal/HLSL `fmod`, which
// keeps the sign of `x`). Used by the simplex-noise permute chain below,
// which can see negative operands, so we implement true GLSL semantics.
static float2 grain_gradient_glsl_mod(float2 x, float y) {
    return x - y * floor(x / y);
}
static float3 grain_gradient_glsl_mod(float3 x, float y) {
    return x - y * floor(x / y);
}

static float3 grain_gradient_permute(float3 x) {
    return grain_gradient_glsl_mod(((x * 34.0) + 1.0) * x, 289.0);
}

// Ashima Arts simplex noise (2D), ported verbatim (source's `simplexNoise`).
static float grain_gradient_snoise(float2 v) {
    const float4 C = float4(0.211324865405187, 0.366025403784439,
        -0.577350269189626, 0.024390243902439);
    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = grain_gradient_glsl_mod(i, 289.0);
    float3 p = grain_gradient_permute(grain_gradient_permute(i.y + float3(0.0, i1.y, 1.0))
        + i.x + float3(0.0, i1.x, 1.0));
    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy),
        dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;
    float3 x = 2.0 * fract(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

// GLSL mat2(cos,sin,-sin,cos) is column-major: col0=(cos,sin), col1=(-sin,cos).
// Metal's float2x2 constructor also takes columns, so this matches exactly
// (source's `rotation2` helper).
static float2 grain_gradient_rotate(float2 uv, float th) {
    return float2x2(float2(cos(th), sin(th)), float2(-sin(th), cos(th))) * uv;
}

// Procedural replacement for the source's texture-backed `randomR` (which
// sampled a pre-computed noise texture via `textureRandomizerR`). We don't
// have that texture on this platform, so we substitute the library's own
// procedural hash (`proceduralHash21` in shader-utils.ts) wherever `randomR`
// was called; it's the same "hash the cell coordinate" role.
static float grain_gradient_hash21(float2 p) {
    p = fract(p * float2(0.3183099, 0.3678794)) + 0.1;
    p += dot(p, p + 19.19);
    return fract(p.x * p.y);
}

// Source's `proceduralHash11`, used directly (not texture-backed) by the
// "dots" shape branch.
static float grain_gradient_hash11(float p) {
    p = fract(p * 0.3183099) + 0.1;
    p *= p + 19.19;
    return fract(p * p);
}

// Source's `valueNoiseR`, rewired onto grain_gradient_hash21 in place of the
// texture-sampling `randomR`.
static float grain_gradient_value_noise(float2 st) {
    float2 i = floor(st);
    float2 f = fract(st);
    float a = grain_gradient_hash21(i);
    float b = grain_gradient_hash21(i + float2(1.0, 0.0));
    float c = grain_gradient_hash21(i + float2(0.0, 1.0));
    float d = grain_gradient_hash21(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    float x1 = mix(a, b, u.x);
    float x2 = mix(c, d, u.x);
    return mix(x1, x2, u.y);
}

// Source's `fbmR`. NOTE: this preserves an apparent upstream quirk verbatim:
// both `valueNoiseR(n2)` and `valueNoiseR(n3)` accumulate into `total.z`
// (not `.w`), so `total.w` is always 0. That's exactly what the shipped
// paper.design GLSL does, so we keep it rather than "fixing" it.
static float4 grain_gradient_fbm(float2 n0, float2 n1, float2 n2, float2 n3) {
    float amplitude = 0.2;
    float4 total = float4(0.0);
    for (int i = 0; i < 3; i++) {
        n0 = grain_gradient_rotate(n0, 0.3);
        n1 = grain_gradient_rotate(n1, 0.3);
        n2 = grain_gradient_rotate(n2, 0.3);
        n3 = grain_gradient_rotate(n3, 0.3);
        total.x += grain_gradient_value_noise(n0) * amplitude;
        total.y += grain_gradient_value_noise(n1) * amplitude;
        total.z += grain_gradient_value_noise(n2) * amplitude;
        total.z += grain_gradient_value_noise(n3) * amplitude;
        n0 *= 1.99;
        n1 *= 1.99;
        n2 *= 1.99;
        n3 *= 1.99;
        amplitude *= 0.6;
    }
    return total;
}

// Source's `truchet`, ported 1:1.
static float2 grain_gradient_truchet(float2 uv, float idx) {
    idx = fract((idx - 0.5) * 2.0);
    if (idx > 0.75) {
        uv = float2(1.0) - uv;
    } else if (idx > 0.5) {
        uv = float2(1.0 - uv.x, uv.y);
    } else if (idx > 0.25) {
        uv = 1.0 - float2(1.0 - uv.x, uv.y);
    }
    return uv;
}

fragment float4 background_grain_gradient_fragment_shader(
    BackgroundFragmentData in [[stage_in]],
    constant BackgroundUniforms *uniforms [[buffer(0)]])
{
    // --- baked tunables: paper.design grain-gradient "Default" preset
    // values (packages/shaders-react/src/shaders/grain-gradient.tsx
    // defaultPreset.params, github.com/paper-design/shaders, checked 2026-07-05) ---
    const float softness = 0.5;       // u_softness, 0-1
    const float intensity = 0.5;      // u_intensity, 0-1
    const float noise_amount = 0.25;  // u_noise, 0-1
    // u_shape: 1=wave 2=dots 3=truchet 4=corners(default) 5=ripple 6=blob 7=sphere.
    const int shape_select = 4;

    int colors_count = uniforms->colors_count;
    if (colors_count < 1) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    // --- color mapping ---
    // uniforms->colors[0]          -> u_colorBack (background fill color)
    // uniforms->colors[1..count-1] -> u_colors[0..] (ordered gradient stop
    // palette), capped at 7 stops to match the source's maxColorCount.
    // (Same convention as the swirl_/warp_ ports: our flat colors[8] array
    // reserves slot 0 for the background since the source keeps u_colorBack
    // and u_colors as separate uniforms.)
    float4 color_back = uniforms->colors[0];
    int stop_count = min(max(0, colors_count - 1), 7);

    if (stop_count < 1) {
        // No gradient stops configured: nothing to blend, just show the
        // flat background color.
        return float4(color_back.rgb, 1.0);
    }
    float colors_count_f = float(stop_count);

    const float first_frame_offset = 7.0;
    float t = 0.1 * (uniforms->time + first_frame_offset);

    // in.uv is centered at (0,0) and aspect-corrected already. The source's
    // v_objectUV / v_patternUV (sizing-adjusted UVs coming out of the vertex
    // shader) both collapse to this directly here because the sizing
    // uniforms that would otherwise transform them (u_rotation, u_scale,
    // u_offsetX/Y) are all at their identity defaults (0, 1, 0/0) and our
    // fullscreen vertex shader already hands us the final screen UV.
    float2 base_uv = in.uv;

    float2 shape_uv;
    float2 grain_uv;
    if (shape_select > 3) {
        // "Object"-sized shapes (corners/ripple/blob/sphere): source scales
        // grain_uv by `v_objectBoxSize` (the object box's pixel size) so the
        // grain frequency stays consistent regardless of window size; we
        // approximate that box size with the viewport size in pixels, which
        // matches it under the default fit="contain"/worldWidth=0 sizing.
        shape_uv = base_uv;
        grain_uv = base_uv * uniforms->viewport_size * 0.7;
    } else {
        // "Pattern"-sized shapes (wave/dots/truchet): source's grain_uv is
        // `100. * v_patternUV`, further divided by a fit-dependent box-scale
        // factor only when u_fit > 0; the wave/dots/truchet presets all ship
        // with fit="none", so that division is skipped and the net factor
        // collapses to the literal 100 * 1.6 = 160 used below.
        shape_uv = 0.5 * base_uv;
        grain_uv = 160.0 * base_uv;
    }

    float shape = 0.0;

    if (shape_select == 1) {
        // Sine wave
        float wave = cos(0.5 * shape_uv.x - 4.0 * t) * sin(1.5 * shape_uv.x + 2.0 * t) * (0.75 + 0.25 * cos(6.0 * t));
        shape = 1.0 - smoothstep(-1.0, 1.0, shape_uv.y + wave);
    } else if (shape_select == 2) {
        // Grid (dots)
        float stripe_idx = floor(2.0 * shape_uv.x / 6.28318530718);
        float rnd = grain_gradient_hash11(stripe_idx * 100.0);
        rnd = sign(rnd - 0.5) * pow(4.0 * abs(rnd), 0.3);
        shape = sin(shape_uv.x) * cos(shape_uv.y - 5.0 * rnd * t);
        shape = pow(abs(shape), 4.0);
    } else if (shape_select == 3) {
        // Truchet pattern
        float n2 = grain_gradient_value_noise(shape_uv * 0.4 - 3.75 * t);
        shape_uv.x += 10.0;
        shape_uv *= 0.6;

        float2 tile = grain_gradient_truchet(fract(shape_uv), grain_gradient_hash21(floor(shape_uv)));

        float distance1 = length(tile);
        float distance2 = length(tile - float2(1.0));

        n2 -= 0.5;
        n2 *= 0.1;
        shape = smoothstep(0.2, 0.55, distance1 + n2) * (1.0 - smoothstep(0.45, 0.8, distance1 - n2));
        shape += smoothstep(0.2, 0.55, distance2 + n2) * (1.0 - smoothstep(0.45, 0.8, distance2 - n2));

        shape = pow(shape, 1.5);
    } else if (shape_select == 4) {
        // Corners
        shape_uv *= 0.6;
        float2 outer = float2(0.5);

        float2 bl = smoothstep(float2(0.0), outer, shape_uv + float2(0.1 + 0.1 * sin(3.0 * t), 0.2 - 0.1 * sin(5.25 * t)));
        float2 tr = smoothstep(float2(0.0), outer, 1.0 - shape_uv);
        shape = 1.0 - bl.x * bl.y * tr.x * tr.y;

        shape_uv = -shape_uv;
        bl = smoothstep(float2(0.0), outer, shape_uv + float2(0.1 + 0.1 * sin(3.0 * t), 0.2 - 0.1 * cos(5.25 * t)));
        tr = smoothstep(float2(0.0), outer, 1.0 - shape_uv);
        shape -= bl.x * bl.y * tr.x * tr.y;

        shape = 1.0 - smoothstep(0.0, 1.0, shape);
    } else if (shape_select == 5) {
        // Ripple
        shape_uv *= 2.0;
        float dist = length(0.4 * shape_uv);
        float waves = sin(pow(dist, 1.2) * 5.0 - 3.0 * t) * 0.5 + 0.5;
        shape = waves;
    } else if (shape_select == 6) {
        // Blob
        float tb = t * 2.0;

        float2 f1_traj = 0.25 * float2(1.3 * sin(tb), 0.2 + 1.3 * cos(0.6 * tb + 4.0));
        float2 f2_traj = 0.2 * float2(1.2 * sin(-tb), 1.3 * sin(1.6 * tb));
        float2 f3_traj = 0.25 * float2(1.7 * cos(-0.6 * tb), cos(-1.6 * tb));
        float2 f4_traj = 0.3 * float2(1.4 * cos(0.8 * tb), 1.2 * sin(-0.6 * tb - 3.0));

        // Source writes this as `clamp(0., 1., length(...))`, i.e. GLSL
        // clamp(x=0, minVal=1, maxVal=length(...)); mechanically that's
        // min(max(0,1), L) = min(1, L), which (since L = length(...) >= 0
        // always) is numerically identical to the conventional
        // clamp(L, 0, 1) used here.
        shape = 0.5 * pow(1.0 - clamp(length(shape_uv + f1_traj), 0.0, 1.0), 5.0);
        shape += 0.5 * pow(1.0 - clamp(length(shape_uv + f2_traj), 0.0, 1.0), 5.0);
        shape += 0.5 * pow(1.0 - clamp(length(shape_uv + f3_traj), 0.0, 1.0), 5.0);
        shape += 0.5 * pow(1.0 - clamp(length(shape_uv + f4_traj), 0.0, 1.0), 5.0);

        shape = smoothstep(0.0, 0.9, shape);
        float edge = smoothstep(0.25, 0.3, shape);
        shape = mix(0.0, shape, edge);
    } else {
        // Sphere
        shape_uv *= 2.0;
        float d = 1.0 - pow(length(shape_uv), 2.0);
        float3 pos = float3(shape_uv, sqrt(max(d, 0.0)));
        float3 light_pos = normalize(float3(cos(1.5 * t), 0.8, sin(1.25 * t)));
        shape = 0.5 + 0.5 * dot(light_pos, pos);
        shape *= step(0.0, d);
    }

    float base_noise = grain_gradient_snoise(grain_uv * 0.5);
    float4 fbm_vals = grain_gradient_fbm(
        0.002 * grain_uv + 10.0,
        0.003 * grain_uv,
        0.001 * grain_uv,
        grain_gradient_rotate(0.4 * grain_uv, 2.0));
    float grain_dist = base_noise * grain_gradient_snoise(grain_uv * 0.2) - fbm_vals.x - fbm_vals.y;
    float raw_noise = 0.75 * base_noise - fbm_vals.w - fbm_vals.z;
    float noise = clamp(raw_noise, 0.0, 1.0);

    shape += intensity * 2.0 / colors_count_f * (grain_dist + 0.5);
    shape += noise_amount * 10.0 / colors_count_f * noise;

    float aa = fwidth(shape);

    shape = clamp(shape - 0.5 / colors_count_f, 0.0, 1.0);
    float total_shape = smoothstep(0.0, softness + 2.0 * aa, clamp(shape * colors_count_f, 0.0, 1.0));
    float mixer = shape * (colors_count_f - 1.0);

    float4 gradient = uniforms->colors[1];
    gradient.rgb *= gradient.a;
    for (int i = 1; i < stop_count; i++) {
        float local_t = clamp(mixer - float(i - 1), 0.0, 1.0);
        local_t = smoothstep(0.5 - 0.5 * softness - aa, 0.5 + 0.5 * softness + aa, local_t);

        float4 c = uniforms->colors[i + 1];
        c.rgb *= c.a;
        gradient = mix(gradient, c, local_t);
    }

    float3 color = gradient.rgb * total_shape;
    float opacity = gradient.a * total_shape;

    float3 bg_rgb = color_back.rgb * color_back.a;
    color = color + bg_rgb * (1.0 - opacity);
    // Kept for parity with the source's premultiplied composite math, even
    // though the background is always returned fully opaque below.
    opacity = opacity + color_back.a * (1.0 - opacity);
    (void)opacity;

    // Fully opaque: the background establishes the base color that the
    // terminal's own (semi-transparent) surfaces composite over.
    return float4(color, 1.0);
}

// ---- gem_smoke ----
// ---- gem-smoke ----
// Metal port of paper.design's "Gem Smoke" shader
// (https://github.com/paper-design/shaders, Apache-2.0): animated color
// fields swirling behind (and glowing outside) a glassy silhouette, giving
// the illusion of smoke trapped inside a gem-like shape. Math translated 1:1
// from the GLSL source; only the color/uniform plumbing was adapted to
// Warp's BackgroundUniforms contract. All helpers are prefixed "gem_smoke_"
// and this file is fully self-contained (no shared bg_*/swirl_*/... helpers
// reused from other ported shaders).
//
// The original shader supports an uploaded logo/image (u_isImage == true)
// whose alpha+roundness map is sampled from a texture (u_image) that was
// pre-processed off-GPU by a Poisson-solver pass (toProcessedGemSmoke in
// gem-smoke.ts). Warp's background has no such uploaded image, so this port
// hard-codes u_isImage == false and bakes u_shape to the "diamond" shape --
// exactly the branch paper.design's own Default/Fire/Fluorescent/Infrared
// presets all use when no image is supplied (packages/shaders-react/src/
// shaders/gem-smoke.tsx: every preset ships `image = ''`, `shape: 'diamond'`).
// The circle/daisy/metaballs/"none" shape branches and the 9x9
// Gaussian-blurred image-sampling path are therefore dropped entirely --
// they are unreachable dead code in the no-image case.
//
// Uniform mapping notes:
// - u_time              -> uniforms->time (speed already applied CPU-side)
// - u_colors[]/u_colorsCount/u_colorInner/u_colorBack -> all folded into one
//   flat uniforms->colors[0..colors_count-1] array (see gem_smoke_split_colors
//   below), since Warp's BackgroundUniforms exposes a single color list
//   instead of paper.design's three separate color uniforms:
//     * colors_count == 1: that one color is reused for the smoke gradient,
//       the inner color, and the backdrop color.
//     * colors_count == 2: colors[0] is the (single) smoke gradient color;
//       colors[1] is reused for both the inner color and the backdrop color.
//     * colors_count >= 3: colors[0 .. colors_count-3] are the smoke
//       gradient colors (u_colors[], capped at 6 entries -- matches
//       gemSmokeMeta.maxColorCount), colors[colors_count-2] is u_colorInner,
//       and colors[colors_count-1] is u_colorBack.
// - u_innerDistortion   -> baked constant 0.8  (Default preset)
// - u_outerDistortion   -> baked constant 0.6  (Default preset)
// - u_outerGlow         -> baked constant 0.55 (Default preset)
// - u_innerGlow         -> baked constant 1.0  (Default preset)
// - u_offset            -> baked constant 0.0  (Default preset)
// - u_angle             -> baked constant 0.0  (Default preset)
// - u_size              -> baked constant 0.8  (Default preset)
// - u_shape             -> baked to "diamond" (index 3); see note above
// - u_isImage           -> baked to false; see note above
// - u_image/u_imageAspectRatio, and all vertex-sizing uniforms
//   (u_scale/u_rotation/u_offsetX/u_offsetY/u_fit/u_worldWidth/...)
//   -> ignored; our fullscreen vertex shader already provides the final
//      (centered, aspect-corrected) uv, and there is no image to sample.
// ============================================================================

constant float gem_smoke_inner_distortion = 0.8;
constant float gem_smoke_outer_distortion = 0.6;
constant float gem_smoke_outer_glow       = 0.55;
constant float gem_smoke_inner_glow       = 1.0;
constant float gem_smoke_offset           = 0.0;
constant float gem_smoke_angle_deg        = 0.0;
constant float gem_smoke_size             = 0.8;

constant float gem_smoke_pi = 3.14159265358979323846;

// GLSL mat2(cos, sin, -sin, cos) is column-major: col0=(cos,sin),
// col1=(-sin,cos). Metal float2x2 takes columns, so this matches exactly.
static float2 gem_smoke_rotate(float2 uv, float th) {
    return float2x2(float2(cos(th), sin(th)), float2(-sin(th), cos(th))) * uv;
}

// Result of splitting Warp's flat uniforms->colors[] list into gem-smoke's
// three color roles (smoke gradient / inner flat color / backdrop color).
// See the "Uniform mapping notes" above for the exact split rule.
struct gem_smoke_color_roles {
    float4 grad_colors[6];
    int grad_count;
    float4 color_inner;
    float4 color_back;
};

static gem_smoke_color_roles gem_smoke_split_colors(constant BackgroundUniforms *uniforms) {
    gem_smoke_color_roles r;
    int total = min(max(uniforms->colors_count, 1), 8);

    if (total == 1) {
        r.grad_colors[0] = uniforms->colors[0];
        r.grad_count = 1;
        r.color_inner = uniforms->colors[0];
        r.color_back = uniforms->colors[0];
    } else if (total == 2) {
        r.grad_colors[0] = uniforms->colors[0];
        r.grad_count = 1;
        r.color_inner = uniforms->colors[1];
        r.color_back = uniforms->colors[1];
    } else {
        int grad_count = total - 2; // 1..6
        for (int i = 0; i < grad_count; i++) {
            r.grad_colors[i] = uniforms->colors[i];
        }
        r.grad_count = grad_count;
        r.color_inner = uniforms->colors[total - 2];
        r.color_back = uniforms->colors[total - 1];
    }

    return r;
}

fragment float4 background_gem_smoke_fragment_shader(
    BackgroundFragmentData in [[stage_in]],
    constant BackgroundUniforms *uniforms [[buffer(0)]])
{
    float time = uniforms->time;

    // --- Shape mask: paper.design's "diamond" shape branch, evaluated
    // directly from the object UV (v_objectUV -> in.uv). The GLSL builds
    // this from `uv = v_objectUV + .5; uv.y = 1. - uv.y; shapeUV = uv - .5;`,
    // which algebraically reduces to just flipping the y sign of v_objectUV.
    float2 shape_uv = float2(in.uv.x, -in.uv.y);
    shape_uv = gem_smoke_rotate(shape_uv, 0.25 * gem_smoke_pi);
    shape_uv *= 1.42;
    shape_uv += 0.5;
    float2 mask = min(shape_uv, 1.0 - shape_uv);
    float2 pixel_thickness = float2(0.15);
    float mask_x = smoothstep(0.0, pixel_thickness.x, mask.x);
    float mask_y = smoothstep(0.0, pixel_thickness.y, mask.y);
    mask_x = pow(mask_x, 0.25);
    mask_y = pow(mask_y, 0.25);
    float edge = clamp(1.0 - mask_x * mask_y, 0.0, 1.0);

    // GLSL's fwidth == Metal's fwidth (same name, same semantics).
    float img_alpha = 1.0 - smoothstep(0.9 - 2.0 * fwidth(edge), 0.9, edge);
    float roundness = 1.0 - edge;

    // --- Smoke UV setup ---
    float2 smoke_uv = in.uv;
    smoke_uv = gem_smoke_rotate(smoke_uv, gem_smoke_angle_deg * gem_smoke_pi / 180.0);
    smoke_uv *= mix(4.0, 1.0, gem_smoke_size);

    // Two swirl paths: inner (shape-masked) and outer (free), each with
    // independent distortion.
    float2 inner_uv = smoke_uv;
    float2 outer_uv = smoke_uv;

    // Vertical displacement, applied independently to inner and outer.
    inner_uv.y += gem_smoke_inner_distortion * (1.0 - smoothstep(0.0, 1.0, length(0.4 * inner_uv)));
    inner_uv.y -= 0.4 * gem_smoke_inner_distortion;
    inner_uv.y += 0.7 * gem_smoke_offset * roundness;

    outer_uv.y += gem_smoke_outer_distortion * (1.0 - smoothstep(0.0, 1.0, length(0.4 * outer_uv)));
    outer_uv.y -= 0.4 * gem_smoke_outer_distortion;

    float inner_swirl = gem_smoke_inner_distortion * roundness;
    float outer_swirl = gem_smoke_outer_distortion;

    for (int i = 1; i < 5; i++) {
        float fi = float(i);

        // GLSL's dFdx/dFdy == Metal's dfdx/dfdy (fragment-only derivatives).
        float stretch_in = max(length(dfdx(inner_uv)), length(dfdy(inner_uv)));
        float dampen_in = 1.0 / (1.0 + stretch_in * 8.0);
        float s_in = inner_swirl * dampen_in;
        inner_uv.x += s_in / fi * cos(time + fi * 2.9 * inner_uv.y);
        inner_uv.y += s_in / fi * cos(time + fi * 1.5 * inner_uv.x);

        float stretch_out = max(length(dfdx(outer_uv)), length(dfdy(outer_uv)));
        float dampen_out = 1.0 / (1.0 + stretch_out * 8.0);
        float s_out = outer_swirl * dampen_out;
        outer_uv.x += s_out / fi * cos(time + fi * 2.9 * outer_uv.y);
        outer_uv.y += s_out / fi * cos(time + fi * 1.5 * outer_uv.x);
    }

    // Smoke shapes from swirl fields.
    float inner_shape = exp(-1.5 * dot(inner_uv, inner_uv));
    float outer_shape = exp(-1.5 * dot(outer_uv, outer_uv));

    // Visibility masks.
    float outer_mask = pow(gem_smoke_outer_glow, 2.0) * (1.0 - img_alpha);
    float inner_mask = (0.01 + 0.99 * gem_smoke_inner_glow) * img_alpha;

    inner_shape *= inner_mask;
    outer_shape *= outer_mask;

    // --- Color roles, split from the flat uniform color list ---
    gem_smoke_color_roles roles = gem_smoke_split_colors(uniforms);

    // Color gradient.
    float mixer = (inner_shape + outer_shape) * float(roles.grad_count);
    float4 gradient = roles.grad_colors[0];
    gradient.rgb *= gradient.a;

    float smoke_mask = 0.0;
    for (int i = 1; i < 7; i++) { // gemSmokeMeta.maxColorCount == 6
        if (i > roles.grad_count) break;

        float m = smoothstep(0.0, 1.0, clamp(mixer - float(i - 1), 0.0, 1.0));
        if (i == 1) smoke_mask = m;

        float4 c = roles.grad_colors[i - 1];
        c.rgb *= c.a;
        gradient = mix(gradient, c, m);
    }

    // Compositing (premultiplied alpha, front-to-back).
    float3 color = gradient.rgb * smoke_mask;
    float opacity = gradient.a * smoke_mask;

    float inner_opacity = roles.color_inner.a * img_alpha;
    float3 inner_color = roles.color_inner.rgb * inner_opacity;
    color += inner_color * (1.0 - opacity);
    opacity += inner_opacity * (1.0 - opacity);

    float3 back_color = roles.color_back.rgb * roles.color_back.a;
    color += back_color * (1.0 - opacity);
    opacity += roles.color_back.a * (1.0 - opacity);
    // `opacity` is discarded below (kept above only for parity with the
    // source's premultiplied composite math): this is the very first thing
    // drawn, so there is nothing beneath it for translucency to reveal.
    (void)opacity;

    // Fully opaque: the background establishes the base color that the
    // terminal's own (semi-transparent) surfaces composite over.
    return float4(color, 1.0);
}

// ---- heatmap ----
// ---- heatmap ----
// Metal port of paper.design's "heatmap" shader
// (https://github.com/paper-design/shaders, Apache-2.0): a glowing wave of
// thermal color that pulses and travels through a shape, driven by an
// animated "shadow" blob (three phase-offset copies of the same hand-built
// blob/logo silhouette animation) whose coverage is colorized through an
// N-stop gradient (cold = colors[1], hot = colors[N-1]).
//
// IMPORTANT DEVIATION FROM THE SOURCE: the original GLSL reads `u_image`, a
// sampler2D that is pre-processed CPU-side (see `toProcessedHeatmap` in
// heatmap.ts) from an arbitrary user-supplied logo/graphic into three
// channels: R = fine "contour" blur, G = wide "outer" blur, B = narrow
// "inner" blur of that image's silhouette. This is not a randomizable noise
// texture (unlike u_noiseTexture elsewhere in paper.design's shaders) — it
// is the actual content being displayed — and Warp's BackgroundUniforms has
// no image asset or texture binding to stand in for it. There is no
// faithful way to reproduce that preprocessing here.
//
// Instead, this port treats the whole viewport as the "shape" (so the
// interior heat animation covers the full background) and synthesizes an
// analogous soft "frame" mask procedurally near the physical screen edges to
// stand in for the missing blur channels, so that both u_innerGlow (heat
// inside the shape) and u_outerGlow (glow bleeding past its edge, here a rim
// near the screen border) remain meaningful. The fine per-pixel "contour"
// channel (tied to actual image content) has no substitute and is baked to
// contribute 0. Everything else — the animated shadow-blob silhouette
// function and the heat-to-gradient colorization — is translated 1:1 from
// the GLSL, since none of it actually depends on the texture.
//
// All helpers are prefixed "heatmap_" and this file is fully self-contained
// (no shared bg_*/other-effect helpers are reused).

// --- helpers (ported 1:1 from heatmap.ts's shadowShape et al.) ---

static float heatmap_circle(float2 uv, float2 c, float2 r) {
    return 1.0 - smoothstep(r.x, r.y, length(uv - c));
}

static float heatmap_lst(float edge0, float edge1, float x) {
    return clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
}

static float heatmap_sst(float edge0, float edge1, float x) {
    return smoothstep(edge0, edge1, x);
}

// Soft rounded-rect mask: 1.0 in the interior, fading to 0.0 within `th` of
// each edge of the [0,1] `uv` domain. Ported from the GLSL's getImgFrame,
// but repurposed here (see file header) as a procedural stand-in for the
// missing image-derived blur channels, evaluated against true fractional
// screen coordinates rather than a padded source-image texture.
static float heatmap_frame_mask(float2 uv, float th) {
    float frame = 1.0;
    frame *= smoothstep(0.0, th, uv.y);
    frame *= 1.0 - smoothstep(1.0 - th, 1.0, uv.y);
    frame *= smoothstep(0.0, th, uv.x);
    frame *= 1.0 - smoothstep(1.0 - th, 1.0, uv.x);
    return frame;
}

// Hand-built animated blob silhouette (morphs through a bitten-apple-like
// shape at certain phases of `t`). Ported 1:1 from the GLSL's shadowShape;
// it does not touch any texture, so no adaptation was needed beyond syntax.
// `contour` only feeds a minor highlight term around the "top circle" and is
// fed 0 by the caller here (see file header) since there is no image detail
// to source it from.
static float heatmap_shadow_shape(float2 uv, float t, float contour) {
    const float two_pi = 6.28318530718;

    float2 scaled_uv = uv;

    // Base shape trajectory.
    float pos_y = mix(-1.0, 2.0, t);

    // Scale X when it's moving down.
    scaled_uv.y -= 0.5;
    float main_circle_scale = heatmap_sst(0.0, 0.8, pos_y) * heatmap_lst(1.4, 0.9, pos_y);
    scaled_uv *= float2(1.0, 1.0 + 1.5 * main_circle_scale);
    scaled_uv.y += 0.5;

    // Base shape.
    float inner_r = 0.4;
    float outer_r = 1.0 - 0.3 * (heatmap_sst(0.1, 0.2, t) * (1.0 - heatmap_sst(0.2, 0.5, t)));
    float s = heatmap_circle(scaled_uv, float2(0.5, pos_y - 0.2), float2(inner_r, outer_r));
    s = pow(s, 1.4);
    s *= 1.2;

    // Flat gradient that takes over the shadow shape near its top.
    {
        float pos = pos_y - uv.y;
        float edge = 1.2;
        float top_flattener = heatmap_lst(-0.4, 0.0, pos) * (1.0 - heatmap_sst(0.0, edge, pos));
        top_flattener = pow(top_flattener, 3.0);
        float top_flattener_mixer = (1.0 - heatmap_sst(0.0, 0.3, pos));
        s = mix(top_flattener, s, top_flattener_mixer);
    }

    // "Apple" right circle.
    {
        float visibility = heatmap_sst(0.6, 0.7, t) * (1.0 - heatmap_sst(0.8, 0.9, t));
        float angle = -2.0 - t * two_pi;
        float right_circle = heatmap_circle(uv, float2(0.95 - 0.2 * cos(angle), 0.4 - 0.1 * sin(angle)), float2(0.15, 0.3));
        right_circle *= visibility;
        s = mix(s, 0.0, right_circle);
    }

    // "Apple" top circle.
    {
        float top_circle = heatmap_circle(uv, float2(0.5, 0.19), float2(0.05, 0.25));
        top_circle += 2.0 * contour * heatmap_circle(uv, float2(0.5, 0.19), float2(0.2, 0.5));
        float visibility = 0.55 * heatmap_sst(0.2, 0.3, t) * (1.0 - heatmap_sst(0.3, 0.45, t));
        top_circle *= visibility;
        s = mix(s, 0.0, top_circle);
    }

    float leaf_mask = heatmap_circle(uv, float2(0.53, 0.13), float2(0.08, 0.19));
    leaf_mask = mix(leaf_mask, 0.0, 1.0 - heatmap_sst(0.4, 0.54, uv.x));
    leaf_mask = mix(0.0, leaf_mask, heatmap_sst(0.0, 0.2, uv.y));
    leaf_mask *= (heatmap_sst(0.5, 1.1, pos_y) * heatmap_sst(1.5, 1.3, pos_y));
    s += leaf_mask;

    // "Apple" bottom circle.
    {
        float visibility = heatmap_sst(0.0, 0.4, t) * (1.0 - heatmap_sst(0.6, 0.8, t));
        s = mix(s, 0.0, visibility * heatmap_circle(uv, float2(0.52, 0.92), float2(0.09, 0.25)));
    }

    // Random balls, invisible once the apple logo phase takes over.
    {
        float pos = heatmap_sst(0.0, 0.6, t) * (1.0 - heatmap_sst(0.6, 1.0, t));
        s = mix(s, 0.5, heatmap_circle(uv, float2(0.0, 1.2 - 0.5 * pos), float2(0.1, 0.3)));
        s = mix(s, 0.0, heatmap_circle(uv, float2(1.0, 0.5 + 0.5 * pos), float2(0.1, 0.3)));

        s = mix(s, 1.0, heatmap_circle(uv, float2(0.95, 0.2 + 0.2 * heatmap_sst(0.3, 0.4, t) * heatmap_sst(0.7, 0.5, t)), float2(0.07, 0.22)));
        s = mix(s, 1.0, heatmap_circle(uv, float2(0.95, 0.2 + 0.2 * heatmap_sst(0.3, 0.4, t) * (1.0 - heatmap_sst(0.5, 0.7, t))), float2(0.07, 0.22)));
        // GLSL's sst(1., .85, uv.y) has edge0 > edge1 (a descending
        // smoothstep); ported verbatim since both GLSL and MSL evaluate the
        // same polynomial formula regardless of edge ordering.
        s /= max(1e-4, heatmap_sst(1.0, 0.85, uv.y));
    }

    // GLSL's `clamp(0., 1., s)` passes its arguments in a non-standard
    // order for GLSL/MSL's clamp(x, minVal, maxVal): this literally computes
    // min(max(0.0, 1.0), s) == min(1.0, s), i.e. an upper-only clamp. Ported
    // verbatim (s never goes negative through the mixes above, so the
    // missing lower bound has no practical effect).
    s = clamp(0.0, 1.0, s);
    return s;
}

fragment float4 background_heatmap_fragment_shader(BackgroundFragmentData in [[stage_in]], constant BackgroundUniforms *uniforms [[buffer(0)]])
{
    // Baked tunables, taken from paper.design's Heatmap "Default" preset
    // (packages/shaders-react/src/shaders/heatmap.tsx): contour=0.5,
    // angle=0, noise=0, innerGlow=0.5, outerGlow=0.5. (scale/speed/frame are
    // vertex-side sizing/motion params, out of scope; speed is already
    // baked into uniforms->time CPU-side.)
    const float u_contour = 0.5;
    const float u_angle = 0.0;
    const float u_noise = 0.0;
    const float u_inner_glow = 0.5;
    const float u_outer_glow = 0.5;

    // Synthetic stand-in for the missing image-derived shape/blur channels
    // (see file header). `frac_uv` is true fractional screen position
    // (independent of aspect-ratio stretching), used both as the "shape"
    // boundary domain and as the coordinate space fed into the ported
    // shadowShape animation (which assumes a roughly square [0,1] domain).
    float2 frac_uv = in.position.xy / max(uniforms->viewport_size, float2(1.0));

    const float shape_th = 0.08;  // width of the soft "outside" rim near the screen edge
    const float big_blur_th = 0.30;  // width of the broader halo standing in for the image's wide blur channel

    float shape = 1.0 - heatmap_frame_mask(frac_uv, shape_th); // ~0 deep interior, ~1 right at the edges
    float big_blur = heatmap_frame_mask(frac_uv, big_blur_th); // ~1 deep interior, ~0 near the edges

    float outer_blur = 1.0 - mix(1.0, big_blur, shape);
    float inner_blur = mix(big_blur, 0.0, shape);
    const float contour_channel = 0.0; // no per-pixel image detail available; see file header

    float2 img_uv = frac_uv;

    float t = 0.1 * uniforms->time;
    t -= 0.3;

    float t_copy = t + 1.0 / 3.0;
    float t_copy2 = t + 2.0 / 3.0;

    // GLSL's `mod(x, 1.)` == x - floor(x) (always non-negative), matching
    // GLSL's sign convention regardless of x's sign.
    t = t - floor(t);
    t_copy = t_copy - floor(t_copy);
    t_copy2 = t_copy2 - floor(t_copy2);

    float2 animation_uv = img_uv - float2(0.5);
    float angle = -u_angle * (3.14159265358979323846 / 180.0);
    float cos_a = cos(angle);
    float sin_a = sin(angle);
    animation_uv = float2(
        animation_uv.x * cos_a - animation_uv.y * sin_a,
        animation_uv.x * sin_a + animation_uv.y * cos_a
    ) + float2(0.5);

    float shadow = heatmap_shadow_shape(animation_uv, t, inner_blur);
    float shadow_copy = heatmap_shadow_shape(animation_uv, t_copy, inner_blur);
    float shadow_copy2 = heatmap_shadow_shape(animation_uv, t_copy2, inner_blur);

    float inner = 0.8 + 0.8 * inner_blur;
    inner = mix(inner, 0.0, shadow);
    inner = mix(inner, 0.0, shadow_copy);
    inner = mix(inner, 0.0, shadow_copy2);

    inner *= mix(0.0, 2.0, u_inner_glow);
    inner += (u_contour * 2.0) * contour_channel;
    inner = min(1.0, inner);
    inner *= (1.0 - shape);

    float outer = 0.0;
    {
        t *= 3.0;
        t = t - 0.1;
        t = t - floor(t);

        outer = 0.9 * pow(outer_blur, 0.8);
        float y = animation_uv.y - t;
        y = y - floor(y);
        float animated_mask = heatmap_sst(0.3, 0.65, y) * (1.0 - heatmap_sst(0.65, 1.0, y));
        animated_mask = 0.5 + animated_mask;
        outer *= animated_mask;
        outer *= mix(0.0, 5.0, pow(u_outer_glow, 2.0));
    }

    inner = pow(inner, 1.2);
    float heat = clamp(inner + outer, 0.0, 1.0);

    heat += (0.005 + 0.35 * u_noise) * (fract(sin(dot(frac_uv, float2(12.9898, 78.233))) * 43758.5453123) - 0.5);

    // Color mapping: the original has a separate u_colorBack plus up to 10
    // u_colors[] gradient stops. BackgroundUniforms has a single colors[8]
    // array, so colors[0] plays the role of u_colorBack (the backdrop shown
    // where heat is low / outside the gradient's reach) and colors[1..7]
    // play the role of u_colors[0..6] (the up-to-7-stop thermal gradient
    // that heat is colorized through, cold to hot).
    float4 back_color = uniforms->colors[0];
    int heat_count = uniforms->colors_count - 1;
    if (heat_count < 1) {
        // Fewer than 2 colors configured: nothing to build a gradient from,
        // fall back to a flat backdrop (still a valid, opaque background).
        float3 flat_color = back_color.rgb * back_color.a;
        return float4(flat_color, 1.0);
    }

    float mixer = heat * float(heat_count);
    float4 gradient = uniforms->colors[1];
    gradient.rgb *= gradient.a;
    float outer_shape = 0.0;
    for (int i = 1; i < 8; i++) {
        if (i > heat_count) break;
        float m = clamp(mixer - float(i - 1), 0.0, 1.0);
        if (i == 1) {
            outer_shape = m;
        }
        float4 c = uniforms->colors[i];
        c.rgb *= c.a;
        gradient = mix(gradient, c, m);
    }

    float3 color = gradient.rgb * outer_shape;
    float opacity = gradient.a * outer_shape;

    float3 bg_color = back_color.rgb * back_color.a;
    color = color + bg_color * (1.0 - opacity);
    opacity = opacity + back_color.a * (1.0 - opacity);

    // Dither to avoid banding (ported from paper.design's colorBandingFix,
    // seeded with frac_uv rather than the original's y-flipped v_objectUV —
    // immaterial for a per-pixel hash-noise dither).
    color += 0.02 * (fract(sin(dot(frac_uv + 1.0, float2(12.9898, 78.233))) * 43758.5453123) - 0.5);

    // Fully opaque: the background establishes the base color that the
    // terminal's own (semi-transparent) surfaces composite over.
    return float4(color, 1.0);
}
