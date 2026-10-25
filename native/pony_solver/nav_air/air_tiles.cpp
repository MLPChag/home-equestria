// Sparse air tile storage (see air_tiles.h).
#include "air_tiles.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <utility>

namespace nav_air {

namespace {

std::atomic<uint64_t> g_revision{0};

inline int cell_index(int x, int y, int z) { return x + DIM * (y + DIM * z); }
inline int tile_index(int x, int y, int z) { return x + TILE_FINE * (y + TILE_FINE * z); }

inline Cell brick_get(const uint8_t *brick, int f) {
	return Cell((brick[f >> 2] >> ((f & 3) * 2)) & 3);
}
inline void brick_set(uint8_t *brick, int f, Cell v) {
	const int shift = (f & 3) * 2;
	brick[f >> 2] = uint8_t((brick[f >> 2] & ~(3 << shift)) | (int(v) << shift));
}

const int SIDE_AXIS[6] = {0, 0, 1, 1, 2, 2};
const int SIDE_SIGN[6] = {-1, 1, -1, 1, -1, 1};

TileKey offset_key(const TileKey &k, int side) {
	TileKey n = k;
	const int s = SIDE_SIGN[side];
	if (SIDE_AXIS[side] == 0) n.x += s;
	else if (SIDE_AXIS[side] == 1) n.y += s;
	else n.z += s;
	return n;
}

// Tile-local fine coordinates of face position (u, v) on `side`; `opposite` gives the
// coordinates of the touching cell in the neighbour tile.
void face_cell(int side, int u, int v, bool opposite, int out[3]) {
	const int axis = SIDE_AXIS[side];
	const bool high = SIDE_SIGN[side] > 0;
	const int layer = (high != opposite) ? TILE_FINE - 1 : 0;
	const int b = (axis + 1) % 3, c = (axis + 2) % 3;
	out[axis] = layer;
	out[b] = u;
	out[c] = v;
}

struct UnionFind {
	std::vector<uint32_t> parent;
	explicit UnionFind(size_t n) : parent(n) {
		for (size_t i = 0; i < n; ++i) parent[i] = uint32_t(i);
	}
	uint32_t find(uint32_t a) {
		while (parent[a] != a) {
			parent[a] = parent[parent[a]];
			a = parent[a];
		}
		return a;
	}
	void unite(uint32_t a, uint32_t b) {
		a = find(a);
		b = find(b);
		if (a != b) parent[std::max(a, b)] = std::min(a, b);
	}
};

}  // namespace

// ---------------------------------------------------------------- AirTile

Cell AirTile::coarse_state(int coarse_index) const {
	if (uniform) return Cell(uniform);
	const uint16_t e = coarse[size_t(coarse_index)];
	return e >= ENTRY_BRICK_BASE ? Cell::UNKNOWN : Cell(e);
}

Cell AirTile::fine_state(int coarse_index, int fine_index) const {
	if (uniform) return Cell(uniform);
	const uint16_t e = coarse[size_t(coarse_index)];
	if (e < ENTRY_BRICK_BASE) return Cell(e);
	return brick_get(&bricks[size_t(e - ENTRY_BRICK_BASE) * BRICK_BYTES], fine_index);
}

Cell AirTile::state_at(int fx, int fy, int fz) const {
	return fine_state(cell_index(fx >> 3, fy >> 3, fz >> 3), cell_index(fx & 7, fy & 7, fz & 7));
}

uint16_t AirTile::component_at(int fx, int fy, int fz) const {
	const int c = cell_index(fx >> 3, fy >> 3, fz >> 3);
	const int f = cell_index(fx & 7, fy & 7, fz & 7);
	if (fine_state(c, f) != Cell::FREE) return NO_COMPONENT;
	if (uniform) return component_count ? 0 : NO_COMPONENT;
	const uint16_t e = coarse[size_t(c)];
	if (e < ENTRY_BRICK_BASE) return coarse_component.empty() ? NO_COMPONENT : coarse_component[size_t(c)];
	const size_t b = e - ENTRY_BRICK_BASE;
	if (b >= brick_component.size()) return NO_COMPONENT;
	const uint16_t bc = brick_component[b];
	if (bc != MIXED_BRICK) return bc;
	return fine_labels[brick_labels_at[b] + size_t(f)];
}

void AirTile::expand(uint8_t *out) const {
	if (uniform) {
		std::memset(out, uniform, TILE_FINE_CELLS);
		return;
	}
	for (int cz = 0; cz < DIM; ++cz)
		for (int cy = 0; cy < DIM; ++cy)
			for (int cx = 0; cx < DIM; ++cx) {
				const int c = cell_index(cx, cy, cz);
				const uint16_t e = coarse[size_t(c)];
				const uint8_t *brick = e >= ENTRY_BRICK_BASE ? &bricks[size_t(e - ENTRY_BRICK_BASE) * BRICK_BYTES] : nullptr;
				for (int z = 0; z < DIM; ++z)
					for (int y = 0; y < DIM; ++y)
						for (int x = 0; x < DIM; ++x) {
							const uint8_t v = brick ? uint8_t(brick_get(brick, cell_index(x, y, z))) : uint8_t(e);
							out[tile_index(cx * 8 + x, cy * 8 + y, cz * 8 + z)] = v;
						}
			}
}

size_t AirTile::memory_bytes() const {
	return sizeof(AirTile) + coarse.capacity() * sizeof(uint16_t) + bricks.capacity() +
			coarse_component.capacity() * sizeof(uint16_t) + brick_component.capacity() * sizeof(uint16_t) +
			brick_labels_at.capacity() * sizeof(uint32_t) + fine_labels.capacity() * sizeof(uint16_t);
}

std::shared_ptr<AirTile> make_tile(const TileKey &key, const uint8_t *fine, uint64_t source_hash) {
	auto tile = std::make_shared<AirTile>();
	tile->key = key;
	tile->source_hash = source_hash;
	bool same = true;
	for (int i = 1; i < TILE_FINE_CELLS && same; ++i) same = fine[i] == fine[0];
	if (same && fine[0] != uint8_t(Cell::UNKNOWN)) {
		tile->uniform = fine[0];
		return tile;
	}
	tile->coarse.assign(CELLS, ENTRY_UNKNOWN);
	uint8_t local[CELLS];
	for (int cz = 0; cz < DIM; ++cz)
		for (int cy = 0; cy < DIM; ++cy)
			for (int cx = 0; cx < DIM; ++cx) {
				bool uniform_cell = true;
				for (int z = 0; z < DIM; ++z)
					for (int y = 0; y < DIM; ++y)
						for (int x = 0; x < DIM; ++x) {
							const uint8_t v = fine[tile_index(cx * 8 + x, cy * 8 + y, cz * 8 + z)];
							local[cell_index(x, y, z)] = v;
							uniform_cell = uniform_cell && v == local[0];
						}
				const int c = cell_index(cx, cy, cz);
				if (uniform_cell) {
					tile->coarse[size_t(c)] = local[0];
					continue;
				}
				const size_t b = tile->brick_count();
				tile->bricks.resize(tile->bricks.size() + BRICK_BYTES, 0);
				uint8_t *brick = &tile->bricks[b * BRICK_BYTES];
				for (int f = 0; f < CELLS; ++f) brick_set(brick, f, Cell(local[f]));
				tile->coarse[size_t(c)] = uint16_t(ENTRY_BRICK_BASE + b);
			}
	tile->bricks.shrink_to_fit();
	return tile;
}

void compute_components(AirTile &tile) {
	tile.component_count = 0;
	tile.coarse_component.clear();
	tile.brick_component.clear();
	tile.brick_labels_at.clear();
	tile.fine_labels.clear();
	if (tile.uniform) {
		tile.component_count = tile.uniform == uint8_t(Cell::FREE) ? 1 : 0;
		return;
	}
	std::vector<uint8_t> grid(TILE_FINE_CELLS);
	tile.expand(grid.data());
	std::vector<uint16_t> label(TILE_FINE_CELLS, NO_COMPONENT);
	std::vector<int> stack;
	// Labels above this share one id: unreachable in practice after inflation, and merging
	// pockets only ever keeps them FREE (never claims a false seal).
	const uint16_t LAST = AirTile::MIXED_BRICK - 1;
	uint32_t count = 0;
	for (int start = 0; start < TILE_FINE_CELLS; ++start) {
		if (grid[size_t(start)] != uint8_t(Cell::FREE) || label[size_t(start)] != NO_COMPONENT) continue;
		const uint16_t id = uint16_t(std::min<uint32_t>(count, LAST));
		if (count <= LAST) ++count;
		label[size_t(start)] = id;
		stack.push_back(start);
		while (!stack.empty()) {
			const int i = stack.back();
			stack.pop_back();
			const int x = i & 63, y = (i >> 6) & 63, z = i >> 12;
			const int n[6] = {x > 0 ? i - 1 : -1, x < 63 ? i + 1 : -1, y > 0 ? i - 64 : -1,
				y < 63 ? i + 64 : -1, z > 0 ? i - 4096 : -1, z < 63 ? i + 4096 : -1};
			for (int k = 0; k < 6; ++k) {
				const int j = n[k];
				if (j < 0 || grid[size_t(j)] != uint8_t(Cell::FREE) || label[size_t(j)] != NO_COMPONENT) continue;
				label[size_t(j)] = id;
				stack.push_back(j);
			}
		}
	}
	tile.component_count = uint16_t(count);
	tile.coarse_component.assign(CELLS, NO_COMPONENT);
	const size_t bricks = tile.brick_count();
	tile.brick_component.assign(bricks, NO_COMPONENT);
	tile.brick_labels_at.assign(bricks, UINT32_MAX);
	for (int cz = 0; cz < DIM; ++cz)
		for (int cy = 0; cy < DIM; ++cy)
			for (int cx = 0; cx < DIM; ++cx) {
				const int c = cell_index(cx, cy, cz);
				const uint16_t e = tile.coarse[size_t(c)];
				if (e < ENTRY_BRICK_BASE) {
					if (e == ENTRY_FREE) tile.coarse_component[size_t(c)] = label[size_t(tile_index(cx * 8, cy * 8, cz * 8))];
					continue;
				}
				const size_t b = e - ENTRY_BRICK_BASE;
				uint16_t single = NO_COMPONENT;
				bool mixed = false;
				uint16_t local[CELLS];
				for (int z = 0; z < DIM; ++z)
					for (int y = 0; y < DIM; ++y)
						for (int x = 0; x < DIM; ++x) {
							const uint16_t l = label[size_t(tile_index(cx * 8 + x, cy * 8 + y, cz * 8 + z))];
							local[cell_index(x, y, z)] = l;
							if (l == NO_COMPONENT) continue;
							if (single == NO_COMPONENT) single = l;
							else if (l != single) mixed = true;
						}
				if (!mixed) {
					tile.brick_component[b] = single;
					continue;
				}
				tile.brick_component[b] = AirTile::MIXED_BRICK;
				tile.brick_labels_at[b] = uint32_t(tile.fine_labels.size());
				tile.fine_labels.insert(tile.fine_labels.end(), local, local + CELLS);
			}
	tile.fine_labels.shrink_to_fit();
}

// ---------------------------------------------------------------- AirTileSpace

AirTileSpace::AirTileSpace(AirProfile profile) : profile_(std::move(profile)) {}

uint64_t AirTileSpace::next_revision() { return g_revision.fetch_add(1) + 1; }

const AirTile *AirTileSpace::find(const TileKey &key) const {
	auto it = tiles_.find(key);
	return it == tiles_.end() ? nullptr : it->second.get();
}

std::shared_ptr<const AirTile> AirTileSpace::tile(const TileKey &key) const {
	auto it = tiles_.find(key);
	return it == tiles_.end() ? nullptr : it->second;
}

uint64_t AirTileSpace::publish(std::shared_ptr<AirTile> tile) {
	if (!tile) return 0;
	compute_components(*tile);
	tile->revision = next_revision();
	const uint64_t revision = tile->revision;
	tiles_[tile->key] = std::move(tile);
	return revision;
}

bool AirTileSpace::remove(const TileKey &key) { return tiles_.erase(key) > 0; }

std::vector<TileKey> AirTileSpace::keys() const {
	std::vector<TileKey> out;
	out.reserve(tiles_.size());
	for (const auto &it : tiles_) out.push_back(it.first);
	std::sort(out.begin(), out.end());
	return out;
}

size_t AirTileSpace::brick_count() const {
	size_t n = 0;
	for (const auto &it : tiles_) n += it.second->brick_count();
	return n;
}

size_t AirTileSpace::memory_bytes() const {
	// Map node (key + shared_ptr + next pointer + cached hash) and the shared_ptr control
	// block are estimated; tile arrays are measured by capacity.
	size_t bytes = sizeof(*this) + tiles_.bucket_count() * sizeof(void *);
	for (const auto &it : tiles_) bytes += it.second->memory_bytes() + 64;
	return bytes;
}

std::shared_ptr<AirTileSpace> AirTileSpace::snapshot() const { return std::make_shared<AirTileSpace>(*this); }

bool AirTileSpace::locate(const Vec3 &p, CellId &out) const {
	out = CellId{0, 0, 0, 0, 0, 0};
	if (!std::isfinite(p.x) || !std::isfinite(p.y) || !std::isfinite(p.z)) return false;
	const double inv = 1.0 / double(FINE_SIZE);
	const int64_t g[3] = {int64_t(std::floor(double(p.x) * inv)), int64_t(std::floor(double(p.y) * inv)),
		int64_t(std::floor(double(p.z) * inv))};
	int64_t t[3];
	int l[3];
	for (int a = 0; a < 3; ++a) {
		t[a] = floor_div(g[a], TILE_FINE);
		l[a] = int(g[a] - t[a] * TILE_FINE);
		if (t[a] < INT32_MIN || t[a] > INT32_MAX) return false;
	}
	out.tx = int32_t(t[0]);
	out.ty = int32_t(t[1]);
	out.tz = int32_t(t[2]);
	out.coarse = uint16_t(cell_index(l[0] >> 3, l[1] >> 3, l[2] >> 3));
	const AirTile *tile = find({out.tx, out.ty, out.tz});
	if (!tile) return false;
	if (tile->is_brick(out.coarse)) {
		out.level = 1;
		out.fine = uint16_t(cell_index(l[0] & 7, l[1] & 7, l[2] & 7));
	}
	return true;
}

Cell AirTileSpace::state(const CellId &c) const {
	const AirTile *tile = find({c.tx, c.ty, c.tz});
	if (!tile || c.coarse >= CELLS || c.level > 1 || (c.level == 1 && c.fine >= CELLS)) return Cell::UNKNOWN;
	return c.level == 0 ? tile->coarse_state(c.coarse) : tile->fine_state(c.coarse, c.fine);
}

Aabb AirTileSpace::bounds(const CellId &c) const {
	const int cx = c.coarse % DIM, cy = (c.coarse / DIM) % DIM, cz = c.coarse / (DIM * DIM);
	double o[3] = {double(c.tx) * TILE_SIZE + cx * double(COARSE_SIZE), double(c.ty) * TILE_SIZE + cy * double(COARSE_SIZE),
		double(c.tz) * TILE_SIZE + cz * double(COARSE_SIZE)};
	double size = COARSE_SIZE;
	if (c.level == 1) {
		o[0] += (c.fine % DIM) * double(FINE_SIZE);
		o[1] += ((c.fine / DIM) % DIM) * double(FINE_SIZE);
		o[2] += (c.fine / (DIM * DIM)) * double(FINE_SIZE);
		size = FINE_SIZE;
	}
	return Aabb{{float(o[0]), float(o[1]), float(o[2])}, {float(o[0] + size), float(o[1] + size), float(o[2] + size)}};
}

void AirTileSpace::neighbours(const CellId &c, std::vector<Face> &out) const {
	out.clear();
	const AirTile *tile = find({c.tx, c.ty, c.tz});
	if (!tile || c.coarse >= CELLS || c.level > 1 || (c.level == 1 && c.fine >= CELLS)) return;
	if (c.level == 0 && tile->is_brick(c.coarse)) return;  // not a leaf
	const int64_t t[3] = {c.tx, c.ty, c.tz};
	const int cc[3] = {c.coarse % DIM, (c.coarse / DIM) % DIM, c.coarse / (DIM * DIM)};
	int64_t lo[3];
	int n = DIM;
	for (int a = 0; a < 3; ++a) lo[a] = t[a] * TILE_FINE + cc[a] * DIM;
	if (c.level == 1) {
		const int fc[3] = {c.fine % DIM, (c.fine / DIM) % DIM, c.fine / (DIM * DIM)};
		for (int a = 0; a < 3; ++a) lo[a] += fc[a];
		n = 1;
	}
	const double h = FINE_SIZE;
	for (int side = 0; side < 6; ++side) {
		const int a = SIDE_AXIS[side], b = (a + 1) % 3, d = (a + 2) % 3;
		const bool high = SIDE_SIGN[side] > 0;
		int64_t g[3] = {lo[0], lo[1], lo[2]};
		g[a] = high ? lo[a] + n : lo[a] - 1;
		int64_t nt[3];
		int nl[3];
		for (int k = 0; k < 3; ++k) {
			nt[k] = floor_div(g[k], TILE_FINE);
			nl[k] = int(g[k] - nt[k] * TILE_FINE);
		}
		const TileKey nkey{int32_t(nt[0]), int32_t(nt[1]), int32_t(nt[2])};
		const AirTile *other = find(nkey);
		if (!other) continue;  // missing tile: unknown, never free
		const int ncoarse = cell_index(nl[0] >> 3, nl[1] >> 3, nl[2] >> 3);
		const float plane = float(double(high ? lo[a] + n : lo[a]) * h);
		if (!other->is_brick(ncoarse)) {
			if (other->coarse_state(ncoarse) != Cell::FREE) continue;
			Face face;
			face.to = CellId{nkey.x, nkey.y, nkey.z, uint16_t(ncoarse), 0, 0};
			float mn[3], mx[3];
			mn[a] = mx[a] = plane;
			mn[b] = float(double(lo[b]) * h);
			mx[b] = float(double(lo[b] + n) * h);
			mn[d] = float(double(lo[d]) * h);
			mx[d] = float(double(lo[d] + n) * h);
			face.overlap = Aabb{{mn[0], mn[1], mn[2]}, {mx[0], mx[1], mx[2]}};
			out.push_back(face);
			continue;
		}
		// Brick across the face: enumerate every touching fine cell (one for a fine cell, an
		// 8 x 8 layer for a coarse cell), keeping only FREE ones with their own face rectangle.
		for (int j = 0; j < n; ++j) {
			for (int i = 0; i < n; ++i) {
				int f[3];
				f[a] = nl[a] & 7;
				f[b] = (nl[b] & 7) + i;
				f[d] = (nl[d] & 7) + j;
				const int fine = cell_index(f[0], f[1], f[2]);
				if (other->fine_state(ncoarse, fine) != Cell::FREE) continue;
				Face face;
				face.to = CellId{nkey.x, nkey.y, nkey.z, uint16_t(ncoarse), uint16_t(fine), 1};
				float mn[3], mx[3];
				mn[a] = mx[a] = plane;
				mn[b] = float(double(lo[b] + i) * h);
				mx[b] = float(double(lo[b] + i + 1) * h);
				mn[d] = float(double(lo[d] + j) * h);
				mx[d] = float(double(lo[d] + j + 1) * h);
				face.overlap = Aabb{{mn[0], mn[1], mn[2]}, {mx[0], mx[1], mx[2]}};
				out.push_back(face);
			}
		}
	}
}

Cell AirTileSpace::sample(const Vec3 &p) const {
	CellId c;
	if (!locate(p, c)) return Cell::UNKNOWN;
	return state(c);
}

uint64_t AirTileSpace::tile_revision(int32_t tx, int32_t ty, int32_t tz) const {
	const AirTile *tile = find({tx, ty, tz});
	return tile ? tile->revision : 0;
}

bool AirTileSpace::touches_unknown(const CellId &c) const {
	const AirTile *tile = find({c.tx, c.ty, c.tz});
	if (!tile || c.coarse >= CELLS || c.level > 1 || (c.level == 1 && c.fine >= CELLS)) return true;
	const int cc[3] = {c.coarse % DIM, (c.coarse / DIM) % DIM, c.coarse / (DIM * DIM)};
	int lo[3], n = DIM;
	for (int a = 0; a < 3; ++a) lo[a] = cc[a] * DIM;
	if (c.level == 1) {
		const int fc[3] = {c.fine % DIM, (c.fine / DIM) % DIM, c.fine / (DIM * DIM)};
		for (int a = 0; a < 3; ++a) lo[a] += fc[a];
		n = 1;
	}
	const TileKey key{c.tx, c.ty, c.tz};
	for (int side = 0; side < 6; ++side) {
		const int a = SIDE_AXIS[side];
		const bool on_side = SIDE_SIGN[side] > 0 ? lo[a] + n == TILE_FINE : lo[a] == 0;
		if (on_side && !find(offset_key(key, side))) return true;
	}
	return false;
}

uint16_t AirTileSpace::component(const CellId &c) const {
	const AirTile *tile = find({c.tx, c.ty, c.tz});
	if (!tile || c.coarse >= CELLS) return NO_COMPONENT;
	const int cx = c.coarse % DIM, cy = (c.coarse / DIM) % DIM, cz = c.coarse / (DIM * DIM);
	if (c.level == 0) {
		if (tile->is_brick(c.coarse)) return NO_COMPONENT;
		return tile->component_at(cx * 8, cy * 8, cz * 8);
	}
	if (c.fine >= CELLS) return NO_COMPONENT;
	return tile->component_at(cx * 8 + c.fine % DIM, cy * 8 + (c.fine / DIM) % DIM, cz * 8 + c.fine / (DIM * DIM));
}

void AirTileSpace::tile_links(const TileKey &key, std::vector<Link> &out) const {
	out.clear();
	const AirTile *tile = find(key);
	if (!tile) return;
	std::vector<std::pair<uint16_t, uint16_t>> pairs;
	for (int side = 0; side < 6; ++side) {
		const TileKey nkey = offset_key(key, side);
		const AirTile *other = find(nkey);
		if (!other) continue;
		pairs.clear();
		for (int v = 0; v < TILE_FINE; ++v)
			for (int u = 0; u < TILE_FINE; ++u) {
				int p[3], q[3];
				face_cell(side, u, v, false, p);
				face_cell(side, u, v, true, q);
				const uint16_t a = tile->component_at(p[0], p[1], p[2]);
				if (a == NO_COMPONENT) continue;
				const uint16_t b = other->component_at(q[0], q[1], q[2]);
				if (b == NO_COMPONENT) continue;
				if (pairs.empty() || pairs.back() != std::make_pair(a, b)) pairs.emplace_back(a, b);
			}
		std::sort(pairs.begin(), pairs.end());
		pairs.erase(std::unique(pairs.begin(), pairs.end()), pairs.end());
		for (const auto &pr : pairs) {
			Link link;
			link.from = pr.first;
			link.to = nkey;
			link.to_component = pr.second;
			link.side = uint8_t(side);
			out.push_back(link);
		}
	}
}

size_t AirTileSpace::seal_enclosed(const std::vector<TileKey> &scope) {
	std::unordered_map<TileKey, uint32_t, TileKeyHash> base;
	std::vector<std::pair<TileKey, const AirTile *>> members;
	uint32_t total = 0;
	for (const TileKey &key : scope) {
		const AirTile *tile = find(key);
		if (!tile || base.count(key)) continue;
		base[key] = total;
		members.emplace_back(key, tile);
		total += tile->component_count;
	}
	if (total == 0) return 0;
	UnionFind uf(total);
	std::vector<uint8_t> open(total, 0);
	for (const auto &m : members) {
		const TileKey &key = m.first;
		const AirTile *tile = m.second;
		if (tile->component_count == 0) continue;
		const uint32_t mine = base[key];
		for (int side = 0; side < 6; ++side) {
			const TileKey nkey = offset_key(key, side);
			const AirTile *other = find(nkey);
			auto in_scope = base.find(nkey);
			const bool positive = SIDE_SIGN[side] > 0;
			if (other && in_scope != base.end() && !positive) continue;  // united from the other side
			for (int v = 0; v < TILE_FINE; ++v)
				for (int u = 0; u < TILE_FINE; ++u) {
					int p[3];
					face_cell(side, u, v, false, p);
					const uint16_t a = tile->component_at(p[0], p[1], p[2]);
					if (a == NO_COMPONENT) continue;
					if (!other) {
						open[mine + a] = 1;  // faces unknown space: cannot prove enclosure
						continue;
					}
					int q[3];
					face_cell(side, u, v, true, q);
					if (in_scope == base.end()) {
						if (other->state_at(q[0], q[1], q[2]) == Cell::FREE) open[mine + a] = 1;
						continue;
					}
					const uint16_t b = other->component_at(q[0], q[1], q[2]);
					if (b != NO_COMPONENT) uf.unite(mine + a, in_scope->second + b);
				}
		}
	}
	std::vector<uint8_t> root_open(total, 0);
	for (uint32_t i = 0; i < total; ++i)
		if (open[i]) root_open[uf.find(i)] = 1;
	size_t changed = 0;
	std::vector<uint8_t> grid;
	for (const auto &m : members) {
		const AirTile *tile = m.second;
		const uint32_t mine = base[m.first];
		std::vector<uint8_t> enclosed(tile->component_count, 0);
		bool any = false;
		for (uint16_t c = 0; c < tile->component_count; ++c)
			if (!root_open[uf.find(mine + c)]) enclosed[c] = 1, any = true;
		if (!any) continue;
		grid.resize(TILE_FINE_CELLS);
		tile->expand(grid.data());
		for (int z = 0; z < TILE_FINE; ++z)
			for (int y = 0; y < TILE_FINE; ++y)
				for (int x = 0; x < TILE_FINE; ++x) {
					const uint16_t c = tile->component_at(x, y, z);
					if (c != NO_COMPONENT && enclosed[c]) grid[size_t(tile_index(x, y, z))] = uint8_t(Cell::SOLID);
				}
		publish(make_tile(m.first, grid.data(), tile->source_hash));  // replaces `tile`
		++changed;
	}
	return changed;
}

}  // namespace nav_air
