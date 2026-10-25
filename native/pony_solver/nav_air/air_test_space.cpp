// See air_test_space.h.
#include "air_test_space.h"

#include <algorithm>
#include <cmath>

namespace nav_air {

namespace {

constexpr int64_t FINE_PER_TILE = 64;
constexpr int64_t FINE_PER_COARSE = 8;

int64_t floor_div(int64_t a, int64_t b) {
	int64_t q = a / b;
	if ((a % b != 0) && ((a < 0) != (b < 0))) {
		--q;
	}
	return q;
}

float axis_of(const Vec3 &v, int axis) {
	return axis == 0 ? v.x : (axis == 1 ? v.y : v.z);
}

// Indices i of cells [i*S, (i+1)*S) touched by [lo, hi]: positive overlap, or closed containment
// when the interval is a single value (so a zero-thickness plane marks both sides).
void cell_range(float lo, float hi, float size, int64_t &first, int64_t &last) {
	const double a = double(lo) / double(size);
	const double b = double(hi) / double(size);
	if (hi > lo) {
		first = int64_t(std::floor(a));
		last = int64_t(std::ceil(b)) - 1;
	} else {
		first = int64_t(std::ceil(a)) - 1;
		last = int64_t(std::floor(a));
	}
}

bool same_cell(const CellId &a, const CellId &b) {
	return a.tx == b.tx && a.ty == b.ty && a.tz == b.tz && a.level == b.level && a.coarse == b.coarse &&
			(a.level == 0 || a.fine == b.fine);
}

} // namespace

size_t TestAirSpace::KeyHash::operator()(const Key &k) const {
	uint64_t h = uint64_t(uint32_t(k.x)) * 0x9E3779B97F4A7C15ull;
	h ^= uint64_t(uint32_t(k.y)) * 0xC2B2AE3D27D4EB4Full + (h << 6) + (h >> 2);
	h ^= uint64_t(uint32_t(k.z)) * 0x165667B19E3779F9ull + (h << 6) + (h >> 2);
	return size_t(h ^ (h >> 29));
}

void TestAirSpace::add_tile(int32_t tx, int32_t ty, int32_t tz, Cell fill) {
	Tile &t = tiles_[Key{tx, ty, tz}];
	t.coarse.fill(uint8_t(fill));
	t.brick.fill(-1);
	t.bricks.clear();
	t.revision = next_revision_++;
}

void TestAirSpace::add_tiles(const Aabb &box, Cell fill) {
	int64_t lo[3], hi[3];
	for (int axis = 0; axis < 3; ++axis) {
		cell_range(axis_of(box.min, axis), axis_of(box.max, axis), AIR_TILE_SIZE, lo[axis], hi[axis]);
	}
	for (int64_t z = lo[2]; z <= hi[2]; ++z) {
		for (int64_t y = lo[1]; y <= hi[1]; ++y) {
			for (int64_t x = lo[0]; x <= hi[0]; ++x) {
				if (tiles_.find(Key{int32_t(x), int32_t(y), int32_t(z)}) == tiles_.end()) {
					add_tile(int32_t(x), int32_t(y), int32_t(z), fill);
				}
			}
		}
	}
}

bool TestAirSpace::remove_tile(int32_t tx, int32_t ty, int32_t tz) {
	return tiles_.erase(Key{tx, ty, tz}) > 0;
}

void TestAirSpace::touch_tile(int32_t tx, int32_t ty, int32_t tz) {
	auto it = tiles_.find(Key{tx, ty, tz});
	if (it != tiles_.end()) {
		it->second.revision = next_revision_++;
	}
}

size_t TestAirSpace::brick_count() const {
	size_t count = 0;
	for (const auto &entry : tiles_) {
		for (int32_t b : entry.second.brick) {
			count += b >= 0 ? 1 : 0;
		}
	}
	return count;
}

int TestAirSpace::ensure_brick(Tile &t, int coarse) {
	if (t.brick[size_t(coarse)] < 0) {
		std::array<uint8_t, 512> cells;
		cells.fill(t.coarse[size_t(coarse)]);
		t.brick[size_t(coarse)] = int32_t(t.bricks.size());
		t.bricks.push_back(cells);
	}
	return t.brick[size_t(coarse)];
}

int TestAirSpace::fill_box(const Aabb &box, Cell state) {
	int64_t tlo[3], thi[3], clo[3], chi[3], flo[3], fhi[3];
	for (int axis = 0; axis < 3; ++axis) {
		const float a = axis_of(box.min, axis), b = axis_of(box.max, axis);
		cell_range(a, b, AIR_TILE_SIZE, tlo[axis], thi[axis]);
		cell_range(a, b, AIR_COARSE_SIZE, clo[axis], chi[axis]);
		cell_range(a, b, AIR_FINE_SIZE, flo[axis], fhi[axis]);
	}
	int changed = 0;
	for (int64_t tz = tlo[2]; tz <= thi[2]; ++tz) {
		for (int64_t ty = tlo[1]; ty <= thi[1]; ++ty) {
			for (int64_t tx = tlo[0]; tx <= thi[0]; ++tx) {
				auto it = tiles_.find(Key{int32_t(tx), int32_t(ty), int32_t(tz)});
				if (it == tiles_.end()) {
					continue;
				}
				Tile &t = it->second;
				const int64_t tile_lo[3] = {tx * 8, ty * 8, tz * 8};
				int64_t a[3], b[3];
				for (int axis = 0; axis < 3; ++axis) {
					a[axis] = std::max(clo[axis], tile_lo[axis]);
					b[axis] = std::min(chi[axis], tile_lo[axis] + 7);
				}
				bool any = false;
				for (int64_t cz = a[2]; cz <= b[2]; ++cz) {
					for (int64_t cy = a[1]; cy <= b[1]; ++cy) {
						for (int64_t cx = a[0]; cx <= b[0]; ++cx) {
							const int64_t c[3] = {cx, cy, cz};
							bool inside = true;
							for (int axis = 0; axis < 3; ++axis) {
								const float lo = float(c[axis]) * AIR_COARSE_SIZE;
								inside = inside && axis_of(box.min, axis) <= lo &&
										axis_of(box.max, axis) >= lo + AIR_COARSE_SIZE;
							}
							const int coarse = int((cx - tile_lo[0]) + 8 * ((cy - tile_lo[1]) + 8 * (cz - tile_lo[2])));
							any = true;
							if (inside) {
								t.coarse[size_t(coarse)] = uint8_t(state);
								t.brick[size_t(coarse)] = -1;
								continue;
							}
							const int brick = ensure_brick(t, coarse);
							int64_t fa[3], fb[3];
							for (int axis = 0; axis < 3; ++axis) {
								fa[axis] = std::max(flo[axis], c[axis] * FINE_PER_COARSE);
								fb[axis] = std::min(fhi[axis], c[axis] * FINE_PER_COARSE + 7);
							}
							for (int64_t fz = fa[2]; fz <= fb[2]; ++fz) {
								for (int64_t fy = fa[1]; fy <= fb[1]; ++fy) {
									for (int64_t fx = fa[0]; fx <= fb[0]; ++fx) {
										const int fine = int((fx - cx * 8) + 8 * ((fy - cy * 8) + 8 * (fz - cz * 8)));
										t.bricks[size_t(brick)][size_t(fine)] = uint8_t(state);
									}
								}
							}
						}
					}
				}
				if (any) {
					t.revision = next_revision_++;
					++changed;
				}
			}
		}
	}
	return changed;
}

int TestAirSpace::refine_box(const Aabb &box) {
	int64_t clo[3], chi[3];
	for (int axis = 0; axis < 3; ++axis) {
		cell_range(axis_of(box.min, axis), axis_of(box.max, axis), AIR_COARSE_SIZE, clo[axis], chi[axis]);
	}
	int refined = 0;
	for (int64_t cz = clo[2]; cz <= chi[2]; ++cz) {
		for (int64_t cy = clo[1]; cy <= chi[1]; ++cy) {
			for (int64_t cx = clo[0]; cx <= chi[0]; ++cx) {
				const int64_t tx = floor_div(cx, 8), ty = floor_div(cy, 8), tz = floor_div(cz, 8);
				auto it = tiles_.find(Key{int32_t(tx), int32_t(ty), int32_t(tz)});
				if (it == tiles_.end()) {
					continue;
				}
				const int coarse = int((cx - tx * 8) + 8 * ((cy - ty * 8) + 8 * (cz - tz * 8)));
				if (it->second.brick[size_t(coarse)] < 0) {
					ensure_brick(it->second, coarse);
					it->second.revision = next_revision_++;
					++refined;
				}
			}
		}
	}
	return refined;
}

const TestAirSpace::Tile *TestAirSpace::tile(int32_t tx, int32_t ty, int32_t tz) const {
	auto it = tiles_.find(Key{tx, ty, tz});
	return it == tiles_.end() ? nullptr : &it->second;
}

bool TestAirSpace::leaf_at(int64_t gx, int64_t gy, int64_t gz, CellId &out, Cell &cell) const {
	const int64_t tx = floor_div(gx, FINE_PER_TILE), ty = floor_div(gy, FINE_PER_TILE), tz = floor_div(gz, FINE_PER_TILE);
	out.tx = int32_t(tx);
	out.ty = int32_t(ty);
	out.tz = int32_t(tz);
	out.coarse = 0;
	out.fine = 0;
	out.level = 0;
	const Tile *t = tile(out.tx, out.ty, out.tz);
	if (t == nullptr) {
		cell = Cell::UNKNOWN;
		return false;
	}
	const int64_t lx = gx - tx * FINE_PER_TILE, ly = gy - ty * FINE_PER_TILE, lz = gz - tz * FINE_PER_TILE;
	const int coarse = int(lx / 8 + 8 * (ly / 8 + 8 * (lz / 8)));
	out.coarse = uint16_t(coarse);
	const int32_t brick = t->brick[size_t(coarse)];
	if (brick < 0) {
		cell = Cell(t->coarse[size_t(coarse)]);
		return true;
	}
	const int fine = int(lx % 8 + 8 * (ly % 8 + 8 * (lz % 8)));
	out.fine = uint16_t(fine);
	out.level = 1;
	cell = Cell(t->bricks[size_t(brick)][size_t(fine)]);
	return true;
}

bool TestAirSpace::locate(const Vec3 &p, CellId &out) const {
	if (!std::isfinite(p.x) || !std::isfinite(p.y) || !std::isfinite(p.z)) {
		return false;
	}
	Cell cell;
	return leaf_at(int64_t(std::floor(double(p.x) / AIR_FINE_SIZE)), int64_t(std::floor(double(p.y) / AIR_FINE_SIZE)),
			int64_t(std::floor(double(p.z) / AIR_FINE_SIZE)), out, cell);
}

Cell TestAirSpace::state(const CellId &c) const {
	const Tile *t = tile(c.tx, c.ty, c.tz);
	if (t == nullptr || c.coarse >= 512) {
		return Cell::UNKNOWN;
	}
	const int32_t brick = t->brick[c.coarse];
	if (c.level == 0) {
		if (brick < 0) {
			return Cell(t->coarse[c.coarse]);
		}
		// A stale coarse id over a brick: answer conservatively for the whole volume.
		bool unknown = false;
		for (uint8_t s : t->bricks[size_t(brick)]) {
			if (Cell(s) == Cell::SOLID) {
				return Cell::SOLID;
			}
			unknown = unknown || Cell(s) == Cell::UNKNOWN;
		}
		return unknown ? Cell::UNKNOWN : Cell::FREE;
	}
	if (brick < 0 || c.fine >= 512) {
		return Cell::UNKNOWN; // stale fine id: the brick no longer exists
	}
	return Cell(t->bricks[size_t(brick)][c.fine]);
}

Aabb TestAirSpace::bounds(const CellId &c) const {
	const int cx = c.coarse % 8, cy = (c.coarse / 8) % 8, cz = c.coarse / 64;
	float x = float(c.tx) * AIR_TILE_SIZE + float(cx) * AIR_COARSE_SIZE;
	float y = float(c.ty) * AIR_TILE_SIZE + float(cy) * AIR_COARSE_SIZE;
	float z = float(c.tz) * AIR_TILE_SIZE + float(cz) * AIR_COARSE_SIZE;
	float size = AIR_COARSE_SIZE;
	if (c.level == 1) {
		x += float(c.fine % 8) * AIR_FINE_SIZE;
		y += float((c.fine / 8) % 8) * AIR_FINE_SIZE;
		z += float(c.fine / 64) * AIR_FINE_SIZE;
		size = AIR_FINE_SIZE;
	}
	return Aabb{Vec3{x, y, z}, Vec3{x + size, y + size, z + size}};
}

void TestAirSpace::neighbours(const CellId &c, std::vector<Face> &out) const {
	out.clear();
	if (tile(c.tx, c.ty, c.tz) == nullptr) {
		return;
	}
	int64_t lo[3] = {int64_t(c.tx) * FINE_PER_TILE + (c.coarse % 8) * FINE_PER_COARSE,
		int64_t(c.ty) * FINE_PER_TILE + ((c.coarse / 8) % 8) * FINE_PER_COARSE,
		int64_t(c.tz) * FINE_PER_TILE + (c.coarse / 64) * FINE_PER_COARSE};
	int64_t n = FINE_PER_COARSE;
	if (c.level == 1) {
		lo[0] += c.fine % 8;
		lo[1] += (c.fine / 8) % 8;
		lo[2] += c.fine / 64;
		n = 1;
	}
	const Aabb self = bounds(c);
	const float self_lo[3] = {self.min.x, self.min.y, self.min.z};
	const float self_hi[3] = {self.max.x, self.max.y, self.max.z};
	CellId seen[64];
	for (int axis = 0; axis < 3; ++axis) {
		const int u = (axis + 1) % 3, v = (axis + 2) % 3;
		for (int side = 0; side < 2; ++side) {
			int seen_count = 0;
			int64_t span = n;
			if (n > 1) {
				// A coarse face meets one uniform coarse entry or a brick: probe once first.
				int64_t g[3];
				g[axis] = side ? lo[axis] + n : lo[axis] - 1;
				g[u] = lo[u];
				g[v] = lo[v];
				CellId leaf;
				Cell cell;
				if (!leaf_at(g[0], g[1], g[2], leaf, cell)) {
					continue;
				}
				if (leaf.level == 0) {
					span = 1; // the whole face, emitted by the loop below with its full overlap
				}
			}
			for (int64_t i = 0; i < span; ++i) {
				for (int64_t j = 0; j < span; ++j) {
					int64_t g[3];
					g[axis] = side ? lo[axis] + n : lo[axis] - 1;
					g[u] = lo[u] + i;
					g[v] = lo[v] + j;
					CellId leaf;
					Cell cell;
					if (!leaf_at(g[0], g[1], g[2], leaf, cell) || cell != Cell::FREE) {
						continue;
					}
					bool repeated = false;
					for (int k = 0; k < seen_count && !repeated; ++k) {
						repeated = same_cell(seen[k], leaf);
					}
					if (repeated) {
						continue;
					}
					if (seen_count < 64) {
						seen[seen_count++] = leaf;
					}
					const Aabb other = bounds(leaf);
					const float other_lo[3] = {other.min.x, other.min.y, other.min.z};
					const float other_hi[3] = {other.max.x, other.max.y, other.max.z};
					float a[3], b[3];
					a[axis] = b[axis] = side ? self_hi[axis] : self_lo[axis];
					a[u] = std::max(self_lo[u], other_lo[u]);
					b[u] = std::min(self_hi[u], other_hi[u]);
					a[v] = std::max(self_lo[v], other_lo[v]);
					b[v] = std::min(self_hi[v], other_hi[v]);
					out.push_back(Face{leaf, Aabb{Vec3{a[0], a[1], a[2]}, Vec3{b[0], b[1], b[2]}}});
				}
			}
		}
	}
}

Cell TestAirSpace::sample(const Vec3 &p) const {
	CellId c;
	if (!locate(p, c)) {
		return Cell::UNKNOWN;
	}
	return state(c);
}

uint64_t TestAirSpace::tile_revision(int32_t tx, int32_t ty, int32_t tz) const {
	const Tile *t = tile(tx, ty, tz);
	return t == nullptr ? 0 : t->revision;
}

} // namespace nav_air
