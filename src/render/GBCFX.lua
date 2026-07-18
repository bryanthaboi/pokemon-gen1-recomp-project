-- GBC Effects post-process ("Pixel Transparency" style, see
-- github.com/mattakins/Pixel_Transparency).  A cumulative 4-level ladder
-- applied after palette colorization and before the CRT pass:
--   1  reflective screen: bright pixels blend toward a procedurally
--      grained warm backing (the unlit-GBC "transparent whites" look)
--   2  + LCD subpixel grid
--   3  + drop shadows (dark pixels float above the backing)
--   4  + sunlight: specular glare + rainbow QWP shimmer with a slowly
--      drifting light source
-- Levels OFF/1/2/3/4 persist as save.options.gbcfx; hotkey 5 cycles.
-- Spec: docs/new-features.md (Custom Options / GBC FX)
--
-- One shader for all levels: features are gated by the `level` uniform
-- (float comparisons), so cycling never recompiles.  All spatial effects
-- key off `pixelScale` (screen pixels per GB pixel) so grid pitch,
-- shadow offsets and grain stay window-size independent.

local GBCFX = {}

GBCFX.LABELS = { "OFF", "1", "2", "3", "4" }
GBCFX.level = 0

local shader -- false = unavailable (headless / no shader support)

-- GLSL 1.20-compatible (no array initializers; wavelength terms and the
-- shadow blur are unrolled by hand).
local SHADER_SRC = [[
extern number level;
extern number time;
extern number pixelScale; // screen pixels per GB pixel (integer fit scale)

#define PI 3.14159265359

// ---- level thresholds (cumulative ladder) ----
#define L_GRID    1.5
#define L_SHADOW  2.5
#define L_SUN     3.5

// ---- level 1: reflective backing ----
#define BACK_BRIGHTNESS 0.48
#define GRAIN_INTENSITY 0.065
// #A6AC84 "Pocket" backing tint, normalized to unit mean brightness
#define POCKET_TINT vec3(1.0596, 1.0979, 0.8424)
#define BASE_ALPHA  0.20
#define WHITE_EXTRA 0.75
// front polarizer film tint
#define POLARIZER vec3(0.94, 1.0, 0.865)

// ---- level 2: LCD grid (lcd1x style) ----
#define BRIGHTEN_SCANLINES 16.0
#define BRIGHTEN_LCD 4.0

// ---- level 3: drop shadow ----
#define SHADOW_OFFSET 3.0
#define SHADOW_OPACITY 0.5

// ---- level 4: sunlight ----
#define GLARE_INTENSITY 0.15
#define GLARE_SIGMA 0.25
#define SHIMMER_INTENSITY 0.25
// chroma amplification so the bands read on the already-desaturated,
// backing-blended image (reference applies 0.25 to raw film reflectance)
#define SHIMMER_CHROMA_GAIN 3.0
#define SHIMMER_SPREAD 1.8
#define LIGHT_RANGE 0.6
#define FILM_NOISE_AMOUNT 0.5
#define REFLECT_FLOOR 0.03

float hash21(vec2 p)
{
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// smooth value noise, ~[0,1]
float vnoise(vec2 p)
{
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float luma(vec3 c)
{
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 pc)
{
    vec4 src = Texel(tex, tc);
    if (level < 0.5) {
        return src * color;
    }

    float ps = max(pixelScale, 1.0);
    vec2 gbPix = pc / ps;                       // GB-pixel coordinates
    vec2 texel = 1.0 / love_ScreenSize.xy;      // one screen pixel in tc
    vec2 gbTexel = texel * ps;                  // one GB pixel in tc

    // Drifting light position (normalized screen coords, upper area).
    // Computed unconditionally: level 3 borrows it for shadow drift.
    vec2 lightPos = vec2(0.5 + 0.35 * sin(time * 0.13),
                         0.3 + 0.2 * sin(time * 0.07));

    // ---- level 1: procedural backing material ----
    // flat gray + 3-octave paper grain, tinted warm
    float grain = vnoise(gbPix * 0.9)  * 0.5
                + vnoise(gbPix * 2.1 + vec2(17.0, 5.0)) * 0.3
                + vnoise(gbPix * 4.3 + vec2(3.0, 29.0)) * 0.2;
    float backLum = BACK_BRIGHTNESS + (grain - 0.5) * (GRAIN_INTENSITY * 2.0);
    vec3 back = backLum * POCKET_TINT;

    // ---- level 3: dark pixels cast a soft shadow onto the backing ----
    if (level >= L_SHADOW) {
        vec2 shOff = vec2(SHADOW_OFFSET);
        if (level >= L_SUN) {
            // subtle drift opposite the light's wander
            shOff += vec2((0.5 - lightPos.x) * 3.0, (0.3 - lightPos.y) * 3.0);
        }
        vec2 so = tc - shOff * gbTexel;
        vec2 e = gbTexel;
        // 9-tap gaussian blur of the offset sample's brightness (unrolled)
        float s = 0.0;
        s += luma(Texel(tex, so).rgb) * 4.0;
        s += luma(Texel(tex, so + vec2( e.x, 0.0)).rgb) * 2.0;
        s += luma(Texel(tex, so + vec2(-e.x, 0.0)).rgb) * 2.0;
        s += luma(Texel(tex, so + vec2(0.0,  e.y)).rgb) * 2.0;
        s += luma(Texel(tex, so + vec2(0.0, -e.y)).rgb) * 2.0;
        s += luma(Texel(tex, so + vec2( e.x,  e.y)).rgb) * 1.0;
        s += luma(Texel(tex, so + vec2( e.x, -e.y)).rgb) * 1.0;
        s += luma(Texel(tex, so + vec2(-e.x,  e.y)).rgb) * 1.0;
        s += luma(Texel(tex, so + vec2(-e.x, -e.y)).rgb) * 1.0;
        s /= 16.0;
        float dark = 1.0 - s;
        // deadzone: near-white pixels (dark ~ 0) cast no shadow at all
        float shadow = dark * smoothstep(0.08, 0.30, dark) * SHADOW_OPACITY;
        back = mix(back, back * 0.2, shadow);
    }

    // ---- level 2: LCD subpixel grid on the lit image only ----
    vec3 lit = src.rgb;
    if (level >= L_GRID) {
        vec2 angle = 2.0 * PI * (gbPix - 0.25);
        float yfac = (BRIGHTEN_SCANLINES + sin(angle.y))
                   / (BRIGHTEN_SCANLINES + 1.0);
        float xfac = (BRIGHTEN_LCD + sin(angle.x)) / (BRIGHTEN_LCD + 1.0);
        lit *= yfac * xfac;
    }

    // ---- level 1: brightness-proportional pixel transparency ----
    float lum = luma(src.rgb);
    float a = BASE_ALPHA * lum;
    // near-white pixels (luma > 0.90 AND min channel > 0.81) are nearly
    // fully transparent -- narrow smoothsteps stand in for the hard AND
    float mn = min(src.r, min(src.g, src.b));
    a += WHITE_EXTRA * smoothstep(0.88, 0.92, lum) * smoothstep(0.79, 0.83, mn);
    vec3 col = mix(lit, back, clamp(a, 0.0, 1.0));

    // ---- level 4: sunlight (glare + rainbow QWP shimmer) ----
    float glare = 0.0;
    if (level >= L_SUN) {
        float aspect = love_ScreenSize.x / love_ScreenSize.y;
        vec2 p = vec2(tc.x * aspect, tc.y);
        vec2 lp = vec2(lightPos.x * aspect, lightPos.y);
        float d = distance(p, lp);

        // specular gaussian hotspot (added after the polarizer tint:
        // it reflects off the front glass, not the LCD)
        glare = GLARE_INTENSITY * exp(-d * d / (2.0 * GLARE_SIGMA * GLARE_SIGMA));

        // quarter-wave-plate film: effective retardance (nm) grows with
        // distance from the light point -> concentric interference bands;
        // smooth "film thickness" noise makes the bands splotchy
        float film = vnoise(gbPix * 0.06 + vec2(7.3, 2.9) + time * 0.01);
        float gammaEff = (260.0 + 620.0 * SHIMMER_SPREAD * (d / LIGHT_RANGE))
                       * (1.0 + FILM_NOISE_AMOUNT * (film - 0.5));
        float ph = 4.0 * PI * gammaEff;

        // 7 wavelength samples 400..700nm with approximate spectral RGB,
        // unrolled (no const arrays in GLSL 1.20)
        vec3 rb = vec3(0.0);
        float cw;
        cw = cos(ph / 400.0); rb += cw * cw * vec3(0.15, 0.00, 0.50);
        cw = cos(ph / 450.0); rb += cw * cw * vec3(0.00, 0.10, 1.00);
        cw = cos(ph / 500.0); rb += cw * cw * vec3(0.00, 0.80, 0.40);
        cw = cos(ph / 550.0); rb += cw * cw * vec3(0.20, 1.00, 0.00);
        cw = cos(ph / 600.0); rb += cw * cw * vec3(1.00, 0.60, 0.00);
        cw = cos(ph / 650.0); rb += cw * cw * vec3(1.00, 0.10, 0.00);
        cw = cos(ph / 700.0); rb += cw * cw * vec3(0.70, 0.00, 0.00);
        rb /= vec3(3.05, 2.60, 1.90);   // per-channel weight sums -> peak 1.0

        // fade with distance from the light, kill on dark pixels,
        // weight by pixel color squared
        float att = 1.0 - smoothstep(0.0, LIGHT_RANGE, d);
        float refl = max(lum, REFLECT_FLOOR);
        // luminance-preserving tint: add only the chroma of the rainbow
        vec3 shimmer = (rb - vec3(luma(rb))) * SHIMMER_CHROMA_GAIN
                     * src.rgb * src.rgb * refl * att;
        col += shimmer * SHIMMER_INTENSITY;
    }

    // front polarizer tint, then front-surface glare on top
    col *= POLARIZER;
    col += vec3(glare);

    return vec4(col, src.a) * color;
}
]]

GBCFX.SHADER_SRC = SHADER_SRC -- exposed for the standalone compile check

function GBCFX.shader()
  if shader == nil then
    local ok, sh = pcall(love.graphics.newShader, SHADER_SRC)
    shader = ok and sh or false
  end
  return shader or nil
end

function GBCFX.setLevel(level)
  level = math.floor(tonumber(level) or 0)
  if level < 0 then level = 0 end
  if level > 4 then level = 4 end
  GBCFX.level = level
end

-- Advance OFF → 1 → 2 → 3 → 4 → OFF.  Returns the new level.
function GBCFX.cycle()
  GBCFX.setLevel((GBCFX.level + 1) % 5)
  return GBCFX.level
end

function GBCFX.applyOptions(opts)
  GBCFX.setLevel(opts and opts.gbcfx or 0)
end

function GBCFX.levelLabel(level)
  return GBCFX.LABELS[(level or GBCFX.level) + 1] or "OFF"
end

function GBCFX.active()
  return GBCFX.level > 0 and GBCFX.shader() ~= nil
end

-- Draw `canvas` fullscreen through the GBC FX shader into the current
-- render target (or plain if the shader is unavailable).  pixelScale is
-- the integer screen-pixels-per-GB-pixel scale so grid/shadow offsets
-- stay window-size independent.
function GBCFX.present(canvas, pixelScale)
  local sh = GBCFX.shader()
  if not sh or GBCFX.level <= 0 then
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(canvas, 0, 0)
    return
  end
  local t = 0
  if love.timer and love.timer.getTime then
    t = love.timer.getTime()
  end
  sh:send("level", GBCFX.level)
  sh:send("time", t)
  sh:send("pixelScale", math.max(1, math.floor(tonumber(pixelScale) or 1)))
  love.graphics.setShader(sh)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(canvas, 0, 0)
  love.graphics.setShader()
end

return GBCFX
