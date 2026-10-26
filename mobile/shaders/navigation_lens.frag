#include <flutter/runtime_effect.glsl>

// The engine supplies the first vec2 and first sampler for ImageFilter.shader.
uniform vec2 u_size;
uniform float u_pixel_ratio;
uniform float u_high_performance;
uniform float u_position;
uniform float u_count;
uniform sampler2D u_input;

out vec4 frag_color;

vec4 sampleInput(vec2 point) {
  vec2 uv = clamp(point / u_size, 0.5 / u_size, 1.0 - 0.5 / u_size);
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return texture(u_input, uv);
}

void main() {
  vec2 point = FlutterFragCoord().xy;
  vec2 center = vec2(u_position * u_size.x, u_size.y * 0.5);
  vec2 half_size = max(vec2(u_size.x / u_count, u_size.y) * 0.5 -
      0.65 * u_pixel_ratio, vec2(0.01));
  float radius = min(half_size.x, half_size.y);
  vec2 centered = point - center;
  vec2 corner = abs(centered) - (half_size - vec2(radius));
  vec2 outside = max(corner, 0.0);
  float distance = length(outside) + min(max(corner.x, corner.y), 0.0) - radius;
  if (distance >= 0.0) {
    frag_color = sampleInput(point);
    return;
  }
  float depth = -distance;
  vec2 normal = sign(centered) * outside / max(length(outside), 0.001);
  float band = max(min(radius * 0.55, 8.0 * u_pixel_ratio), 0.01);
  float edge = 1.0 - smoothstep(0.0, band, depth);
  float bend = sin(edge * 3.14159265) *
      mix(2.2, 1.5, u_high_performance) * u_pixel_ratio;
  vec2 refracted = center + centered / 1.02 - normal * bend;
  vec4 clear = sampleInput(refracted);

  // Frost is confined to a narrow lower rim; the central glyphs stay sharp.
  float lower = smoothstep(0.0, radius * 0.65, centered.y);
  float frost = edge * lower * mix(0.28, 0.16, u_high_performance);
  if (frost > 0.001) {
    vec2 offset = vec2(0.65 * u_pixel_ratio, 0.0);
    vec4 soft = (sampleInput(refracted + offset) +
                 sampleInput(refracted - offset)) * 0.5;
    if (u_high_performance < 0.5) {
      soft = soft * 0.5 +
          (sampleInput(refracted + offset.yx) +
           sampleInput(refracted - offset.yx)) * 0.25;
    }
    clear = mix(clear, soft, frost);
  }
  frag_color = clear;
}
