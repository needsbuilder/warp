mod gpu_info;
pub mod texture_cache;
pub use gpu_info::{GPUBackend, GPUDeviceInfo, GPUDeviceType, OnGPUDeviceSelected};
use serde::{Deserialize, Serialize};

use crate::platform::GraphicsBackend;

/// Circumstances under which glyphs should be rasterized with thin strokes.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema_gen", derive(schemars::JsonSchema))]
#[cfg_attr(
    feature = "schema_gen",
    schemars(
        description = "When to render text with thinner strokes for a lighter appearance.",
        rename_all = "snake_case"
    )
)]
#[cfg_attr(feature = "settings_value", derive(settings_value::SettingsValue))]
pub enum ThinStrokes {
    /// Never render glyphs using thin strokes.
    Never,
    /// Render glyphs using thin strokes when rendering on a low-DPI display.
    OnLowDpiDisplays,
    /// Render glyphs using thin strokes when rendering on a high-DPI display.
    #[default]
    OnHighDpiDisplays,
    /// Always render glyphs using thin strokes.
    Always,
}

impl ThinStrokes {
    /// The minimum scale factor for which we'll consider a display to be high-DPI.
    const HIGH_DPI_SCALE_FACTOR: f32 = 1.5;

    pub fn enabled_for_scale_factor(&self, scale_factor: f32) -> bool {
        match self {
            Self::Never => false,
            Self::OnLowDpiDisplays => scale_factor < Self::HIGH_DPI_SCALE_FACTOR,
            Self::OnHighDpiDisplays => scale_factor >= Self::HIGH_DPI_SCALE_FACTOR,
            Self::Always => true,
        }
    }
}

/// Options for configuring rendering of glyphs.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct GlyphConfig {
    /// Whether to render glyphs using thin strokes.
    pub use_thin_strokes: ThinStrokes,
}

/// Power preference for GPU for rendering.
///
/// Relevant for machines with multiple GPUs (typically a discrete high-performance GPU and an
/// integrated low-power-usage GPU).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum GPUPowerPreference {
    LowPower,
    #[default]
    HighPerformance,
}

/// The maximum number of colors an animated background shader accepts.
pub const BACKGROUND_SHADER_MAX_COLORS: usize = 8;

/// The animated background shader effects available to themes.
///
/// The effects are Metal ports of shaders from paper.design's shader library
/// (https://github.com/paper-design/shaders, Apache-2.0).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BackgroundShaderKind {
    /// A flowing composition of color spots warped by organic noise and a
    /// vortex swirl.
    MeshGradient,
    /// Colorful stripes twisted into a vortex around the center.
    Swirl,
    /// A checks/stripes pattern distorted by noise and swirl iterations.
    Warp,
    /// Neural-looking fractal noise lines.
    NeuroNoise,
    /// Classic animated perlin noise blobs.
    PerlinNoise,
    /// Overlapping translucent color panels rotating in pseudo-3D.
    ColorPanels,
    /// Gooey colored balls wandering around the center and merging.
    Metaballs,
    /// Animated chrome stripes with a color-burn tint.
    LiquidMetal,
    /// Volumetric light rays emanating from a point.
    GodRays,
    /// Caustic water-surface distortion.
    Water,
    /// Animated voronoi cell pattern.
    Voronoi,
    /// A ring of drifting smoke.
    SmokeRing,
    /// A hypnotic rotating spiral.
    Spiral,
    /// Grainy blended color gradient.
    GrainGradient,
    /// Wisps of colored smoke over a dark base.
    GemSmoke,
    /// A flowing heatmap color ramp.
    Heatmap,
}

/// Shorthand for a `ColorU` literal in the default palettes below.
const fn shader_color(r: u8, g: u8, b: u8) -> crate::color::ColorU {
    crate::color::ColorU { r, g, b, a: 255 }
}

// Default palettes for each background shader effect. They follow
// paper.design's demo defaults, except MeshGradient which matches the WarpOss
// icon gradient.
static MESH_GRADIENT_COLORS: [crate::color::ColorU; 4] = [
    shader_color(41, 71, 219),
    shader_color(112, 61, 219),
    shader_color(26, 133, 235),
    shader_color(158, 71, 204),
];
// colors[0] is the background fill, the rest are stripe colors.
static SWIRL_COLORS: [crate::color::ColorU; 4] = [
    shader_color(0x33, 0x00, 0x00),
    shader_color(0xff, 0xd1, 0xd1),
    shader_color(0xff, 0x8a, 0x8a),
    shader_color(0x66, 0x00, 0x00),
];
static WARP_COLORS: [crate::color::ColorU; 4] = [
    shader_color(0x12, 0x12, 0x12),
    shader_color(0x94, 0x70, 0xff),
    shader_color(0x12, 0x12, 0x12),
    shader_color(0x88, 0x38, 0xff),
];
static NEURO_NOISE_COLORS: [crate::color::ColorU; 3] = [
    shader_color(0xff, 0xff, 0xff),
    shader_color(0x47, 0xa6, 0xff),
    shader_color(0x00, 0x00, 0x00),
];
static PERLIN_NOISE_COLORS: [crate::color::ColorU; 2] = [
    shader_color(0xfc, 0xcf, 0xf7),
    shader_color(0x63, 0x2a, 0xd5),
];
static COLOR_PANELS_COLORS: [crate::color::ColorU; 5] = [
    shader_color(0xff, 0x9d, 0x00),
    shader_color(0xfd, 0x4f, 0x30),
    shader_color(0x6d, 0x2e, 0xff),
    shader_color(0xf1, 0x5c, 0xff),
    shader_color(0xff, 0xd5, 0x57),
];
static METABALLS_COLORS: [crate::color::ColorU; 6] = [
    shader_color(0x00, 0x00, 0x00),
    shader_color(0x6e, 0x33, 0xcc),
    shader_color(0xff, 0x55, 0x00),
    shader_color(0xff, 0xc1, 0x05),
    shader_color(0xff, 0xc8, 0x00),
    shader_color(0xf5, 0x85, 0xff),
];
static LIQUID_METAL_COLORS: [crate::color::ColorU; 2] = [
    shader_color(0x10, 0x10, 0x14),
    shader_color(0x5a, 0x8c, 0xa8),
];
static GOD_RAYS_COLORS: [crate::color::ColorU; 6] = [
    shader_color(0x00, 0x00, 0x00),
    shader_color(0x00, 0x00, 0xff),
    shader_color(0xa6, 0x00, 0xff),
    shader_color(0x62, 0x00, 0xff),
    shader_color(0xff, 0xff, 0xff),
    shader_color(0x33, 0xff, 0xf5),
];
static WATER_COLORS: [crate::color::ColorU; 2] = [
    shader_color(0x0b, 0x2a, 0x3d),
    shader_color(0x8f, 0xe3, 0xff),
];
static VORONOI_COLORS: [crate::color::ColorU; 4] = [
    shader_color(0x1a, 0x24, 0x40),
    shader_color(0x2c, 0x5f, 0x74),
    shader_color(0x5b, 0x3f, 0x78),
    shader_color(0x4f, 0x8f, 0x6b),
];
static SMOKE_RING_COLORS: [crate::color::ColorU; 4] = [
    shader_color(0x00, 0x00, 0x00),
    shader_color(0xff, 0xff, 0xff),
    shader_color(0xff, 0xca, 0x0a),
    shader_color(0xfc, 0x62, 0x03),
];
static SPIRAL_COLORS: [crate::color::ColorU; 2] = [
    shader_color(0x79, 0xd1, 0xff),
    shader_color(0x00, 0x14, 0x29),
];
static GRAIN_GRADIENT_COLORS: [crate::color::ColorU; 5] = [
    shader_color(0x00, 0x00, 0x00),
    shader_color(0x73, 0x00, 0xff),
    shader_color(0xeb, 0xa8, 0xff),
    shader_color(0x00, 0xbf, 0xff),
    shader_color(0x2a, 0x00, 0xff),
];
static GEM_SMOKE_COLORS: [crate::color::ColorU; 4] = [
    shader_color(0x22, 0xd3, 0xa5),
    shader_color(0xa8, 0x55, 0xf7),
    shader_color(0x15, 0x0f, 0x1e),
    shader_color(0x08, 0x06, 0x0c),
];
static HEATMAP_COLORS: [crate::color::ColorU; 8] = [
    shader_color(0x00, 0x00, 0x00),
    shader_color(0x11, 0x20, 0x6a),
    shader_color(0x1f, 0x3b, 0xa2),
    shader_color(0x2f, 0x63, 0xe7),
    shader_color(0x6b, 0xd7, 0xff),
    shader_color(0xff, 0xe6, 0x79),
    shader_color(0xff, 0x99, 0x1e),
    shader_color(0xff, 0x4c, 0x00),
];

impl BackgroundShaderKind {
    /// Resolves a theme-provided shader name (e.g. `mesh_gradient`) to a
    /// shader kind. Returns `None` for unknown names.
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "mesh_gradient" => Some(Self::MeshGradient),
            "swirl" => Some(Self::Swirl),
            "warp" => Some(Self::Warp),
            "neuro_noise" => Some(Self::NeuroNoise),
            "perlin_noise" => Some(Self::PerlinNoise),
            "color_panels" => Some(Self::ColorPanels),
            "metaballs" => Some(Self::Metaballs),
            "liquid_metal" => Some(Self::LiquidMetal),
            "god_rays" => Some(Self::GodRays),
            "water" => Some(Self::Water),
            "voronoi" => Some(Self::Voronoi),
            "smoke_ring" => Some(Self::SmokeRing),
            "spiral" => Some(Self::Spiral),
            "grain_gradient" => Some(Self::GrainGradient),
            "gem_smoke" => Some(Self::GemSmoke),
            "heatmap" => Some(Self::Heatmap),
            _ => None,
        }
    }

    /// The default color palette used when a theme enables this shader
    /// without specifying colors.
    pub fn default_colors(&self) -> &'static [crate::color::ColorU] {
        match self {
            Self::MeshGradient => &MESH_GRADIENT_COLORS,
            Self::Swirl => &SWIRL_COLORS,
            Self::Warp => &WARP_COLORS,
            Self::NeuroNoise => &NEURO_NOISE_COLORS,
            Self::PerlinNoise => &PERLIN_NOISE_COLORS,
            Self::ColorPanels => &COLOR_PANELS_COLORS,
            Self::Metaballs => &METABALLS_COLORS,
            Self::LiquidMetal => &LIQUID_METAL_COLORS,
            Self::GodRays => &GOD_RAYS_COLORS,
            Self::Water => &WATER_COLORS,
            Self::Voronoi => &VORONOI_COLORS,
            Self::SmokeRing => &SMOKE_RING_COLORS,
            Self::Spiral => &SPIRAL_COLORS,
            Self::GrainGradient => &GRAIN_GRADIENT_COLORS,
            Self::GemSmoke => &GEM_SMOKE_COLORS,
            Self::Heatmap => &HEATMAP_COLORS,
        }
    }
}

/// Configuration for the animated background shader drawn behind all scene
/// content, sourced from the active theme.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BackgroundShaderConfig {
    pub kind: BackgroundShaderKind,
    /// The shader's color palette; only the first `colors_count` entries are
    /// meaningful.
    pub colors: [crate::color::ColorU; BACKGROUND_SHADER_MAX_COLORS],
    pub colors_count: u8,
    /// Animation speed as a percentage; 100 = normal speed.
    pub speed_percent: u16,
}

/// Options for configuring rendering at the application level. These options
/// will apply for the entirety of a frame, but may change between frames.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Config {
    /// Configuration options relating to glyph rendering.
    pub glyphs: GlyphConfig,

    /// Power preference for GPU used for rendering; this is applicable on dual GPU machines where
    /// there's a choice between a discrete high-performance GPU and a more power-efficient
    /// integrated GPU.
    pub gpu_power_preference: GPUPowerPreference,

    pub backend_preference: Option<GraphicsBackend>,

    /// The animated background shader to draw behind all scene content, if
    /// the active theme enables one.
    pub background_shader: Option<BackgroundShaderConfig>,
}

#[derive(Clone, Debug, Default)]
pub struct CornerRadius {
    pub top_left: f32,
    pub top_right: f32,
    pub bottom_left: f32,
    pub bottom_right: f32,
}

impl CornerRadius {
    pub fn from_ui_corner_radius(
        corner_radius: crate::scene::CornerRadius,
        scale_factor: f32,
        min_dimension: f32,
    ) -> Self {
        let top_left = match corner_radius.get_top_left() {
            crate::scene::Radius::Pixels(px) => px * scale_factor,
            crate::scene::Radius::Percentage(percent) => percent / 100. * min_dimension,
        };
        let top_right = match corner_radius.get_top_right() {
            crate::scene::Radius::Pixels(px) => px * scale_factor,
            crate::scene::Radius::Percentage(percent) => percent / 100. * min_dimension,
        };
        let bottom_left = match corner_radius.get_bottom_left() {
            crate::scene::Radius::Pixels(px) => px * scale_factor,
            crate::scene::Radius::Percentage(percent) => percent / 100. * min_dimension,
        };
        let bottom_right = match corner_radius.get_bottom_right() {
            crate::scene::Radius::Pixels(px) => px * scale_factor,
            crate::scene::Radius::Percentage(percent) => percent / 100. * min_dimension,
        };
        Self {
            top_left,
            top_right,
            bottom_left,
            bottom_right,
        }
    }
}
