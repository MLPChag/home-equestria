// Runtime BC1/BC3 (S3TC) texture compression for exported builds. Godot's export templates
// carry no BC encoder, so textures built at runtime (wallpaper, artwork, timber, terrain layers)
// uploaded as raw RGBA8 at four times the VRAM of the editor's S3TC (docs/ALPHA_RELEASE_2026_09_29.md).
// A plain bounding-box range fit per 4x4 block: fast, deterministic, editor-like quality for
// these painted textures. Desktop only; Android GPUs do not sample BC formats.
#pragma once

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>

namespace godot {

class PonyTextureCodec : public RefCounted {
	GDCLASS(PonyTextureCodec, RefCounted)

protected:
	static void _bind_methods();

public:
	// RGBA8 image (any size, with or without mipmaps) -> DXT1 when fully opaque, else DXT5,
	// with the same mipmap chain. Null for anything that is not RGBA8 or is empty.
	static Ref<Image> compress(const Ref<Image> &p_image);
};

} // namespace godot
