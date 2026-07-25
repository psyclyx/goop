//! Names expected by Snail's caller-owned Vulkan reference implementation.
//! The bytes come from the public generated `snail-shaders` module.

const shaders = @import("snail_shaders");

pub const vert_text_native_spv = shaders.textSpv(.vertex);
pub const frag_text_native_spv = shaders.textSpv(.fragment);
pub const frag_colr_native_spv = shaders.colrFragSpv();
pub const frag_path_quadratic_native_spv = shaders.pathQuadraticFragSpv();
pub const frag_path_conic_native_spv = shaders.pathConicFragSpv();
pub const frag_path_native_spv = shaders.pathFragSpv();
pub const frag_tt_hinted_native_spv = shaders.ttHintedFragSpv();
pub const vert_autohint_native_spv = shaders.autohintSpv(.vertex);
pub const frag_autohint_native_spv = shaders.autohintSpv(.fragment);
pub const frag_subpixel_native_spv = shaders.subpixelFragSpv();
pub const frag_tt_hinted_subpixel_native_spv = shaders.ttHintedSubpixelFragSpv();
pub const frag_autohint_subpixel_native_spv = shaders.autohintSubpixelFragSpv();
