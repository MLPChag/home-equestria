// nav_air binary formats (see air_serialize.h).
#include "air_serialize.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <unordered_set>

namespace nav_air {

namespace {

const char DATA_MAGIC[8] = {'H', 'E', 'A', 'I', 'R', 'N', 'A', 'V'};
const char GEOMETRY_MAGIC[8] = {'H', 'E', 'A', 'I', 'R', 'G', 'E', 'O'};

struct Writer {
	std::vector<uint8_t> &out;
	void bytes(const void *p, size_t n) {
		const uint8_t *b = static_cast<const uint8_t *>(p);
		out.insert(out.end(), b, b + n);
	}
	void u8(uint8_t v) { out.push_back(v); }
	void u16(uint16_t v) { u8(uint8_t(v)); u8(uint8_t(v >> 8)); }
	void u32(uint32_t v) { for (int i = 0; i < 4; ++i) u8(uint8_t(v >> (8 * i))); }
	void u64(uint64_t v) { for (int i = 0; i < 8; ++i) u8(uint8_t(v >> (8 * i))); }
	void i32(int32_t v) { u32(uint32_t(v)); }
	void f32(float v) { uint32_t u; std::memcpy(&u, &v, 4); u32(u); }
	void f64(double v) { uint64_t u; std::memcpy(&u, &v, 8); u64(u); }
};

struct Reader {
	const uint8_t *data;
	size_t size, at = 0;
	bool ok = true;
	bool need(size_t n) {
		if (!ok || size - at < n) { ok = false; return false; }
		return true;
	}
	bool bytes(void *p, size_t n) {
		if (!need(n)) return false;
		std::memcpy(p, data + at, n);
		at += n;
		return true;
	}
	uint8_t u8() { return need(1) ? data[at++] : 0; }
	uint16_t u16() { uint16_t v = u8(); v |= uint16_t(u8()) << 8; return v; }
	uint32_t u32() { uint32_t v = 0; for (int i = 0; i < 4; ++i) v |= uint32_t(u8()) << (8 * i); return v; }
	uint64_t u64() { uint64_t v = 0; for (int i = 0; i < 8; ++i) v |= uint64_t(u8()) << (8 * i); return v; }
	int32_t i32() { return int32_t(u32()); }
	float f32() { uint32_t u = u32(); float v; std::memcpy(&v, &u, 4); return v; }
	double f64() { uint64_t u = u64(); double v; std::memcpy(&v, &u, 8); return v; }
	size_t left() const { return size - at; }
};

bool fail(std::string *error, const std::string &why) {
	if (error) *error = why;
	return false;
}

}  // namespace

uint64_t fnv1a(const void *data, size_t size, uint64_t seed) {
	const uint8_t *b = static_cast<const uint8_t *>(data);
	uint64_t h = seed;
	for (size_t i = 0; i < size; ++i) {
		h ^= b[i];
		h *= 1099511628211ull;
	}
	return h;
}

bool write_air_data(const AirTileSpace &space, uint64_t source_hash, std::vector<uint8_t> &out) {
	const AirProfile &profile = space.profile();
	if (profile.name.size() > 255) return false;
	out.clear();
	Writer w{out};
	w.bytes(DATA_MAGIC, 8);
	w.u32(AIR_DATA_VERSION);
	w.f32(TILE_SIZE);
	w.f32(COARSE_SIZE);
	w.f32(FINE_SIZE);
	w.u32(DIM);
	w.f64(0.0);
	w.f64(0.0);
	w.f64(0.0);
	w.u64(source_hash);
	w.f32(profile.envelope_radius);
	w.f32(profile.centre_offset.x);
	w.f32(profile.centre_offset.y);
	w.f32(profile.centre_offset.z);
	w.u16(uint16_t(profile.name.size()));
	w.bytes(profile.name.data(), profile.name.size());
	const std::vector<TileKey> keys = space.keys();
	TileKey mn{0, 0, 0}, mx{-1, -1, -1};
	for (size_t i = 0; i < keys.size(); ++i) {
		const TileKey &k = keys[i];
		if (i == 0) mn = mx = k;
		mn = {std::min(mn.x, k.x), std::min(mn.y, k.y), std::min(mn.z, k.z)};
		mx = {std::max(mx.x, k.x), std::max(mx.y, k.y), std::max(mx.z, k.z)};
	}
	w.i32(mn.x); w.i32(mn.y); w.i32(mn.z);
	w.i32(mx.x); w.i32(mx.y); w.i32(mx.z);
	w.u32(uint32_t(keys.size()));
	for (const TileKey &k : keys) {
		const AirTile *t = space.find(k);
		w.i32(k.x); w.i32(k.y); w.i32(k.z);
		w.u64(t->source_hash);
		w.u8(t->uniform);
		if (t->uniform) continue;
		for (uint16_t e : t->coarse) w.u16(e);
		w.u16(uint16_t(t->brick_count()));
		w.bytes(t->bricks.data(), t->bricks.size());
	}
	const uint64_t sum = fnv1a(out.data(), out.size());
	w.u64(sum);
	return true;
}

bool read_air_data(const uint8_t *data, size_t size, AirTileSpace &space, AirDataInfo *info, std::string *error) {
	if (!data || size < 8 + 8) return fail(error, "file too short");
	uint64_t stored = 0;
	for (int i = 0; i < 8; ++i) stored |= uint64_t(data[size - 8 + size_t(i)]) << (8 * i);
	if (fnv1a(data, size - 8) != stored) return fail(error, "checksum mismatch");
	Reader r{data, size - 8};
	char magic[8];
	r.bytes(magic, 8);
	if (!r.ok || std::memcmp(magic, DATA_MAGIC, 8) != 0) return fail(error, "not nav_air data");
	AirDataInfo meta;
	meta.version = r.u32();
	if (meta.version != AIR_DATA_VERSION) return fail(error, "unsupported version " + std::to_string(meta.version));
	meta.tile_size = r.f32();
	meta.coarse_size = r.f32();
	meta.fine_size = r.f32();
	const uint32_t dim = r.u32();
	if (meta.tile_size != TILE_SIZE || meta.coarse_size != COARSE_SIZE || meta.fine_size != FINE_SIZE || dim != DIM)
		return fail(error, "resolution mismatch");
	for (double &o : meta.origin) o = r.f64();
	if (meta.origin[0] != 0.0 || meta.origin[1] != 0.0 || meta.origin[2] != 0.0) return fail(error, "unsupported origin");
	meta.source_hash = r.u64();
	meta.profile.envelope_radius = r.f32();
	meta.profile.centre_offset.x = r.f32();
	meta.profile.centre_offset.y = r.f32();
	meta.profile.centre_offset.z = r.f32();
	if (!std::isfinite(meta.profile.envelope_radius) || meta.profile.envelope_radius < 0) return fail(error, "bad envelope");
	const uint16_t name_len = r.u16();
	if (name_len > 255) return fail(error, "bad profile name");
	meta.profile.name.resize(name_len);
	if (name_len) r.bytes(&meta.profile.name[0], name_len);
	meta.min = {r.i32(), r.i32(), r.i32()};
	meta.max = {r.i32(), r.i32(), r.i32()};
	meta.tile_count = r.u32();
	if (!r.ok) return fail(error, "truncated header");
	if (size_t(meta.tile_count) > r.left() / 21) return fail(error, "bad tile count");
	std::vector<std::shared_ptr<AirTile>> tiles;
	tiles.reserve(meta.tile_count);
	std::unordered_set<TileKey, TileKeyHash> seen;
	for (uint32_t i = 0; i < meta.tile_count; ++i) {
		auto t = std::make_shared<AirTile>();
		t->key = {r.i32(), r.i32(), r.i32()};
		t->source_hash = r.u64();
		t->uniform = r.u8();
		if (!r.ok) return fail(error, "truncated tile");
		if (!seen.insert(t->key).second) return fail(error, "duplicate tile");
		if (t->key.x < meta.min.x || t->key.y < meta.min.y || t->key.z < meta.min.z || t->key.x > meta.max.x ||
				t->key.y > meta.max.y || t->key.z > meta.max.z)
			return fail(error, "tile outside bounds");
		if (t->uniform == uint8_t(Cell::FREE) || t->uniform == uint8_t(Cell::SOLID)) {
			tiles.push_back(t);
			continue;
		}
		if (t->uniform != 0) return fail(error, "bad uniform state");
		t->coarse.resize(CELLS);
		for (uint16_t &e : t->coarse) e = r.u16();
		const uint16_t bricks = r.u16();
		if (!r.ok || bricks > CELLS) return fail(error, "bad brick count");
		t->bricks.resize(size_t(bricks) * BRICK_BYTES);
		if (bricks && !r.bytes(t->bricks.data(), t->bricks.size())) return fail(error, "truncated bricks");
		for (uint16_t e : t->coarse)
			if (e >= ENTRY_BRICK_BASE + bricks) return fail(error, "brick index out of range");
		for (uint8_t b : t->bricks)
			for (int s = 0; s < 8; s += 2)
				if (((b >> s) & 3) == 3) return fail(error, "bad fine state");
		tiles.push_back(t);
	}
	if (!r.ok || r.left() != 0) return fail(error, "trailing or missing bytes");
	space.set_profile(meta.profile);
	for (auto &t : tiles) space.publish(t);
	if (info) *info = meta;
	return true;
}

bool save_file(const std::string &path, const std::vector<uint8_t> &bytes, std::string *error) {
	FILE *f = std::fopen(path.c_str(), "wb");
	if (!f) return fail(error, "cannot open for writing");
	const bool ok = bytes.empty() || std::fwrite(bytes.data(), 1, bytes.size(), f) == bytes.size();
	const bool closed = std::fclose(f) == 0;
	return (ok && closed) ? true : fail(error, "write failed");
}

bool load_file(const std::string &path, std::vector<uint8_t> &bytes, std::string *error) {
	FILE *f = std::fopen(path.c_str(), "rb");
	if (!f) return fail(error, "cannot open");
	std::fseek(f, 0, SEEK_END);
	const long n = std::ftell(f);
	std::fseek(f, 0, SEEK_SET);
	if (n < 0) {
		std::fclose(f);
		return fail(error, "cannot size");
	}
	bytes.resize(size_t(n));
	const bool ok = n == 0 || std::fread(bytes.data(), 1, size_t(n), f) == size_t(n);
	std::fclose(f);
	return ok ? true : fail(error, "read failed");
}

bool read_geometry_column(const uint8_t *data, size_t size, GeometryColumn &out, std::string *error) {
	out = GeometryColumn();
	Reader r{data, size};
	char magic[8];
	r.bytes(magic, 8);
	if (!r.ok || std::memcmp(magic, GEOMETRY_MAGIC, 8) != 0) return fail(error, "not nav_air geometry");
	const uint32_t version = r.u32();
	if (version != AIR_GEOMETRY_VERSION) return fail(error, "unsupported geometry version");
	out.tx = r.i32();
	out.tz = r.i32();
	out.tile_size = r.f32();
	out.margin = r.f32();
	const uint32_t records = r.u32();
	if (!r.ok) return fail(error, "truncated header");
	for (uint32_t i = 0; i < records; ++i) {
		const uint8_t kind = r.u8();
		const uint8_t cls = r.u8();
		r.u16();
		const uint32_t count = r.u32();
		if (!r.ok || cls >= uint8_t(SourceClass::COUNT)) return fail(error, "bad record");
		if (kind == 1) {
			if (size_t(count) > r.left() / 36) return fail(error, "truncated triangles");
			TriangleSoup soup;
			soup.cls = SourceClass(cls);
			soup.xyz.resize(size_t(count) * 9);
			for (float &v : soup.xyz) v = r.f32();
			out.triangles += count;
			out.geometry.soups.push_back(std::move(soup));
		} else if (kind == 2) {
			if (size_t(count) > r.left() / 12) return fail(error, "truncated convex");
			ConvexSolid s;
			s.cls = SourceClass(cls);
			s.points.resize(count);
			for (Vec3 &p : s.points) p = {r.f32(), r.f32(), r.f32()};
			++out.convexes;
			out.geometry.convexes.push_back(std::move(s));
		} else if (kind == 3) {
			HeightField f;
			f.cls = SourceClass(cls);
			f.x0 = r.f32();
			f.z0 = r.f32();
			f.dx = r.f32();
			f.dz = r.f32();
			f.w = r.i32();
			f.d = r.i32();
			if (!r.ok || f.w < 2 || f.d < 2 || !(f.dx > 0) || !(f.dz > 0) || uint64_t(f.w) * uint64_t(f.d) != count ||
					size_t(count) > r.left() / 4)
				return fail(error, "bad heightfield");
			f.heights.resize(count);
			for (float &h : f.heights) h = r.f32();
			++out.fields;
			out.geometry.fields.push_back(std::move(f));
		} else {
			return fail(error, "unknown record kind");
		}
	}
	if (!r.ok || r.left() != 0) return fail(error, "trailing or missing bytes");
	out.geometry.source_hash = fnv1a(data, size);
	return true;
}

bool read_manifest(const std::string &path, std::map<std::string, std::string> &out, std::string *error) {
	std::vector<uint8_t> bytes;
	if (!load_file(path, bytes, error)) return false;
	std::string text(bytes.begin(), bytes.end());
	size_t at = 0;
	while (at < text.size()) {
		size_t end = text.find('\n', at);
		if (end == std::string::npos) end = text.size();
		std::string line = text.substr(at, end - at);
		at = end + 1;
		while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
		if (line.empty() || line[0] == '#') continue;
		const size_t eq = line.find('=');
		if (eq == std::string::npos) return fail(error, "bad manifest line");
		out[line.substr(0, eq)] = line.substr(eq + 1);
	}
	return true;
}

}  // namespace nav_air
