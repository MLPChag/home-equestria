// BC1/BC3 encoder for runtime-built textures (texture_codec.h).
#include "texture_codec.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cstdint>
#include <cstring>

using namespace godot;

namespace {

uint16_t to_565(const int p_c[3]) {
	return uint16_t(((p_c[0] * 31 + 127) / 255) << 11 | ((p_c[1] * 63 + 127) / 255) << 5 | ((p_c[2] * 31 + 127) / 255));
}

void from_565(uint16_t p_v, int r_c[3]) {
	const int r = (p_v >> 11) & 31, g = (p_v >> 5) & 63, b = p_v & 31;
	r_c[0] = (r << 3) | (r >> 2);
	r_c[1] = (g << 2) | (g >> 4);
	r_c[2] = (b << 3) | (b >> 2);
}

// One 4x4 block of RGBA8 pixels -> 8 bytes of BC1 colour (always the four-colour mode).
void encode_color(const uint8_t p_px[16][4], uint8_t *r_out) {
	int lo[3] = { 255, 255, 255 }, hi[3] = { 0, 0, 0 };
	for (int i = 0; i < 16; i++) {
		for (int c = 0; c < 3; c++) {
			lo[c] = std::min(lo[c], int(p_px[i][c]));
			hi[c] = std::max(hi[c], int(p_px[i][c]));
		}
	}
	// Inset the box by 1/16 of its size so the endpoints sit on the colours, not past them.
	for (int c = 0; c < 3; c++) {
		const int inset = (hi[c] - lo[c]) / 16;
		lo[c] = std::min(255, lo[c] + inset);
		hi[c] = std::max(0, hi[c] - inset);
	}
	uint16_t c0 = to_565(hi), c1 = to_565(lo);
	if (c0 < c1) {
		std::swap(c0, c1);
	}
	uint32_t indices = 0;
	if (c0 != c1) {
		int palette[4][3];
		from_565(c0, palette[0]);
		from_565(c1, palette[1]);
		for (int c = 0; c < 3; c++) {
			palette[2][c] = (2 * palette[0][c] + palette[1][c]) / 3;
			palette[3][c] = (palette[0][c] + 2 * palette[1][c]) / 3;
		}
		for (int i = 0; i < 16; i++) {
			int best = 0, best_d = INT32_MAX;
			for (int k = 0; k < 4; k++) {
				int d = 0;
				for (int c = 0; c < 3; c++) {
					const int e = int(p_px[i][c]) - palette[k][c];
					d += e * e;
				}
				if (d < best_d) {
					best_d = d;
					best = k;
				}
			}
			indices |= uint32_t(best) << (2 * i);
		}
	}
	r_out[0] = uint8_t(c0 & 0xFF);
	r_out[1] = uint8_t(c0 >> 8);
	r_out[2] = uint8_t(c1 & 0xFF);
	r_out[3] = uint8_t(c1 >> 8);
	for (int k = 0; k < 4; k++) {
		r_out[4 + k] = uint8_t((indices >> (8 * k)) & 0xFF);
	}
}

// One 4x4 block of alpha -> 8 bytes of BC3 alpha (eight interpolated values).
void encode_alpha(const uint8_t p_px[16][4], uint8_t *r_out) {
	int lo = 255, hi = 0;
	for (int i = 0; i < 16; i++) {
		lo = std::min(lo, int(p_px[i][3]));
		hi = std::max(hi, int(p_px[i][3]));
	}
	r_out[0] = uint8_t(hi);
	r_out[1] = uint8_t(lo);
	uint64_t bits = 0;
	if (hi != lo) {
		int values[8];
		values[0] = hi;
		values[1] = lo;
		for (int k = 1; k < 7; k++) {
			values[k + 1] = ((7 - k) * hi + k * lo) / 7;
		}
		for (int i = 0; i < 16; i++) {
			int best = 0, best_d = INT32_MAX;
			for (int k = 0; k < 8; k++) {
				const int d = std::abs(int(p_px[i][3]) - values[k]);
				if (d < best_d) {
					best_d = d;
					best = k;
				}
			}
			bits |= uint64_t(best) << (3 * i);
		}
	}
	for (int k = 0; k < 6; k++) {
		r_out[2 + k] = uint8_t((bits >> (8 * k)) & 0xFF);
	}
}

} // namespace

void PonyTextureCodec::_bind_methods() {
	ClassDB::bind_static_method("PonyTextureCodec", D_METHOD("compress", "image"), &PonyTextureCodec::compress);
}

Ref<Image> PonyTextureCodec::compress(const Ref<Image> &p_image) {
	if (p_image.is_null() || p_image->is_empty() || p_image->get_format() != Image::FORMAT_RGBA8) {
		return Ref<Image>();
	}
	const int width = p_image->get_width();
	const int height = p_image->get_height();
	const bool mipmaps = p_image->has_mipmaps();
	const int levels = mipmaps ? p_image->get_mipmap_count() + 1 : 1;
	const PackedByteArray source = p_image->get_data();
	const uint8_t *src = source.ptr();

	bool opaque = true;
	for (int64_t i = 3; i < source.size() && opaque; i += 4) {
		opaque = src[i] == 255;
	}
	const int block_bytes = opaque ? 8 : 16;

	int64_t total = 0;
	for (int level = 0; level < levels; level++) {
		const int w = std::max(1, width >> level), h = std::max(1, height >> level);
		total += int64_t((w + 3) / 4) * ((h + 3) / 4) * block_bytes;
	}
	PackedByteArray out;
	out.resize(total);
	uint8_t *dst = out.ptrw();

	int64_t written = 0;
	for (int level = 0; level < levels; level++) {
		const int w = std::max(1, width >> level), h = std::max(1, height >> level);
		const int64_t offset = level == 0 ? 0 : p_image->get_mipmap_offset(level);
		const uint8_t *pixels = src + offset;
		for (int by = 0; by < h; by += 4) {
			for (int bx = 0; bx < w; bx += 4) {
				uint8_t block[16][4];
				for (int y = 0; y < 4; y++) {
					for (int x = 0; x < 4; x++) {
						// Edge blocks repeat the last row/column, as the GPU never samples them.
						const int sx = std::min(bx + x, w - 1), sy = std::min(by + y, h - 1);
						std::memcpy(block[y * 4 + x], pixels + (int64_t(sy) * w + sx) * 4, 4);
					}
				}
				if (!opaque) {
					encode_alpha(block, dst + written);
					written += 8;
				}
				encode_color(block, dst + written);
				written += 8;
			}
		}
	}
	return Image::create_from_data(width, height, mipmaps, opaque ? Image::FORMAT_DXT1 : Image::FORMAT_DXT5, out);
}
