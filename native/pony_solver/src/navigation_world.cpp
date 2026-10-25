// Native pony navigation, ground storage: see navigation_world.h.
#include "navigation_world.h"

#include <algorithm>
#include <cstring>

namespace ponynav {

namespace {

std::atomic<uint64_t> revision_counter{ 0 };

uint64_t mix(uint64_t hash, uint64_t value) {
	hash ^= value + 0x9e3779b97f4a7c15ull + (hash << 6) + (hash >> 2);
	return hash;
}

uint64_t bits_of(double value) {
	uint64_t bits = 0;
	std::memcpy(&bits, &value, sizeof(bits));
	return bits;
}

void finish_chunk(GroundChunk &chunk) {
	chunk.cost_floor = INF;
	chunk.max_column_spans = 0;
	for (const FloorSpan &span : chunk.spans) {
		chunk.cost_floor = std::min(chunk.cost_floor, span_paint(span));
	}
	for (int32_t column = 0; column < CHUNK_COLUMNS; ++column) {
		chunk.max_column_spans = std::max(chunk.max_column_spans, chunk.column_end(column) - chunk.column_begin(column));
	}
}

} // namespace

uint64_t next_revision() {
	return revision_counter.fetch_add(1, std::memory_order_relaxed) + 1;
}

size_t GroundChunk::memory_bytes() const {
	return sizeof(GroundChunk) + column_offsets.capacity() * sizeof(uint32_t) + spans.capacity() * sizeof(FloorSpan);
}

std::shared_ptr<GroundChunk> build_chunk_from_legacy(const ChunkKey &key, const float *floor_y, size_t floor_count,
		const uint8_t *slope_deg, size_t slope_count, const float *water_depth, size_t water_count, const float *headroom,
		size_t headroom_count, const uint8_t *flags, size_t flags_count, const uint8_t *paint_cost, size_t paint_count,
		const uint8_t *trail_weight, size_t trail_count, std::string &error) {
	const size_t slots = size_t(LEGACY_SLOTS);
	if (flags_count != slots || floor_count != slots || slope_count != slots || water_count != slots ||
			headroom_count != slots) {
		error = "walk chunk slot arrays must hold 64 * 64 * 2 entries";
		return nullptr;
	}
	if (paint_count != size_t(CHUNK_COLUMNS)) {
		error = "walk chunk paint_cost must hold 64 * 64 entries";
		return nullptr;
	}
	auto chunk = std::make_shared<GroundChunk>();
	chunk->key = key;
	chunk->column_offsets.resize(size_t(CHUNK_COLUMNS) + 1);
	size_t solid = 0;
	for (size_t slot = 0; slot < slots; ++slot) {
		solid += (flags[slot] & FLAG_SOLID) ? 1 : 0;
	}
	chunk->spans.reserve(solid);
	for (int32_t column = 0; column < CHUNK_COLUMNS; ++column) {
		chunk->column_offsets[size_t(column)] = uint32_t(chunk->spans.size());
		for (int32_t slot = 0; slot < LEGACY_SPANS; ++slot) {
			const size_t index = size_t(column) * LEGACY_SPANS + size_t(slot);
			if (!(flags[index] & FLAG_SOLID)) {
				continue;
			}
			FloorSpan span;
			span.floor_y = floor_y[index];
			span.headroom = headroom[index];
			span.water_depth = water_depth[index];
			span.surface_id = (uint32_t(column) << SLOT_BITS) | uint32_t(slot);
			span.flags = flags[index];
			span.slope_deg = slope_deg[index];
			span.paint_byte = paint_cost[size_t(column)];
			span.trail_byte = (trail_weight != nullptr && index < trail_count) ? trail_weight[index] : 0;
			chunk->spans.push_back(span);
		}
	}
	chunk->column_offsets[size_t(CHUNK_COLUMNS)] = uint32_t(chunk->spans.size());
	finish_chunk(*chunk);
	return chunk;
}

std::shared_ptr<GroundChunk> build_chunk_from_columns(const ChunkKey &key, const std::vector<uint32_t> &column_offsets,
		const std::vector<SpanInput> &spans, std::string &error) {
	if (column_offsets.size() != size_t(CHUNK_COLUMNS) + 1) {
		error = "column_offsets must hold 64 * 64 + 1 entries";
		return nullptr;
	}
	if (column_offsets.front() != 0 || column_offsets.back() != spans.size()) {
		error = "column_offsets must start at 0 and end at the span count";
		return nullptr;
	}
	auto chunk = std::make_shared<GroundChunk>();
	chunk->key = key;
	chunk->column_offsets = column_offsets;
	chunk->spans.reserve(spans.size());
	for (int32_t column = 0; column < CHUNK_COLUMNS; ++column) {
		const uint32_t begin = column_offsets[size_t(column)];
		const uint32_t end = column_offsets[size_t(column) + 1];
		if (end < begin) {
			error = "column_offsets must not decrease";
			return nullptr;
		}
		if (end - begin > MAX_COLUMN_SPANS) {
			error = "a column holds at most 15 floor spans";
			return nullptr;
		}
		for (uint32_t index = begin; index < end; ++index) {
			const SpanInput &input = spans[index];
			FloorSpan span;
			span.floor_y = input.floor_y;
			span.headroom = input.headroom;
			span.water_depth = input.water_depth;
			span.surface_id = (uint32_t(column) << SLOT_BITS) | (index - begin);
			span.flags = uint8_t(input.flags | FLAG_SOLID);
			span.slope_deg = input.slope_deg;
			span.paint_byte = input.paint_byte;
			span.trail_byte = input.trail_byte;
			chunk->spans.push_back(span);
		}
	}
	finish_chunk(*chunk);
	return chunk;
}

GroundProfile GroundProfile::effective() const {
	GroundProfile result = *this;
	if (scale != 1.0) {
		result.radius = radius * scale;
		result.clearance = clearance * scale;
		result.step = step * scale;
	}
	result.scale = 1.0;
	return result;
}

uint64_t GroundProfile::signature() const {
	uint64_t hash = 0x5ca1ab1eull;
	hash = mix(hash, bits_of(radius));
	hash = mix(hash, bits_of(clearance));
	hash = mix(hash, bits_of(step));
	hash = mix(hash, bits_of(slope));
	hash = mix(hash, bits_of(wade));
	hash = mix(hash, swim ? 1u : 0u);
	hash = mix(hash, bits_of(scale));
	hash = mix(hash, mask);
	return hash;
}

bool GroundProfile::same(const GroundProfile &other) const {
	return bits_of(radius) == bits_of(other.radius) && bits_of(clearance) == bits_of(other.clearance) &&
			bits_of(step) == bits_of(other.step) && bits_of(slope) == bits_of(other.slope) &&
			bits_of(wade) == bits_of(other.wade) && swim == other.swim && bits_of(scale) == bits_of(other.scale) &&
			mask == other.mask;
}

bool GroundProfile::valid(std::string &error) const {
	const double values[] = { radius, clearance, step, slope, wade, scale };
	for (double value : values) {
		if (!std::isfinite(value)) {
			error = "movement profile values must be finite";
			return false;
		}
	}
	if (radius < 0.0 || clearance < 0.0 || step < 0.0 || wade < 0.0 || scale <= 0.0) {
		error = "movement profile radius, clearance, step and wade must be >= 0 and scale > 0";
		return false;
	}
	// Body room looks at most one chunk away (ProfileLayer stamps cover that neighbourhood).
	if (radius * scale > 15.0) {
		error = "movement profile radius must stay below 15 m";
		return false;
	}
	return true;
}

ProfileLayer::ProfileLayer(uint32_t spans) :
		span_count(spans), room(new std::atomic<uint8_t>[spans == 0 ? 1 : spans]) {
	for (uint32_t i = 0; i < span_count; ++i) {
		room[i].store(0, std::memory_order_relaxed);
	}
}

size_t ProfileLayer::memory_bytes() const {
	return sizeof(ProfileLayer) + span_count + component.capacity() * sizeof(uint32_t) + touch.capacity() +
			portal_offsets.capacity() * sizeof(uint32_t) + portals.capacity() * sizeof(Portal);
}

ClearanceCache::ClearanceCache(size_t p_limit) :
		limit(p_limit) {
}

std::shared_ptr<ProfileLayer> ClearanceCache::acquire(const ChunkKey &key, const GroundProfile &profile,
		const std::array<uint64_t, 25> &stamp, uint32_t span_count) {
	const uint64_t used = use_clock.fetch_add(1, std::memory_order_relaxed) + 1;
	std::lock_guard<std::mutex> lock(mutex);
	std::vector<Entry> &list = entries[key.packed()];
	for (Entry &entry : list) {
		if (!entry.profile.same(profile)) {
			continue;
		}
		if (entry.layer->stamp == stamp && entry.layer->span_count == span_count) {
			entry.layer->last_used.store(used, std::memory_order_relaxed);
			hit_count.fetch_add(1, std::memory_order_relaxed);
			return entry.layer;
		}
		// Older or newer geometry around this chunk: replace. A search still holding the old
		// layer keeps it alive through its own shared_ptr.
		entry.layer = std::make_shared<ProfileLayer>(span_count);
		entry.layer->stamp = stamp;
		entry.layer->last_used.store(used, std::memory_order_relaxed);
		miss_count.fetch_add(1, std::memory_order_relaxed);
		return entry.layer;
	}
	Entry entry;
	entry.profile = profile;
	entry.layer = std::make_shared<ProfileLayer>(span_count);
	entry.layer->stamp = stamp;
	entry.layer->last_used.store(used, std::memory_order_relaxed);
	std::shared_ptr<ProfileLayer> result = entry.layer;
	list.push_back(std::move(entry));
	++count;
	miss_count.fetch_add(1, std::memory_order_relaxed);
	if (count > limit) {
		evict_locked();
	}
	return result;
}

void ClearanceCache::evict_locked() {
	// Drop the least recently used quarter. Searches holding a dropped layer keep their copy.
	std::vector<uint64_t> ages;
	ages.reserve(count);
	for (const auto &bucket : entries) {
		for (const Entry &entry : bucket.second) {
			ages.push_back(entry.layer->last_used.load(std::memory_order_relaxed));
		}
	}
	if (ages.empty()) {
		return;
	}
	const size_t drop = std::max<size_t>(1, ages.size() / 4);
	std::nth_element(ages.begin(), ages.begin() + long(drop - 1), ages.end());
	const uint64_t threshold = ages[drop - 1];
	for (auto bucket = entries.begin(); bucket != entries.end();) {
		std::vector<Entry> &list = bucket->second;
		const size_t before = list.size();
		list.erase(std::remove_if(list.begin(), list.end(),
						   [threshold](const Entry &entry) {
							   return entry.layer->last_used.load(std::memory_order_relaxed) <= threshold;
						   }),
				list.end());
		count -= before - list.size();
		if (list.empty()) {
			bucket = entries.erase(bucket);
		} else {
			++bucket;
		}
	}
}

size_t ClearanceCache::layer_count() const {
	std::lock_guard<std::mutex> lock(mutex);
	return count;
}

size_t ClearanceCache::memory_bytes() const {
	std::lock_guard<std::mutex> lock(mutex);
	size_t total = 0;
	for (const auto &bucket : entries) {
		for (const Entry &entry : bucket.second) {
			total += entry.layer->memory_bytes();
		}
	}
	return total;
}

void ClearanceCache::clear() {
	std::lock_guard<std::mutex> lock(mutex);
	entries.clear();
	count = 0;
}

void ClearanceCache::set_limit(size_t p_limit) {
	std::lock_guard<std::mutex> lock(mutex);
	limit = std::max<size_t>(16, p_limit);
	if (count > limit) {
		evict_locked();
	}
}

NavigationWorld::NavigationWorld(uint32_t id) :
		world_id(id), clearance(std::make_shared<ClearanceCache>()) {
}

uint64_t NavigationWorld::publish(std::shared_ptr<GroundChunk> chunk) {
	if (!chunk) {
		return 0;
	}
	chunk->revision = next_revision();
	const uint64_t revision = chunk->revision;
	const uint64_t key = chunk->key.packed();
	std::lock_guard<std::mutex> lock(mutex);
	chunks[key] = std::shared_ptr<const GroundChunk>(std::move(chunk));
	dirty = true;
	return revision;
}

bool NavigationWorld::remove(const ChunkKey &key) {
	std::lock_guard<std::mutex> lock(mutex);
	const bool removed = chunks.erase(key.packed()) > 0;
	dirty = dirty || removed;
	return removed;
}

void NavigationWorld::clear() {
	std::lock_guard<std::mutex> lock(mutex);
	chunks.clear();
	dirty = true;
	clearance->clear();
}

uint64_t NavigationWorld::revision_of(const ChunkKey &key) const {
	std::lock_guard<std::mutex> lock(mutex);
	const auto found = chunks.find(key.packed());
	return found == chunks.end() ? 0 : found->second->revision;
}

std::shared_ptr<const GroundChunk> NavigationWorld::chunk(const ChunkKey &key) const {
	std::lock_guard<std::mutex> lock(mutex);
	const auto found = chunks.find(key.packed());
	return found == chunks.end() ? nullptr : found->second;
}

std::shared_ptr<const Snapshot> NavigationWorld::snapshot() {
	std::lock_guard<std::mutex> lock(mutex);
	if (!dirty && current) {
		return current;
	}
	auto built = std::make_shared<Snapshot>();
	built->epoch = ++epoch;
	built->chunks.reserve(chunks.size());
	for (const auto &entry : chunks) {
		built->chunks.push_back(entry.second);
	}
	std::sort(built->chunks.begin(), built->chunks.end(),
			[](const std::shared_ptr<const GroundChunk> &a, const std::shared_ptr<const GroundChunk> &b) {
				return a->key < b->key;
			});
	built->index.reserve(built->chunks.size() * 2);
	for (size_t i = 0; i < built->chunks.size(); ++i) {
		built->index[built->chunks[i]->key.packed()] = uint32_t(i);
		built->cost_floor = std::min(built->cost_floor, built->chunks[i]->cost_floor);
		built->span_total += built->chunks[i]->spans.size();
	}
	current = built;
	dirty = false;
	return current;
}

size_t NavigationWorld::chunk_count() const {
	std::lock_guard<std::mutex> lock(mutex);
	return chunks.size();
}

size_t NavigationWorld::memory_bytes() const {
	std::lock_guard<std::mutex> lock(mutex);
	size_t total = 0;
	for (const auto &entry : chunks) {
		total += entry.second->memory_bytes();
	}
	return total;
}

} // namespace ponynav
