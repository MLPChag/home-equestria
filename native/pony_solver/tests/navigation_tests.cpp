// Standalone algorithm tests for the native navigation core (no Godot). They build from the
// same sources as the GDExtension: see build_navigation_tests.sh next to this file.
// Each test answers a behaviour question; costs are compared against an independent Dijkstra
// written here from the walk_planner.gd edge and cost rules.
#include "navigation_jobs.h"

#include <cstdio>
#include <functional>
#include <map>
#include <queue>
#include <set>
#include <thread>

using namespace ponynav;

namespace {

int failures = 0;
int checks = 0;

#define CHECK(condition, label)                                                    \
	do {                                                                           \
		++checks;                                                                  \
		if (!(condition)) {                                                        \
			++failures;                                                            \
			std::printf("  FAIL %s (%s:%d)\n", label, __FILE__, __LINE__);        \
		}                                                                          \
	} while (0)

void section(const char *name) {
	std::printf("[%s]\n", name);
}

using CellFn = std::function<std::vector<SpanInput>(int32_t, int32_t)>;

SpanInput floor_at(float y) {
	SpanInput span;
	span.floor_y = y;
	span.headroom = std::numeric_limits<float>::infinity();
	return span;
}

SpanInput wall_at(float y) {
	SpanInput span = floor_at(y);
	span.headroom = 0.0f; // the sampler's foot-band volume test marks walls this way
	return span;
}

std::shared_ptr<GroundChunk> make_chunk(const ChunkKey &key, const CellFn &cells) {
	std::vector<uint32_t> offsets(size_t(CHUNK_COLUMNS) + 1);
	std::vector<SpanInput> spans;
	for (int32_t column = 0; column < CHUNK_COLUMNS; ++column) {
		offsets[size_t(column)] = uint32_t(spans.size());
		const int32_t x = key.x * CHUNK_CELLS + column % CHUNK_CELLS;
		const int32_t z = key.z * CHUNK_CELLS + column / CHUNK_CELLS;
		for (const SpanInput &span : cells(x, z)) {
			spans.push_back(span);
		}
	}
	offsets[size_t(CHUNK_COLUMNS)] = uint32_t(spans.size());
	std::string error;
	std::shared_ptr<GroundChunk> chunk = build_chunk_from_columns(key, offsets, spans, error);
	if (!chunk) {
		std::printf("  chunk build error: %s\n", error.c_str());
	}
	return chunk;
}

void fill(NavigationWorld &world, int32_t x0, int32_t z0, int32_t x1, int32_t z1, const CellFn &cells) {
	for (int32_t cz = z0; cz <= z1; ++cz) {
		for (int32_t cx = x0; cx <= x1; ++cx) {
			ChunkKey key;
			key.x = cx;
			key.z = cz;
			world.publish(make_chunk(key, cells));
		}
	}
}

Vec3f centre(int32_t x, int32_t z, float y) {
	return Vec3f(float((double(x) + .5) * CELL), y, float((double(z) + .5) * CELL));
}

GroundProfile pony() {
	return GroundProfile();
}

SearchOutput search(NavigationWorld &world, const GroundProfile &profile, const Vec3f &from, const Vec3f &to,
		const SearchOptions &options = SearchOptions()) {
	GroundSearch run(world.snapshot(), world.cache(), profile, from, to, options);
	run.run_to_completion();
	return run.output();
}

// Independent reference: plain Dijkstra over the walk_planner.gd edge rules.
double reference_cost(NavigationWorld &world, const GroundProfile &profile, const CellKey &start_key,
		const CellKey &goal_key, bool &reached) {
	reached = false;
	GroundAccess ground(world.snapshot(), nullptr, profile);
	const Handle start = ground.find(start_key);
	const Handle goal = ground.find(goal_key);
	if (start == NO_HANDLE || goal == NO_HANDLE) {
		return INF;
	}
	std::unordered_map<Handle, double> best;
	using Item = std::pair<double, Handle>;
	std::priority_queue<Item, std::vector<Item>, std::greater<Item>> open;
	best[start] = 0.0;
	open.push(Item(0.0, start));
	auto room = [&ground](Handle handle) { return ground.pure_room(handle); };
	while (!open.empty()) {
		const Item item = open.top();
		open.pop();
		if (item.first > best[item.second]) {
			continue;
		}
		if (item.second == goal) {
			reached = true;
			return item.first;
		}
		const FloorSpan &source = ground.span(item.second);
		if (!ground.allowed(source)) {
			continue;
		}
		int32_t x = 0;
		int32_t z = 0;
		ground.cell(item.second, x, z);
		for (int dir = 0; dir < 8; ++dir) {
			const GroundAccess::Column column = ground.column(x + DIR_X[dir], z + DIR_Z[dir]);
			for (uint32_t i = 0; i < column.count; ++i) {
				const Handle next = make_handle(uint32_t(column.chunk), column.first + i);
				const FloorSpan &dest = ground.span(next);
				if (!ground.edge(source, x, z, dir, next, dest, room)) {
					continue;
				}
				const double weight = GroundAccess::direction_distance(dir) * (1.0 + double(dest.slope_deg) / 45.0) *
						(1.0 + 4.0 * double(dest.water_depth) / ground.wade_floor()) * span_paint(dest);
				const double score = item.first + weight;
				const auto known = best.find(next);
				if (known == best.end() || score < known->second) {
					best[next] = score;
					open.push(Item(score, next));
				}
			}
		}
	}
	return INF;
}

bool near(double a, double b) {
	return std::fabs(a - b) <= 1e-9 * std::max(1.0, std::fabs(b));
}

// Walls around the chunk's outer four cells keep the walkable area off unsampled borders.
bool border(int32_t x, int32_t z) {
	const int32_t lx = positive_mod(x, CHUNK_CELLS);
	const int32_t lz = positive_mod(z, CHUNK_CELLS);
	return lx < 4 || lx > 59 || lz < 4 || lz > 59;
}

struct Lcg {
	uint64_t state;
	explicit Lcg(uint64_t seed) :
			state(seed) {}
	uint32_t next() {
		state = state * 6364136223846793005ull + 1442695040888963407ull;
		return uint32_t(state >> 33);
	}
	double unit() { return double(next()) / 2147483648.0; }
};

uint32_t hash_cell(int32_t x, int32_t z, uint32_t salt) {
	uint32_t h = uint32_t(x) * 73856093u ^ uint32_t(z) * 19349663u ^ salt * 83492791u;
	h ^= h >> 13;
	h *= 1274126177u;
	h ^= h >> 16;
	return h;
}

// ---------------------------------------------------------------------------------------------

void test_coordinates() {
	section("floor division, positive modulo and negative coordinates");
	CHECK(floor_div(-1, 64) == -1, "cell -1 is in chunk -1");
	CHECK(floor_div(-64, 64) == -1, "cell -64 is in chunk -1");
	CHECK(floor_div(-65, 64) == -2, "cell -65 is in chunk -2");
	CHECK(floor_div(63, 64) == 0 && floor_div(64, 64) == 1 && floor_div(0, 64) == 0, "positive cells");
	CHECK(positive_mod(-1, 64) == 63 && positive_mod(-64, 64) == 0 && positive_mod(-65, 64) == 63, "negative local columns");
	CHECK(positive_mod(65, 64) == 1, "positive local column");
	CHECK(cell_coord(-0.1) == -1, "X = -0.1 m is cell -1, not 0");
	CHECK(cell_coord(0.0) == 0 && cell_coord(0.24) == 0, "cell 0");
	CHECK(cell_coord(-0.25) == -1 && cell_coord(-0.26) == -2, "cell boundaries below zero");
	const ChunkKey a = ChunkKey::of_cell(-1, -1);
	CHECK(a.x == -1 && a.z == -1, "chunk of cell (-1, -1)");
	const ChunkKey b = ChunkKey::of_cell(-65, 64);
	CHECK(b.x == -2 && b.z == 1, "chunk of cell (-65, 64)");
	CHECK(local_column(-1, -1) == 63 * 64 + 63, "local column of cell (-1, -1)");
	CHECK(local_column(64, 1) == 64, "local column of cell (64, 1)");
	ChunkKey c;
	c.x = -7;
	c.z = 123456;
	CHECK(ChunkKey::from_packed(c.packed()) == c, "chunk key packing keeps negative coordinates");
}

void test_legacy_conversion() {
	section("walk_chunk.gd arrays convert once into CSR column offsets");
	std::vector<float> floor_y(LEGACY_SLOTS, NAN), water(LEGACY_SLOTS, 0.0f), headroom(LEGACY_SLOTS, INFINITY);
	std::vector<uint8_t> slope(LEGACY_SLOTS, 0), flags(LEGACY_SLOTS, 0), paint(CHUNK_COLUMNS, 50);
	std::vector<uint8_t> trail = { 255, 7, 0, 0 }; // shorter than the slots (old cache file)
	// column 0: deck over river bed; column 2: only slot 1 (kept as slot 1); column 4095: one floor.
	floor_y[0] = 1.0f;
	flags[0] = FLAG_SOLID;
	floor_y[1] = -0.5f;
	flags[1] = FLAG_SOLID | FLAG_WATER;
	water[1] = 0.8f;
	headroom[1] = 1.4f;
	floor_y[5] = 2.0f;
	flags[5] = FLAG_SOLID | FLAG_PAINT_TRAIL;
	paint[2] = 30;
	floor_y[4095 * 2] = 3.0f;
	flags[4095 * 2] = FLAG_SOLID;
	slope[4095 * 2] = 12;
	std::string error;
	ChunkKey key;
	key.x = -3;
	key.z = 2;
	auto chunk = build_chunk_from_legacy(key, floor_y.data(), floor_y.size(), slope.data(), slope.size(), water.data(),
			water.size(), headroom.data(), headroom.size(), flags.data(), flags.size(), paint.data(), paint.size(),
			trail.data(), trail.size(), error);
	CHECK(chunk != nullptr, "conversion succeeds");
	if (!chunk) {
		return;
	}
	CHECK(chunk->span_count() == 4, "only SOLID slots become spans");
	CHECK(chunk->column_offsets[0] == 0 && chunk->column_offsets[1] == 2 && chunk->column_offsets[2] == 2 &&
					chunk->column_offsets[3] == 3 && chunk->column_offsets[4095] == 3 && chunk->column_offsets[4096] == 4,
			"column offsets");
	CHECK(chunk->spans[0].slot() == 0 && chunk->spans[1].slot() == 1 && chunk->spans[2].slot() == 1,
			"slot order kept, a lone slot 1 stays slot 1");
	CHECK(chunk->spans[0].column() == 0 && chunk->spans[2].column() == 2 && chunk->spans[3].column() == 4095,
			"surface ids name the column");
	CHECK(chunk->spans[0].trail_byte == 255 && chunk->spans[1].trail_byte == 7 && chunk->spans[2].trail_byte == 0,
			"short trail arrays read as 0 past their end");
	CHECK(near(span_paint(chunk->spans[0]), 1.0 * (1.0 + (0.6 - 1.0) * 1.0)), "a full terrain trail discounts paint by 40 %");
	CHECK(near(span_paint(chunk->spans[2]), 30.0 / 50.0) && span_trail(chunk->spans[2]) == 1.0,
			"a painted trail is a full trail and keeps its paint");
	CHECK(near(chunk->cost_floor, 0.6), "chunk cost floor is the cheapest span");
	std::vector<uint8_t> short_flags(10, 0);
	auto bad = build_chunk_from_legacy(key, floor_y.data(), floor_y.size(), slope.data(), slope.size(), water.data(),
			water.size(), headroom.data(), headroom.size(), short_flags.data(), short_flags.size(), paint.data(),
			paint.size(), nullptr, 0, error);
	CHECK(bad == nullptr && !error.empty(), "wrong array sizes are rejected");
}

void test_known_costs() {
	section("A* finds analytically known costs (straight, diagonal, discounted trail)");
	NavigationWorld open(1);
	fill(open, 0, 0, 0, 0, [](int32_t x, int32_t z) {
		return std::vector<SpanInput>{ border(x, z) ? wall_at(0.0f) : floor_at(0.0f) };
	});
	SearchOutput straight = search(open, pony(), centre(10, 10, 0.0f), centre(30, 10, 0.0f));
	CHECK(straight.status == RouteStatus::COMPLETE, "straight route completes");
	CHECK(near(straight.raw_cost, 20 * 0.25), "20 cells east cost 5.0");
	CHECK(straight.raw_cells.size() == 21, "straight route visits 21 cells");
	SearchOutput diagonal = search(open, pony(), centre(10, 10, 0.0f), centre(30, 30, 0.0f));
	CHECK(diagonal.status == RouteStatus::COMPLETE && near(diagonal.raw_cost, 20 * GroundAccess::direction_distance(4)),
			"20 diagonal cells cost 20 * sqrt(2) * 0.25 (single-precision length)");
	CHECK(!straight.path.empty() && straight.path.size() <= straight.raw_cells.size(), "smoothed path is not longer than the cells");

	NavigationWorld road(2);
	fill(road, 0, 0, 0, 0, [](int32_t x, int32_t z) {
		SpanInput span = border(x, z) ? wall_at(0.0f) : floor_at(0.0f);
		if (z >= 22 && z <= 24 && x >= 8 && x <= 52) {
			span.trail_byte = 255;
		}
		return std::vector<SpanInput>{ span };
	});
	SearchOutput via_road = search(road, pony(), centre(10, 19, 0.0f), centre(50, 19, 0.0f));
	bool reached = false;
	const double expected = reference_cost(road, pony(), via_road.start, via_road.goal, reached);
	CHECK(via_road.status == RouteStatus::COMPLETE && reached, "road route completes");
	CHECK(near(via_road.raw_cost, expected), "road route cost equals independent Dijkstra");
	CHECK(via_road.raw_cost < 40 * 0.25, "discounted trail beats the straight line");
	bool on_road = false;
	for (const CellKey &cell : via_road.raw_cells) {
		on_road = on_road || (cell.z >= 22 && cell.z <= 24);
	}
	CHECK(on_road, "route uses the trail");
	SearchOptions reference;
	reference.dijkstra = true;
	SearchOutput dijkstra = search(road, pony(), centre(10, 19, 0.0f), centre(50, 19, 0.0f), reference);
	CHECK(near(dijkstra.raw_cost, via_road.raw_cost), "zero-heuristic search gives the same cost");
	CHECK(via_road.expanded <= dijkstra.expanded, "admissible heuristic expands no more than Dijkstra here");
}

void test_bridge_over_floor() {
	section("bridge deck over a river bed and over a dry floor (negative chunk)");
	// Chunk (-1, -1): cells x, z in [-64, -1]. Local lx = x + 64.
	NavigationWorld river(3);
	fill(river, -1, -1, -1, -1, [](int32_t x, int32_t z) {
		const int32_t lx = x + 64;
		const int32_t lz = z + 64;
		if (border(x, z)) {
			return std::vector<SpanInput>{ wall_at(0.0f) };
		}
		if (lz >= 20 && lz < 44) {
			SpanInput bed = floor_at(-1.0f);
			bed.water_depth = 1.0f;
			bed.flags |= FLAG_WATER;
			if (lx >= 28 && lx < 36) {
				bed.headroom = 1.0f;
				return std::vector<SpanInput>{ floor_at(0.05f), bed };
			}
			return std::vector<SpanInput>{ bed };
		}
		return std::vector<SpanInput>{ floor_at(0.0f) };
	});
	SearchOutput crossing = search(river, pony(), centre(32 - 64, 8 - 64, 0.0f), centre(32 - 64, 56 - 64, 0.0f));
	CHECK(crossing.status == RouteStatus::COMPLETE, "route crosses the river");
	bool deck_only = true;
	int over_river = 0;
	for (const CellKey &cell : crossing.raw_cells) {
		const int32_t lz = cell.z + 64;
		if (lz >= 20 && lz < 44) {
			++over_river;
			deck_only = deck_only && cell.slot == 0;
		}
	}
	CHECK(over_river >= 24 && deck_only, "every river cell of the route is on the deck span");
	bool path_on_deck = true;
	for (const Vec3f &point : crossing.path) {
		const int32_t lz = cell_coord(double(point.z)) + 64;
		if (lz >= 20 && lz < 44) {
			path_on_deck = path_on_deck && std::fabs(point.y - 0.05f) < 1e-4f;
		}
	}
	CHECK(path_on_deck, "smoothed route stays at deck height over the river");
	bool reached = false;
	const double bridge_reference = reference_cost(river, pony(), crossing.start, crossing.goal, reached);
	if (!near(crossing.raw_cost, bridge_reference) || !reached) {
		std::printf("  bridge cost %.12f reference %.12f reached %d start (%d,%d,%d) goal (%d,%d,%d) cells %zu\n",
				crossing.raw_cost, bridge_reference, int(reached), crossing.start.x, crossing.start.slot, crossing.start.z,
				crossing.goal.x, crossing.goal.slot, crossing.goal.z, crossing.raw_cells.size());
	}
	CHECK(near(crossing.raw_cost, bridge_reference) && reached, "bridge route cost equals independent Dijkstra");

	NavigationWorld overpass(4);
	fill(overpass, -1, -1, -1, -1, [](int32_t x, int32_t z) {
		const int32_t lx = x + 64;
		const int32_t lz = z + 64;
		if (border(x, z)) {
			return std::vector<SpanInput>{ wall_at(0.0f) };
		}
		if (lx >= 28 && lx < 36 && lz >= 20 && lz < 44) {
			SpanInput ground = floor_at(0.0f);
			ground.headroom = 2.9f;
			return std::vector<SpanInput>{ floor_at(3.0f), ground };
		}
		return std::vector<SpanInput>{ floor_at(0.0f) };
	});
	SearchOutput under = search(overpass, pony(), centre(32 - 64, 8 - 64, 0.0f), centre(32 - 64, 56 - 64, 0.0f));
	bool ground_only = true;
	for (const CellKey &cell : under.raw_cells) {
		const int32_t lx = cell.x + 64;
		const int32_t lz = cell.z + 64;
		if (lx >= 28 && lx < 36 && lz >= 20 && lz < 44) {
			ground_only = ground_only && cell.slot == 1;
		}
	}
	CHECK(under.status == RouteStatus::COMPLETE && ground_only, "route under the deck keeps the ground span");
	CHECK(near(under.raw_cost, 48 * 0.25), "straight route under the deck costs 12.0");
	SearchOutput onto = search(overpass, pony(), centre(32 - 64, 8 - 64, 0.0f), centre(32 - 64, 32 - 64, 3.0f));
	CHECK(onto.goal.valid() && onto.goal.slot == 0, "a goal at deck height selects the deck span, not the ground below");
	CHECK(onto.status == RouteStatus::UNREACHABLE && onto.frontier.empty(),
			"an unconnected deck is unreachable after exhausting the known graph");
}

void test_three_floors() {
	section("three stacked floors with a stair (negative chunk)");
	// Chunk (-1, 0): x in [-64, -1], z in [0, 63]. A plate (lx, lz in [10, 40)) holds floors at
	// 3.0, 1.5 and 0.0. A stair (lz 10..13, lx 40..57) climbs 0.1 per cell from 1.6 to a 3.0
	// landing, and a walkway at 3.0 (lz 14..17, lx 40..57) leads back to the top floor.
	NavigationWorld building(5);
	fill(building, -1, 0, -1, 0, [](int32_t x, int32_t z) {
		const int32_t lx = x + 64;
		const int32_t lz = z;
		if (border(x, z)) {
			return std::vector<SpanInput>{ wall_at(0.0f) };
		}
		if (lx >= 10 && lx < 40 && lz >= 10 && lz < 40) {
			SpanInput middle = floor_at(1.5f);
			middle.headroom = 1.45f;
			SpanInput ground = floor_at(0.0f);
			ground.headroom = 1.45f;
			return std::vector<SpanInput>{ floor_at(3.0f), middle, ground };
		}
		if (lx >= 40 && lx <= 57 && lz >= 10 && lz <= 13) {
			return std::vector<SpanInput>{ floor_at(float(std::min(3.0, 1.6 + 0.1 * double(lx - 40)))) };
		}
		if (lx >= 40 && lx <= 57 && lz >= 14 && lz <= 17) {
			return std::vector<SpanInput>{ floor_at(3.0f) };
		}
		return std::vector<SpanInput>{ floor_at(0.0f) };
	});
	std::shared_ptr<const Snapshot> snapshot = building.snapshot();
	const GroundChunk &chunk = *snapshot->chunks[0];
	const int32_t plate_column = 25 * 64 + 25;
	CHECK(chunk.column_end(plate_column) - chunk.column_begin(plate_column) == 3, "a plate column holds three spans");
	CHECK(chunk.spans[chunk.column_begin(plate_column)].floor_y == 3.0f &&
					chunk.spans[chunk.column_begin(plate_column) + 2].slot() == 2,
			"spans are highest first with slots 0..2");
	CHECK(chunk.max_column_spans == 3, "the chunk records three floors in one column");
	SearchOutput up = search(building, pony(), centre(25 - 64, 25, 1.5f), centre(25 - 64, 25, 3.0f));
	CHECK(up.status == RouteStatus::COMPLETE, "middle floor reaches the top floor at the same X/Z");
	CHECK(up.start.slot == 1 && up.goal.slot == 0, "start on the middle span, goal on the top span");
	bool used_stair = false;
	for (const CellKey &cell : up.raw_cells) {
		used_stair = used_stair || (cell.x + 64 >= 40 && cell.z >= 10 && cell.z <= 13);
	}
	CHECK(used_stair, "the route climbs the stair");
	CHECK(!up.path.empty() && std::fabs(up.path.back().y - 3.0f) < 1e-4f, "the route ends at top-floor height");
	bool reached = false;
	CHECK(near(up.raw_cost, reference_cost(building, pony(), up.start, up.goal, reached)) && reached,
			"stacked-floor route cost equals independent Dijkstra");
	SearchOutput down = search(building, pony(), centre(25 - 64, 25, 1.5f), centre(25 - 64, 25, 0.0f));
	CHECK(down.goal.slot == 2 && down.status == RouteStatus::UNREACHABLE,
			"the ground floor under the plate is a separate, unconnected surface");
}

void test_random_vs_dijkstra() {
	section("random terrain: A* cost and reachability equal independent Dijkstra");
	for (int variant = 0; variant < 2; ++variant) {
		NavigationWorld world(uint32_t(10 + variant));
		const uint32_t salt = 17u + uint32_t(variant) * 101u;
		const int32_t cx = variant == 0 ? 0 : -1;
		const int32_t cz = variant == 0 ? 0 : -2;
		fill(world, cx, cz, cx, cz, [salt](int32_t x, int32_t z) {
			if (border(x, z)) {
				return std::vector<SpanInput>{ wall_at(0.0f) };
			}
			const uint32_t h = hash_cell(x, z, salt);
			// Steps up to 0.09 m (below the 0.117 m step), a few steeper ramps, walls, shallow
			// and deep water, paint and trails: most cells keep body room, some do not.
			SpanInput span = floor_at(float(0.03 * double((h >> 3) % 4)));
			if ((h % 100) < 4) {
				span.headroom = 0.0f; // wall
			}
			span.slope_deg = uint8_t((h >> 8) % 37);
			if (((h >> 14) % 10) == 0) {
				span.water_depth = float(double((h >> 18) % 45) / 100.0);
			}
			span.paint_byte = uint8_t(30 + (h >> 20) % 90);
			span.trail_byte = uint8_t(((h >> 24) % 3) * 127);
			if (((h >> 27) % 13) == 0) {
				span.flags |= FLAG_PAINT_TRAIL;
			}
			std::vector<SpanInput> spans;
			if (((h >> 29) % 7) == 0) {
				SpanInput deck = floor_at(span.floor_y + 2.0f);
				deck.slope_deg = 3;
				span.headroom = std::min(span.headroom, 1.9f);
				spans.push_back(deck);
			}
			spans.push_back(span);
			return spans;
		});
		Lcg random(1234 + uint64_t(variant));
		int compared = 0;
		int reachable = 0;
		int mismatches = 0;
		// Actual-floor starts correctly classify more random wall-adjacent cells as cramped.
		// Sample more endpoints; preserve the independent oracle and coverage minimum.
		for (int trial = 0; trial < 120; ++trial) {
			const int32_t x0 = cx * 64 + 5 + int32_t(random.next() % 54);
			const int32_t z0 = cz * 64 + 5 + int32_t(random.next() % 54);
			const int32_t x1 = cx * 64 + 5 + int32_t(random.next() % 54);
			const int32_t z1 = cz * 64 + 5 + int32_t(random.next() % 54);
			const SearchOutput result = search(world, pony(), centre(x0, z0, 0.1f), centre(x1, z1, 0.1f));
			if (result.status == RouteStatus::NO_FLOOR || result.start_cramped || result.goal_count != 1) {
				continue;
			}
			bool reached = false;
			const double expected = reference_cost(world, pony(), result.start, result.goal, reached);
			++compared;
			reachable += reached ? 1 : 0;
			const bool same_reach = reached == (result.status == RouteStatus::COMPLETE);
			const bool same_cost = !reached || near(result.raw_cost, expected);
			const bool truthful = reached || result.status == RouteStatus::UNREACHABLE;
			if (!same_reach || !same_cost || !truthful) {
				++mismatches;
				std::printf("  mismatch trial %d: status %s cost %.12f expected %.12f\n", trial,
						status_name(result.status), result.raw_cost, expected);
			}
		}
		std::printf("  variant %d: %d routes compared, %d reachable\n", variant, compared, reachable);
		CHECK(compared >= 30 && reachable >= 10, "enough random routes were compared");
		CHECK(mismatches == 0, "every random route matches Dijkstra in reachability and cost");
	}
}

void test_unreachable_and_frontier() {
	section("unreachable only after exhausting the known graph; missing chunks wait for geometry");
	NavigationWorld world(20);
	const CellFn cells = [](int32_t x, int32_t z) {
		const int32_t lx = positive_mod(x, 64);
		const int32_t lz = positive_mod(z, 64);
		const bool west_chunk = x < 64;
		if (lz < 4 || lz > 59 || (west_chunk && lx < 4)) {
			return std::vector<SpanInput>{ wall_at(0.0f) };
		}
		// A walled box in the west chunk (cells 20..30).
		if (west_chunk && lx >= 20 && lx <= 30 && lz >= 20 && lz <= 30 && (lx == 20 || lx == 30 || lz == 20 || lz == 30)) {
			return std::vector<SpanInput>{ wall_at(0.0f) };
		}
		return std::vector<SpanInput>{ floor_at(0.0f) };
	};
	fill(world, 0, 0, 1, 0, cells);
	SearchOutput boxed = search(world, pony(), centre(10, 40, 0.0f), centre(25, 25, 0.0f));
	CHECK(boxed.status == RouteStatus::WAITING_FOR_GEOMETRY, "an open edge toward a missing chunk is not unreachable");
	bool east = false;
	for (const ChunkKey &key : boxed.frontier) {
		east = east || (key.x == 2 && key.z == 0);
	}
	CHECK(east, "the frontier names the missing east chunk");
	ChunkKey closed;
	closed.x = 2;
	closed.z = 0;
	world.publish(make_chunk(closed, [](int32_t, int32_t) { return std::vector<SpanInput>{ wall_at(0.0f) }; }));
	SearchOutput sealed = search(world, pony(), centre(10, 40, 0.0f), centre(25, 25, 0.0f));
	CHECK(sealed.status == RouteStatus::UNREACHABLE && sealed.frontier.empty(),
			"after the frontier chunk arrives walled, the box is certified unreachable");
	SearchOutput nowhere = search(world, pony(), centre(10, 40, 0.0f), centre(10, 40 + 64 * 4, 0.0f));
	CHECK(nowhere.status == RouteStatus::NO_FLOOR, "a destination outside the known ground has no floor");
	SearchOptions partial;
	partial.expansion_limit = 40;
	partial.allow_partial = true;
	SearchOutput prefix = search(world, pony(), centre(10, 40, 0.0f), centre(100, 40, 0.0f), partial);
	CHECK(prefix.status == RouteStatus::PARTIAL && prefix.limited_by == RouteStatus::BUDGET_EXHAUSTED,
			"a budget-limited search may return a partial prefix");
	CHECK(prefix.path.empty() && !prefix.partial_path.empty(), "a partial prefix is never the route itself");
	partial.allow_partial = false;
	SearchOutput budget = search(world, pony(), centre(10, 40, 0.0f), centre(100, 40, 0.0f), partial);
	CHECK(budget.status == RouteStatus::BUDGET_EXHAUSTED && budget.expanded == 40,
			"the expansion cap ends as budget exhausted, not unreachable");
}

void test_coarse_components() {
	section("component/portal corridor over 25 chunks, islands and certified outcomes");
	NavigationWorld world(30);
	// 5 x 5 chunks (320 x 320 cells). A wall along x = 160 with a gap at z 280..290; a walled
	// island in chunk (2, 1); outer walls.
	const CellFn cells = [](int32_t x, int32_t z) {
		if (x < 4 || z < 4 || x > 315 || z > 315) {
			return std::vector<SpanInput>{ wall_at(0.0f) };
		}
		if ((x == 160 || x == 161) && !(z >= 280 && z <= 290)) {
			return std::vector<SpanInput>{ wall_at(0.0f) };
		}
		if (x >= 140 && x <= 150 && z >= 80 && z <= 90 && (x == 140 || x == 150 || z == 80 || z == 90)) {
			return std::vector<SpanInput>{ wall_at(0.0f) };
		}
		return std::vector<SpanInput>{ floor_at(0.0f) };
	};
	fill(world, 0, 0, 4, 4, cells);
	SearchOutput detour = search(world, pony(), centre(20, 20, 0.0f), centre(300, 20, 0.0f));
	CHECK(detour.status == RouteStatus::COMPLETE && detour.corridor_used, "long detour completes through the coarse corridor");
	CHECK(detour.coarse_expanded > 0 && !detour.corridor_widened, "the component corridor held the cell route");
	SearchOptions full;
	full.use_corridor = false;
	SearchOutput exact = search(world, pony(), centre(20, 20, 0.0f), centre(300, 20, 0.0f), full);
	bool reached = false;
	const double expected = reference_cost(world, pony(), exact.start, exact.goal, reached);
	CHECK(exact.status == RouteStatus::COMPLETE && near(exact.raw_cost, expected), "full search equals Dijkstra");
	CHECK(detour.raw_cost >= exact.raw_cost - 1e-9, "corridor route is never cheaper than the optimum");
	std::printf("  corridor cost %.4f, optimum %.4f, expansions %lld vs %lld\n", detour.raw_cost, exact.raw_cost,
			(long long)detour.expanded, (long long)exact.expanded);
	CHECK(detour.raw_cost <= exact.raw_cost * 1.05, "corridor route stays within 5 % of the optimum here");

	GroundAccess ground(world.snapshot(), world.cache(), pony());
	CellKey inside;
	inside.x = 145;
	inside.z = 85;
	inside.slot = 0;
	CellKey outside;
	outside.x = 135;
	outside.z = 85;
	outside.slot = 0;
	const CellReport in = report_cell(ground, inside, true);
	const CellReport out = report_cell(ground, outside, true);
	CHECK(in.component != NO_COMPONENT && out.component != NO_COMPONENT && in.component != out.component,
			"an island and its surroundings in one chunk get separate components");
	SearchOutput island = search(world, pony(), centre(20, 20, 0.0f), centre(145, 85, 0.0f));
	CHECK(island.status == RouteStatus::UNREACHABLE && island.coarse_certified && island.expanded == 0,
			"the component graph certifies the island unreachable without a cell search");
	ChunkKey corner;
	corner.x = 0;
	corner.z = 4;
	world.remove(corner);
	SearchOutput waiting = search(world, pony(), centre(20, 20, 0.0f), centre(145, 85, 0.0f));
	bool names_corner = false;
	for (const ChunkKey &key : waiting.frontier) {
		names_corner = names_corner || key == corner;
	}
	CHECK(waiting.status == RouteStatus::WAITING_FOR_GEOMETRY && names_corner,
			"with a reachable chunk missing the verdict waits for geometry and names it");
}

void test_budget_resume() {
	section("budgeted slices pause and resume to the same result");
	NavigationWorld world(40);
	fill(world, 0, 0, 0, 0, [](int32_t x, int32_t z) {
		const bool wall = border(x, z) || (x == 30 && z < 50) || (z == 30 && x > 12 && x < 30);
		return std::vector<SpanInput>{ wall ? wall_at(0.0f) : floor_at(0.0f) };
	});
	const SearchOutput whole = search(world, pony(), centre(8, 8, 0.0f), centre(55, 10, 0.0f));
	GroundSearch sliced(world.snapshot(), world.cache(), pony(), centre(8, 8, 0.0f), centre(55, 10, 0.0f), SearchOptions());
	int slices = 0;
	RouteStatus status = RouteStatus::PENDING;
	while (status == RouteStatus::PENDING && slices < 100000) {
		status = sliced.advance(37, 0, nullptr);
		++slices;
	}
	CHECK(whole.status == RouteStatus::COMPLETE && status == RouteStatus::COMPLETE, "both runs complete");
	CHECK(slices > 10, "the search paused many times");
	CHECK(sliced.output().raw_cells == whole.raw_cells && sliced.output().raw_cost == whole.raw_cost &&
					sliced.output().expanded == whole.expanded,
			"resumed search returns the same cells, cost and expansions");
	bool same_path = sliced.output().path.size() == whole.path.size();
	for (size_t i = 0; same_path && i < whole.path.size(); ++i) {
		same_path = sliced.output().path[i].x == whole.path[i].x && sliced.output().path[i].y == whole.path[i].y &&
				sliced.output().path[i].z == whole.path[i].z;
	}
	CHECK(same_path, "resumed search returns the same smoothed path");
}

void test_cancellation() {
	section("cancellation is atomic and final");
	NavigationWorld world(50);
	fill(world, 0, 0, 0, 0, [](int32_t x, int32_t z) {
		return std::vector<SpanInput>{ border(x, z) ? wall_at(0.0f) : floor_at(0.0f) };
	});
	std::atomic<bool> cancel{ false };
	GroundSearch run(world.snapshot(), world.cache(), pony(), centre(6, 6, 0.0f), centre(57, 57, 0.0f), SearchOptions());
	CHECK(run.advance(20, 0, &cancel) == RouteStatus::PENDING, "first slice leaves work");
	cancel.store(true);
	CHECK(run.advance(20, 0, &cancel) == RouteStatus::CANCELLED && run.finished(), "the next slice sees the flag");
	CHECK(run.output().path.empty(), "a cancelled search returns no route");
	GroundSearch other(world.snapshot(), world.cache(), pony(), centre(6, 6, 0.0f), centre(57, 57, 0.0f), SearchOptions());
	other.cancel();
	CHECK(other.output().status == RouteStatus::CANCELLED && other.advance(10, 0, nullptr) == RouteStatus::CANCELLED,
			"cancel() before any slice is final");
}

void test_profiles_and_cache() {
	section("clearance cache keyed by the whole movement profile");
	NavigationWorld world(60);
	fill(world, 0, 0, 0, 0, [](int32_t x, int32_t z) {
		const bool wall = border(x, z) || (z == 32 && !(x >= 30 && x <= 31));
		return std::vector<SpanInput>{ wall ? wall_at(0.0f) : floor_at(0.0f) };
	});
	GroundProfile filly = pony();
	filly.radius = 0.2;
	const GroundProfile mare = pony();
	GroundProfile scaled = pony();
	scaled.radius = 0.225;
	scaled.scale = 2.0;
	scaled.step = 0.117 / 2.0;
	scaled.clearance = 0.6;
	const Vec3f from = centre(30, 10, 0.0f);
	const Vec3f to = centre(30, 50, 0.0f);
	const SearchOutput a = search(world, filly, from, to);
	const SearchOutput b = search(world, mare, from, to);
	const SearchOutput c = search(world, filly, from, to);
	CHECK(a.status == RouteStatus::COMPLETE, "a filly fits the two-cell gap");
	CHECK(b.status == RouteStatus::UNREACHABLE, "a mare does not fit the two-cell gap");
	CHECK(c.status == RouteStatus::COMPLETE && c.raw_cost == a.raw_cost, "the mare's answer did not leak into the filly's");
	const size_t layers = world.cache()->layer_count();
	const SearchOutput d = search(world, scaled, from, to);
	CHECK(d.status == RouteStatus::UNREACHABLE, "a half-size profile scaled by 2 behaves like the mare");
	CHECK(world.cache()->layer_count() == layers, "equal effective profiles share cache layers");
	GroundProfile swimmer = mare;
	swimmer.swim = true;
	CHECK(swimmer.signature() != mare.signature() && !swimmer.same(mare), "swim is part of the profile signature");
	GroundProfile masked = mare;
	masked.mask = 3;
	CHECK(masked.signature() != mare.signature(), "the capability mask is part of the profile signature");
}

std::vector<NavResult> wait_results(NavigationService &service, size_t want, int max_ms = 10000) {
	std::vector<NavResult> all;
	for (int waited = 0; waited < max_ms; ++waited) {
		std::vector<NavResult> batch = service.poll();
		all.insert(all.end(), batch.begin(), batch.end());
		if (all.size() >= want && service.pending_jobs() == 0) {
			break;
		}
		std::this_thread::sleep_for(std::chrono::milliseconds(1));
	}
	return all;
}

bool wait_idle(NavigationService &service, int max_ms = 10000) {
	for (int waited = 0; waited < max_ms; ++waited) {
		if (service.queued_jobs() == 0 && service.busy_workers() == 0) {
			return true;
		}
		std::this_thread::sleep_for(std::chrono::milliseconds(1));
	}
	return false;
}

IntentParams intent(uint64_t generation, const Vec3f &from, const Vec3f &goal) {
	IntentParams params;
	params.owner = 7;
	params.generation = generation;
	params.from = from;
	params.goal = goal;
	return params;
}

void test_service_lifecycle() {
	section("actors, intents, stale rejection, coalescing and shutdown");
	NavigationService service(2);
	const uint32_t id = service.create_world();
	NavigationWorld *world = service.world(id);
	const CellFn open = [](int32_t x, int32_t z) {
		return std::vector<SpanInput>{ border(x, z) ? wall_at(0.0f) : floor_at(0.0f) };
	};
	fill(*world, 0, 0, 0, 0, open);
	std::string error;
	ActorHandle actor = service.register_actor(id, pony(), error);
	CHECK(actor.generation == 1 && service.actor_live(actor), "actor registered");
	const Vec3f a = centre(8, 8, 0.0f);
	const Vec3f b = centre(50, 50, 0.0f);
	const Vec3f c = centre(50, 8, 0.0f);

	service.set_paused(true);
	CHECK(service.submit_intent(actor, intent(1, a, b)) == 1, "intent 1 accepted");
	CHECK(service.submit_intent(actor, intent(2, centre(9, 9, 0.0f), b)) == 1, "identical reissue keeps generation 1");
	CHECK(service.counters().idempotent == 1 && service.pending_jobs() == 1, "idempotent reissue starts no job");
	CHECK(service.submit_intent(actor, intent(1, a, c)) == -1, "a non-increasing generation is rejected");
	CHECK(service.submit_intent(actor, intent(3, a, c)) == 3, "intent 3 supersedes intent 1");
	service.set_paused(false);
	std::vector<NavResult> results = wait_results(service, 1);
	CHECK(results.size() == 1 && results[0].intent_generation == 3 && results[0].output.status == RouteStatus::COMPLETE,
			"only the newest intent's route is delivered");
	CHECK(service.counters().cancelled == 1, "the superseded search was cancelled");

	service.set_paused(true);
	CHECK(service.submit_intent(actor, intent(4, a, b)) == 4, "intent 4 accepted");
	ChunkKey origin;
	world->publish(make_chunk(origin, open)); // same content, new revision
	service.set_paused(false);
	results = wait_results(service, 1);
	CHECK(results.size() == 1 && results[0].output.status == RouteStatus::STALE && results[0].output.path.empty(),
			"a route over a republished chunk is delivered as stale, without a path");
	CHECK(service.counters().stale_chunk == 1, "stale chunk counted");

	CHECK(service.submit_intent(actor, intent(5, a, b)) == 5, "intent 5 accepted");
	CHECK(wait_idle(service), "worker finished intent 5");
	CHECK(service.unregister_actor(actor), "actor unregistered");
	results = service.poll();
	CHECK(results.empty() && service.counters().stale_actor == 1, "a finished route for a removed actor is rejected");
	const ActorHandle reused = service.register_actor(id, pony(), error);
	CHECK(reused.slot == actor.slot && reused.generation == actor.generation + 1, "slot reuse bumps the generation");
	CHECK(!service.actor_live(actor) && service.submit_intent(actor, intent(6, a, b)) == -1, "the old handle is dead");
	actor = reused;

	CHECK(service.submit_intent(actor, intent(1, a, b)) == 1, "new actor starts its own generations");
	CHECK(wait_idle(service), "worker finished");
	CHECK(service.submit_intent(actor, intent(2, a, c)) == 2, "intent 2 replaces a finished, unpolled intent 1");
	results = wait_results(service, 1);
	CHECK(results.size() == 1 && results[0].intent_generation == 2, "only intent 2 is delivered");
	CHECK(service.counters().stale_intent == 1, "the finished intent 1 result was rejected as stale");

	service.set_paused(true);
	CHECK(service.submit_intent(actor, intent(3, a, b)) == 3, "intent 3 accepted");
	CHECK(service.cancel_intent(actor, 3), "intent 3 cancelled");
	service.set_paused(false);
	results = wait_results(service, 0, 2000);
	CHECK(results.empty(), "a cancelled intent delivers nothing");

	const uint64_t submitted = service.counters().jobs_submitted;
	const uint64_t coalesced = service.counters().coalesced;
	service.set_paused(true);
	IntentParams follow = intent(4, a, centre(20, 40, 0.0f));
	follow.follow = true;
	CHECK(service.submit_intent(actor, follow) == 4, "follow intent accepted");
	for (int step = 0; step < 100; ++step) {
		service.update_intent_goal(actor, 4, centre(20 + step / 4, 40, 0.0f), a);
	}
	CHECK(service.counters().coalesced - coalesced == 100 && service.pending_jobs() == 1,
			"100 goal updates coalesce into the one search in flight");
	service.set_paused(false);
	results = wait_results(service, 2);
	CHECK(service.counters().jobs_submitted - submitted == 2, "exactly one follow-up search for the newest goal");
	CHECK(results.size() == 2 && results[0].goal_superseded && !results[1].goal_superseded, "both follow results delivered");
	if (results.size() == 2) {
		CHECK(results[1].goal.x == centre(20 + 99 / 4, 40, 0.0f).x, "the follow-up searched the newest goal");
	}

	IntentParams bad = intent(9, a, Vec3f(NAN, 0.0f, 0.0f));
	CHECK(service.submit_intent(actor, bad) == -1, "non-finite goals are rejected at the interface");

	service.set_workers(1);
	CHECK(service.workers() == 1, "worker count configurable down to one");
	CHECK(service.submit_intent(actor, intent(10, a, b)) == 10, "intent accepted with one worker");
	results = wait_results(service, 1);
	CHECK(results.size() == 1 && results[0].output.status == RouteStatus::COMPLETE, "one worker completes the route");

	service.set_paused(true);
	CHECK(service.submit_intent(actor, intent(11, a, b)) == 11, "intent accepted before world destruction");
	CHECK(service.destroy_world(id), "world destroyed while its search is queued");
	service.set_paused(false);
	results = wait_results(service, 0, 2000);
	CHECK(results.empty() && service.pending_jobs() == 0, "nothing is delivered for a destroyed world");

	const uint32_t second = service.create_world();
	fill(*service.world(second), 0, 0, 0, 0, open);
	const ActorHandle other = service.register_actor(second, pony(), error);
	service.set_paused(true);
	for (uint64_t g = 1; g <= 5; ++g) {
		service.submit_intent(other, intent(g, a, g % 2 ? b : c));
	}
	service.shutdown();
	CHECK(true, "shutdown with queued work joins the owned workers");
}

void test_determinism_threads() {
	section("worker results equal the same search on the calling thread");
	NavigationService service(2);
	const uint32_t id = service.create_world();
	NavigationWorld *world = service.world(id);
	fill(*world, 0, 0, 1, 1, [](int32_t x, int32_t z) {
		const uint32_t h = hash_cell(x, z, 5u);
		const bool wall = x < 4 || z < 4 || x > 123 || z > 123 || (h % 100) < 9;
		SpanInput span = wall ? wall_at(0.0f) : floor_at(0.0f);
		span.paint_byte = uint8_t(40 + h % 40);
		return std::vector<SpanInput>{ span };
	});
	std::string error;
	std::vector<ActorHandle> actors;
	std::vector<std::pair<Vec3f, Vec3f>> routes;
	Lcg random(99);
	for (int i = 0; i < 16; ++i) {
		actors.push_back(service.register_actor(id, pony(), error));
		routes.push_back(std::make_pair(centre(6 + int32_t(random.next() % 116), 6 + int32_t(random.next() % 116), 0.0f),
				centre(6 + int32_t(random.next() % 116), 6 + int32_t(random.next() % 116), 0.0f)));
	}
	for (int i = 0; i < 16; ++i) {
		service.submit_intent(actors[size_t(i)], intent(1, routes[size_t(i)].first, routes[size_t(i)].second));
	}
	std::vector<NavResult> results = wait_results(service, 16);
	CHECK(results.size() == 16, "sixteen concurrent searches delivered");
	int same = 0;
	for (const NavResult &result : results) {
		const auto &route = routes[result.actor.slot];
		const SearchOutput direct = search(*world, pony(), route.first, route.second);
		bool equal = direct.status == result.output.status && direct.raw_cells == result.output.raw_cells &&
				direct.raw_cost == result.output.raw_cost && direct.path.size() == result.output.path.size();
		for (size_t p = 0; equal && p < direct.path.size(); ++p) {
			equal = direct.path[p].x == result.output.path[p].x && direct.path[p].z == result.output.path[p].z;
		}
		same += equal ? 1 : 0;
	}
	CHECK(same == 16, "threaded, sliced searches are deterministic");
}

// =============================================================================================
// Phase 2: continuous ground follower (docs/NAVIGATION_PHASE_2_2026_10_02.md)

// The locomotion adapter's native-mode contract in miniature: speed follows the command at the
// profile's acceleration and braking, yaw follows the command's curvature at the executed speed
// (a stepping turn yaws in place), translation and yaw integrate together at the midpoint.
struct Motor {
	Pose2 pose;
	double y = 0.0;
	double v = 0.0;
	double accel = 2.5;
	double braking = 3.5;
	double executed_w = 0.0;

	void apply(const float *command, double dt) {
		double command_v = command[1];
		double command_w = command[2];
		int32_t mode = int32_t(command[3]);
		if (command[0] == 0.0f) {
			command_v = 0.0;
			command_w = 0.0;
			mode = MODE_STOP;
		}
		const double wanted = mode == MODE_STEP_TURN ? 0.0 : std::max(0.0, command_v);
		const double rate = wanted > v ? accel : braking;
		const double next = v + std::max(-rate * dt, std::min(rate * dt, wanted - v));
		double w = 0.0;
		if (mode == MODE_STEP_TURN) {
			w = command_w;
		} else if (command_v > 1e-4) {
			w = command_w / command_v * next;
		}
		pose = advance_midpoint(pose, next, w, dt);
		v = next;
		executed_w = w;
	}
	Vec3f position() const { return Vec3f(float(pose.x), float(y), float(pose.z)); }
	Vec3f velocity() const {
		double fx = 0.0, fz = 0.0;
		forward_of(pose.yaw, fx, fz);
		return Vec3f(float(fx * v), 0.0f, float(fz * v));
	}
};

std::vector<Vec3f> densify(const std::vector<Vec3f> &corners, double step = 0.5) {
	std::vector<Vec3f> out{ corners[0] };
	for (size_t i = 1; i < corners.size(); ++i) {
		const Vec3f a = corners[i - 1];
		const Vec3f b = corners[i];
		const double length = std::hypot(double(b.x - a.x), double(b.z - a.z));
		const int n = std::max(1, int(std::ceil(length / step)));
		for (int k = 1; k <= n; ++k) {
			const float t = float(k) / float(n);
			out.push_back(Vec3f(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t));
		}
	}
	return out;
}

struct FollowRun {
	bool arrived = false;
	int arrivals = 0;
	double arrived_at = INF;
	double miss = INF;
	double longest_unexplained_stop = 0.0;
	double turned = 0.0;
	double turned_moving = 0.0;
	double turned_standing = 0.0;
	double max_lateral_accel = 0.0;
	double max_yaw_rate = 0.0;
	double max_deviation = 0.0;
	double faced_at = INF;
	int stepping = 0;
	int reversing = 0;
	int failed = 0;
	int repairs = 0;
	int replans = 0;
	int alternates = 0;
	bool left_room = false;
	double min_speed_moving = INF;
	std::vector<std::string> events;
};

// Steps one follower through the service with the motor model. `room_check` (optional) is
// called with the actor's position every tick and returns false when she stands where the
// validator would never send her.
FollowRun run_follower(NavigationService &service, const ActorHandle &actor, Motor &motor, double requested,
		double seconds, double face_x, double face_z, const std::function<bool(const Motor &)> &room_check = nullptr,
		double startup = 0.5, const std::function<void(const FollowEvent &, const Motor &)> &on_event = nullptr) {
	FollowRun run;
	const double dt = 1.0 / 60.0;
	std::vector<int64_t> keys{ int64_t(actor.slot), int64_t(actor.generation) };
	std::vector<float> commands;
	std::vector<float> state;
	std::vector<Vec3f> preferred;
	std::vector<float> inputs(INPUT_STRIDE, 0.0f);
	double stop_run = 0.0;
	double previous_yaw = motor.pose.yaw;
	const FollowState *follow = service.follow_state(actor);
	for (double t = 0.0; t < seconds; t += dt) {
		inputs[INPUT_REQUESTED_SPEED] = float(requested);
		inputs[INPUT_EXECUTED_SPEED] = float(motor.v);
		inputs[INPUT_EXECUTED_YAW] = float(motor.executed_w);
		inputs[INPUT_STEP_SECONDS] = float(dt);
		const Vec3f position = motor.position();
		const Vec3f velocity = motor.velocity();
		const float heading = float(motor.pose.yaw);
		std::string error;
		if (!service.follow_step(keys.data(), keys.size(), &position, 1, &velocity, 1, &heading, 1, dt, inputs.data(),
					inputs.size(), commands, state, preferred, error)) {
			std::printf("  step error: %s\n", error.c_str());
			break;
		}
		for (const FollowEvent &event : service.take_follow_events()) {
			run.events.push_back(event.reason);
			if (on_event) {
				on_event(event, motor);
			}
			if (event.kind == EVENT_ARRIVED) {
				++run.arrivals;
				if (!run.arrived) {
					run.arrived = true;
					run.arrived_at = t;
					run.miss = std::hypot(double(event.at.x) - face_x, double(event.at.z) - face_z);
				}
			} else if (event.kind == EVENT_FAILED) {
				++run.failed;
			} else if (event.kind == EVENT_REPAIR) {
				++run.repairs;
			} else if (event.kind == EVENT_REPLAN) {
				++run.replans;
			} else if (event.kind == EVENT_ALTERNATE) {
				++run.alternates;
			}
		}
		const int32_t reason = int32_t(state[5]);
		if (int32_t(commands[3]) == MODE_STEP_TURN) {
			++run.stepping;
		}
		if (reason == REASON_REVERSING) {
			++run.reversing;
		}
		motor.apply(commands.data(), dt);
		if (room_check && !room_check(motor)) {
			run.left_room = true;
		}
		const double turned = std::fabs(wrap_angle(motor.pose.yaw - previous_yaw));
		previous_yaw = motor.pose.yaw;
		run.turned += turned;
		if (motor.v >= 0.05) {
			run.turned_moving += turned;
		} else {
			run.turned_standing += turned;
		}
		run.max_lateral_accel = std::max(run.max_lateral_accel, std::fabs(motor.v * motor.executed_w));
		run.max_yaw_rate = std::max(run.max_yaw_rate, std::fabs(motor.executed_w));
		if (follow != nullptr && follow->last_projection.found) {
			run.max_deviation = std::max(run.max_deviation, follow->last_projection.lateral);
		}
		const double remaining = follow != nullptr ? follow->corridor.length() - follow->s : 0.0;
		const bool counted = t > startup && remaining > 1.0 && !run.arrived;
		if (counted && motor.v < 0.05 && !reason_explains_stop(reason)) {
			stop_run += dt;
			run.longest_unexplained_stop = std::max(run.longest_unexplained_stop, stop_run);
		} else {
			stop_run = 0.0;
		}
		if (counted && motor.v >= 0.05) {
			run.min_speed_moving = std::min(run.min_speed_moving, motor.v);
		}
		if (!std::isfinite(run.faced_at) && follow != nullptr) {
			double tx = 0.0, tz = 0.0;
			follow->corridor.tangent_at(follow->s, tx, tz);
			if (std::fabs(wrap_angle(motor.pose.yaw - yaw_of(tx, tz))) < 30.0 * PI_D / 180.0) {
				run.faced_at = t;
			}
		}
		if (run.arrived && t > run.arrived_at + 1.0) {
			break;
		}
		if (run.failed > 0) {
			break;
		}
	}
	return run;
}

const CellFn flat_floor = [](int32_t, int32_t) { return std::vector<SpanInput>{ floor_at(0.0f) }; };

uint32_t open_world(NavigationService &service, const CellFn &cells = flat_floor) {
	const uint32_t id = service.create_world();
	fill(*service.world(id), -2, -2, 1, 1, cells);
	return id;
}

ActorHandle follower(NavigationService &service, uint32_t world, const SteeringLimits &limits = SteeringLimits()) {
	std::string error;
	const ActorHandle actor = service.register_actor(world, pony(), error);
	service.follow_configure(actor, limits, nullptr);
	return actor;
}

CorridorReply give_corridor(NavigationService &service, const ActorHandle &actor, const std::vector<Vec3f> &points,
		const Motor &motor, uint64_t route, uint64_t intent, bool terminal = true) {
	CorridorRequest request;
	request.points = points;
	request.route = route;
	request.intent = intent;
	request.terminal = terminal;
	request.has_goal = true;
	request.goal = points.back();
	return service.follow_set_corridor(actor, request, motor.position(), motor.pose.yaw, motor.velocity());
}

void test_godot_convention() {
	section("Godot convention: positive yaw turns forward toward world -X, at every heading");
	Pose2 pose;
	double forward = 0.0, left = 0.0;
	const double k = pursuit_curvature(pose, -1.0, -2.0, forward, left);
	CHECK(forward > 0.0 && left > 0.0 && k > 0.0, "yaw 0: a target toward world -X gives a positive curvature");
	CHECK(std::fabs(k - 0.4) < 1e-12, "2 m ahead and 1 m left gives 0.4 per metre");
	CHECK(pursuit_curvature(pose, 1.0, -2.0, forward, left) < 0.0, "yaw 0: a target toward +X turns right");
	const double headings[] = { PI_D * 0.5, PI_D, -PI_D * 0.5, 0.7, -2.3, 3.0 };
	int correct = 0;
	for (double yaw : headings) {
		Pose2 at;
		at.x = 3.0;
		at.z = -4.0;
		at.yaw = yaw;
		double fx = 0.0, fz = 0.0, lx = 0.0, lz = 0.0;
		forward_of(yaw, fx, fz);
		left_of(yaw, lx, lz);
		const double to_left = pursuit_curvature(at, at.x + 2.0 * fx + lx, at.z + 2.0 * fz + lz, forward, left);
		const double to_right = pursuit_curvature(at, at.x + 2.0 * fx - lx, at.z + 2.0 * fz - lz, forward, left);
		// Turning with a positive yaw rate must move her toward that left-hand target.
		Pose2 moved = at;
		for (int i = 0; i < 30; ++i) {
			moved = advance_midpoint(moved, 1.0, 0.4, 1.0 / 60.0);
		}
		const double side = (moved.x - at.x) * lx + (moved.z - at.z) * lz;
		if (std::fabs(to_left - 0.4) < 1e-9 && std::fabs(to_right + 0.4) < 1e-9 && side > 0.0 && moved.yaw != at.yaw) {
			++correct;
		}
	}
	CHECK(correct == 6, "at six other headings: left targets +0.4, right targets -0.4, a positive yaw rate drifts left");
	Pose2 integrated = pose;
	for (int i = 0; i < 60; ++i) {
		integrated = advance_midpoint(integrated, 1.0, 0.4, 1.0 / 60.0);
	}
	const Pose2 exact = arc_pose(pose, 0.4, 1.0);
	CHECK(std::hypot(integrated.x - exact.x, integrated.z - exact.z) < 1e-4 && std::fabs(integrated.yaw - exact.yaw) < 1e-9,
			"midpoint-yaw integration follows the exact arc");
	CHECK(exact.x < 0.0 && exact.yaw > 0.0, "a positive yaw rate at yaw 0 moves her toward world -X");
}

void test_corridor_projection() {
	section("corridor progress: bounded forward window, loops, stacked floors, merged points");
	Corridor hairpin;
	CHECK(hairpin.assign({ Vec3f(0, 0, 0), Vec3f(0, 0, -10), Vec3f(1, 0, -10), Vec3f(1, 0, 0) }), "hairpin built");
	CHECK(std::fabs(hairpin.length() - 21.0) < 1e-9, "hairpin length 21 m");
	const CorridorProjection window = hairpin.project_window(0.6, 0.0, -5.0, 4.5, 0.75, 3.0, 0.65);
	CHECK(window.found && window.segment == 0 && std::fabs(window.s - 5.0) < 1e-9,
			"the forward window keeps her on the outgoing leg beside the return leg");
	const CorridorProjection everything = hairpin.project_all(0.6, 0.0, -5.0, 0.65);
	CHECK(everything.segment == 2, "only a full search would jump to the nearer return leg (recovery only)");
	Corridor stacked;
	stacked.assign({ Vec3f(0, 0, 5), Vec3f(0, 0, -5), Vec3f(5, 1.5f, -5), Vec3f(5, 3, 0), Vec3f(-5, 3, 0) });
	const CorridorProjection lower = stacked.project_all(0.0, 0.0, 0.0, 0.65);
	CHECK(lower.found && lower.segment == 0 && std::fabs(lower.s - 5.0) < 1e-6,
			"a crossing 3 m overhead is not her floor even in a full search");
	const CorridorProjection upper = stacked.project_all(0.0, 3.0, 0.0, 0.65);
	CHECK(upper.found && upper.segment == 3, "on the upper floor the upper crossing is hers");
	Corridor merged;
	merged.assign({ Vec3f(0, 0, 0), Vec3f(0, 0, 0), Vec3f(0, 0, -1), Vec3f(0, 0.2f, -1.0000001f), Vec3f(1, 0, -1) });
	CHECK(merged.size() == 3 && std::fabs(merged.length() - 2.0) < 1e-6, "zero-length segments are merged");
	Corridor corner;
	corner.assign(densify({ Vec3f(0, 0, 0), Vec3f(0, 0, -9), Vec3f(9, 0, -9) }));
	CHECK(std::fabs(corner.absolute_turn(8.0, 10.0) - PI_D * 0.5) < 1e-6, "a right-angle corner turns 90 degrees");
	CHECK(corner.signed_turn(8.0, 10.0) < 0.0, "turning toward +X from -Z is a right turn (negative yaw)");
	CHECK(std::fabs(corner.absolute_turn(0.0, 8.5)) < 1e-9, "no turn before the corner");
}

void test_speed_limits() {
	section("curve, arrival and preview speed limits");
	CHECK(!std::isfinite(curve_speed_limit(0.0, 1.8, 3.0)), "a straight line has no curve limit");
	CHECK(std::fabs(curve_speed_limit(1.0, 1.8, 3.0) - std::sqrt(3.0)) < 1e-12, "k = 1: the lateral limit binds");
	CHECK(std::fabs(curve_speed_limit(2.0, 1.8, 3.0) - 0.9) < 1e-12, "k = 2: the yaw-rate limit binds");
	CHECK(std::fabs(stopping_speed(2.0, 0.0, 3.5) - std::sqrt(14.0)) < 1e-12, "braking curve sqrt(2 b d)");
	Corridor corner;
	corner.assign(densify({ Vec3f(0, 0, 0), Vec3f(0, 0, -20), Vec3f(20, 0, -20) }));
	SteeringLimits limits;
	const double far = preview_speed_limit(corner, 0.0, 3.0, limits);
	const double before = preview_speed_limit(corner, 17.0, 3.0, limits);
	const double nearer = preview_speed_limit(corner, 19.0, 3.0, limits);
	const double at = preview_speed_limit(corner, 20.0, 3.0, limits);
	std::printf("  preview: 20 m before %.2f, 3 m before %.2f, 1 m before %.2f, at the corner %.2f m/s\n", far, before, nearer, at);
	CHECK(far > 3.0, "a corner beyond braking distance does not limit");
	CHECK(before >= nearer && nearer >= at && at < 2.2, "speed falls toward the corner's limit ahead of it");
	CHECK(at > 1.0, "a right-angle corner is still taken at a trot-band speed, not a stop");
}

void test_follow_open_ground() {
	section("real follower runs: 45/90-degree bends and an S-curve keep moving (walk and trot)");
	NavigationService service(1);
	const uint32_t world = open_world(service);
	SteeringLimits limits;
	const ActorHandle actor = follower(service, world, limits);
	struct Shape {
		const char *name;
		std::vector<Vec3f> corners;
	};
	const double r = std::sin(PI_D / 4.0) * 9.0;
	const std::vector<Shape> shapes{
		{ "bend45", { Vec3f(0, 0, 0), Vec3f(0, 0, -9), Vec3f(float(r), 0, float(-9.0 - r)) } },
		{ "bend90", { Vec3f(0, 0, 0), Vec3f(0, 0, -9), Vec3f(9, 0, -9) } },
		{ "s_curve", { Vec3f(0, 0, 0), Vec3f(0, 0, -5), Vec3f(-3.5f, 0, -8.5f), Vec3f(-3.5f, 0, -13.5f), Vec3f(0, 0, -17), Vec3f(0, 0, -22) } },
	};
	uint64_t route = 1;
	for (const Shape &shape : shapes) {
		for (double requested : { 0.33, 2.8 }) {
			std::vector<Vec3f> corners = shape.corners;
			for (Vec3f &corner : corners) {
				corner.x -= 6.0f;
				corner.z += 12.0f;
			}
			const std::vector<Vec3f> course = densify(corners);
			Motor motor;
			motor.pose.x = course[0].x;
			motor.pose.z = course[0].z;
			const CorridorReply reply = give_corridor(service, actor, course, motor, route, route);
			++route;
			Corridor measure;
			measure.assign(course);
			const FollowRun run = run_follower(service, actor, motor, requested, measure.length() / requested + 15.0,
					course.back().x, course.back().z);
			const double share = run.turned > 0.05 ? run.turned_moving / run.turned : 1.0;
			std::printf("  %-8s %.2f m/s: arrived %d at %.1f s, miss %.3f m, unexplained stop %.2f s, turning while moving "
						"%.0f%%, max lateral %.2f m/s2, max yaw %.2f rad/s, max deviation %.2f m, slowest %.2f m/s\n",
					shape.name, requested, run.arrivals, run.arrived_at, run.miss, run.longest_unexplained_stop, share * 100.0,
					run.max_lateral_accel, run.max_yaw_rate, run.max_deviation, run.min_speed_moving);
			CHECK(reply.accepted && reply.goal_appended, "corridor accepted");
			CHECK(run.arrivals == 1 && run.miss <= limits.arrival_radius, "arrives once within 0.25 m");
			CHECK(run.longest_unexplained_stop <= 0.25, "no unexplained stop over 0.25 s");
			CHECK(share >= 0.95, "turns while moving");
			CHECK(run.max_lateral_accel <= limits.lateral_accel * 1.05 + 0.05, "lateral acceleration within the limit");
			CHECK(run.max_yaw_rate <= limits.yaw_rate_max + 1e-6, "yaw rate within the limit");
			CHECK(run.stepping == 0, "no stepping turn on an open bend");
		}
	}
}

void test_follow_reversal() {
	section("reversals: a destination behind her and a U-turn at a trot use a walking arc");
	NavigationService service(1);
	const uint32_t world = open_world(service);
	SteeringLimits limits;
	const ActorHandle actor = follower(service, world, limits);
	for (int scenario = 0; scenario < 2; ++scenario) {
		Motor motor;
		motor.pose.x = 0.0;
		motor.pose.z = -5.0;
		motor.v = scenario == 0 ? 0.0 : 2.5;
		const std::vector<Vec3f> course = densify({ Vec3f(0, 0, -5), Vec3f(0, 0, 15) });
		give_corridor(service, actor, course, motor, uint64_t(10 + scenario), uint64_t(10 + scenario));
		const FollowRun run = run_follower(service, actor, motor, 2.8, 30.0, course.back().x, course.back().z);
		std::printf("  %s: arrived %d at %.1f s, faced the route at %.2f s, turned %.0f deg (%.0f standing), "
					"stepping ticks %d, unexplained stop %.2f s\n",
				scenario == 0 ? "behind, from standstill" : "u-turn at 2.5 m/s", run.arrivals, run.arrived_at, run.faced_at,
				run.turned * 180.0 / PI_D, run.turned_standing * 180.0 / PI_D, run.stepping, run.longest_unexplained_stop);
		CHECK(run.arrivals == 1, "arrives");
		CHECK(run.longest_unexplained_stop <= 0.25, "no unexplained stop");
		CHECK(run.faced_at <= PI_D / limits.yaw_rate_max + 1.5, "faces the route within pi / yaw rate + 1.5 s");
		CHECK(run.turned < 1.5 * PI_D, "no spin");
		CHECK(run.stepping == 0, "open ground uses a walking arc, not a stepping turn");
		CHECK(run.reversing > 0, "the reversal arc was used");
	}
}

// Floor with wall cells (headroom 0) where `wall` says so.
CellFn walled(const std::function<bool(int32_t, int32_t)> &wall) {
	return [wall](int32_t x, int32_t z) {
		return std::vector<SpanInput>{ wall(x, z) ? wall_at(0.0f) : floor_at(0.0f) };
	};
}

void test_follow_walls() {
	section("walls: a bend around an inner corner and a wall across the route");
	{
		// Inner-corner block 0.9 m from both legs of a right-angle bend.
		auto block = [](int32_t x, int32_t z) {
			const double cx = (double(x) + .5) * CELL;
			const double cz = (double(z) + .5) * CELL;
			return cx >= 0.9 && cx <= 6.0 && cz >= -8.1 + 12.0 - 12.0 && cz <= -2.0 && cz >= -8.1;
		};
		NavigationService service(1);
		const uint32_t world = open_world(service, walled(block));
		const ActorHandle actor = follower(service, world);
		GroundAccess ground(service.world(world)->snapshot(), service.world(world)->cache(), pony());
		const std::vector<Vec3f> course = densify({ Vec3f(0, 0, 0), Vec3f(0, 0, -9), Vec3f(9, 0, -9) });
		Motor motor;
		give_corridor(service, actor, course, motor, 1, 1);
		auto room_check = [&ground](const Motor &m) {
			const GroundAccess::Column column = ground.column(cell_coord(m.pose.x), cell_coord(m.pose.z));
			return column.chunk >= 0 && column.count > 0 && ground.pure_room(make_handle(uint32_t(column.chunk), column.first));
		};
		const FollowRun run = run_follower(service, actor, motor, 2.8, 25.0, 9.0, -9.0, room_check);
		std::printf("  inner corner at a trot: arrived %d at %.1f s, unexplained stop %.2f s, left body room %d, slowest %.2f m/s\n",
				run.arrivals, run.arrived_at, run.longest_unexplained_stop, int(run.left_room), run.min_speed_moving);
		CHECK(run.arrivals == 1, "arrives around the corner");
		CHECK(!run.left_room, "never enters a cell without body room (the corner is not cut through the wall)");
		CHECK(run.longest_unexplained_stop <= 0.25, "keeps moving");
	}
	{
		// A wall straight across the route 8 m ahead.
		auto across = [](int32_t, int32_t z) {
			const double cz = (double(z) + .5) * CELL;
			return cz <= -7.5 && cz >= -8.0;
		};
		NavigationService service(1);
		const uint32_t world = open_world(service, walled(across));
		const ActorHandle actor = follower(service, world);
		GroundAccess ground(service.world(world)->snapshot(), service.world(world)->cache(), pony());
		const std::vector<Vec3f> course = densify({ Vec3f(0.1f, 0, 0), Vec3f(0.1f, 0, -15) });
		Motor motor;
		motor.pose.x = 0.1;
		give_corridor(service, actor, course, motor, 1, 1);
		auto room_check = [&ground](const Motor &m) {
			const GroundAccess::Column column = ground.column(cell_coord(m.pose.x), cell_coord(m.pose.z));
			return column.chunk >= 0 && column.count > 0 && ground.pure_room(make_handle(uint32_t(column.chunk), column.first));
		};
		// The navigator answers a replan or an alternate request with a new route; here the search
		// would find the same straight line again (the wall is in the grid), so it is re-sent.
		uint64_t route = 1;
		auto replan = [&](const FollowEvent &event, const Motor &m) {
			if (event.kind == EVENT_REPLAN || event.kind == EVENT_ALTERNATE) {
				give_corridor(service, actor, densify({ Vec3f(float(m.pose.x), 0, float(m.pose.z)), Vec3f(0.1f, 0, -15) }), m,
						++route, 1);
			}
		};
		const FollowRun run = run_follower(service, actor, motor, 2.8, 60.0, 0.1, -15.0, room_check, 0.5, replan);
		std::printf("  wall across the route: stopped at z=%.2f, repairs %d, replans %d, alternates %d, failed %d\n",
				motor.pose.z, run.repairs, run.replans, run.alternates, run.failed);
		for (const std::string &line : run.events) {
			std::printf("    event: %s\n", line.c_str());
		}
		CHECK(run.arrivals == 0, "no false arrival through a wall");
		CHECK(!run.left_room && motor.pose.z > -7.5 + 0.45 - 0.2, "stops before the wall's clearance");
		CHECK(run.repairs >= 1 && run.replans >= 1 && run.alternates >= 1 && run.failed == 1,
				"escalates: local repair, replan, alternate route, one terminal failure");
		// A destination 0.4 m beyond where the wall's clearance stops her: the nearest reachable
		// spot is an arrival reported as a goal-region alternative, not a failure.
		const ActorHandle near_wall = follower(service, world);
		Motor close;
		close.pose.x = 0.1;
		close.pose.z = -4.0;
		give_corridor(service, near_wall, densify({ Vec3f(0.1f, 0, -4), Vec3f(0.1f, 0, -7.6f) }), close, 1, 1);
		const FollowRun short_run = run_follower(service, near_wall, close, 1.0, 20.0, 0.1, -7.6, room_check);
		const FollowState *held = service.follow_state(near_wall);
		std::printf("  destination just past the wall's clearance: arrived %d (alternative %d), failed %d, stopped at z=%.2f\n",
				short_run.arrivals, int(held != nullptr && held->alternative), short_run.failed, close.pose.z);
		CHECK(short_run.arrivals == 1 && short_run.failed == 0 && held != nullptr && held->alternative,
				"held short of an unreachable last step: an alternative arrival");
		CHECK(!short_run.left_room, "without entering the wall's clearance");
	}
}

void test_narrow_ramp_start() {
	section("start on narrow ramp stays on its surface instead of snapping to ground beside it");
	NavigationWorld world(1);
	fill(world, -1, -1, 0, 0, [](int32_t x, int32_t z) {
		const float cz = float((z + .5) * CELL);
		SpanInput span = floor_at(0.0f);
		if ((x == -1 || x == 0) && cz > -2.0f && cz < 2.0f) {
			span.floor_y = (2.0f - cz) * .325f;
			span.slope_deg = 18;
		}
		return std::vector<SpanInput>{span};
	});
	SearchOptions options;
	options.escape_reach = 2.5;
	const SearchOutput route = search(world, pony(), Vec3f(.125f, .65f, .125f), Vec3f(3.0f, 0.0f, 5.0f), options);
	CHECK(route.status == RouteStatus::COMPLETE, "narrow ramp connects to ground via its foot");
	CHECK(route.start_cramped, "ramp start uses connected escape even with nearby roomy ground");
	CHECK(!route.path.empty() && route.path.front().y > .5f, "route starts on supporting ramp surface");
}

void test_cramped_escape() {
	section("cramped start: escape seeds, a supported stepping turn and walking out of a 1 m nook");
	// A nook 1.0 m wide (inner faces x = 0 and 1) and 1.5 m deep (back face z = -1.5), open toward
	// +Z. As the sampler sees it: a cell whose 0.18 m sampling cylinder touches a wall is blocked,
	// so only the two middle columns of the nook are floor and none of them has body room.
	auto nook = [](int32_t x, int32_t z) {
		const double cx = (double(x) + .5) * CELL;
		const double cz = (double(z) + .5) * CELL;
		const double reach = 0.18;
		const bool side = (cx > -0.25 - reach && cx < 0.0 + reach) || (cx > 1.0 - reach && cx < 1.25 + reach);
		const bool back = cx > -0.25 - reach && cx < 1.25 + reach && cz > -1.75 - reach && cz < -1.5 + reach;
		return (side && cz > -1.75 - reach && cz < 0.0 + reach) || back;
	};
	NavigationService service(1);
	const uint32_t world = open_world(service, walled(nook));
	const Vec3f inside(0.5f, 0.0f, -0.75f);
	const Vec3f goal(0.5f, 0.0f, 7.0f);
	SearchOptions plain;
	const SearchOutput without = search(*service.world(world), pony(), inside, goal, plain);
	SearchOptions escape;
	escape.escape_reach = 2.5;
	const SearchOutput with = search(*service.world(world), pony(), inside, goal, escape);
	std::printf("  without escape seeds: %s; with: %s, %zu points\n", status_name(without.status), status_name(with.status),
			with.path.size());
	CHECK(without.status != RouteStatus::COMPLETE, "the legacy seeding cannot leave the deep nook");
	CHECK(with.status == RouteStatus::COMPLETE && with.start_cramped, "escape seeds connect her cell to open ground");
	const ActorHandle actor = follower(service, world);
	Motor motor;
	motor.pose.x = inside.x;
	motor.pose.z = inside.z;
	motor.pose.yaw = 0.0; // facing the back wall (-Z)
	const CorridorReply reply = give_corridor(service, actor, with.path, motor, 1, 1);
	CHECK(reply.accepted && reply.escape_length > 0.5, "the corridor's cramped prefix is relaxed");
	GroundAccess ground(service.world(world)->snapshot(), service.world(world)->cache(), pony());
	auto allowed_floor = [&ground](const Motor &m) {
		const GroundAccess::Column column = ground.column(cell_coord(m.pose.x), cell_coord(m.pose.z));
		return column.chunk >= 0 && column.count > 0 && ground.allowed(ground.span(make_handle(uint32_t(column.chunk), column.first)));
	};
	const FollowRun run = run_follower(service, actor, motor, 0.33, 60.0, goal.x, goal.z, allowed_floor);
	std::printf("  nook: arrived %d at %.1f s, stepping ticks %d, faced the route at %.2f s, turned %.0f deg, left floor %d\n",
			run.arrivals, run.arrived_at, run.stepping, run.faced_at, run.turned * 180.0 / PI_D, int(run.left_room));
	CHECK(run.stepping > 0, "a deliberate stepping turn turns her round where no arc fits");
	CHECK(run.arrivals == 1, "she walks out and arrives");
	CHECK(!run.left_room, "never steps onto a wall cell");
	CHECK(run.turned < 1.5 * PI_D, "no spin");
}

void test_wide_nook() {
	section("1.4 m nook (the travel fixture's cramped_turn): turn round inside, walk out, arrive");
	// Inner faces x = 0 and 1.4, back face z = -0.8, side walls to z = 0.6, sampled with the 0.18 m
	// cylinder (cells touching a wall are blocked). She starts facing the back wall.
	auto nook = [](int32_t x, int32_t z) {
		const double cx = (double(x) + .5) * CELL;
		const double cz = (double(z) + .5) * CELL;
		const double reach = 0.18;
		const bool side = (cx > -0.2 - reach && cx < 0.0 + reach) || (cx > 1.4 - reach && cx < 1.6 + reach);
		const bool back = cx > -0.2 - reach && cx < 1.6 + reach && cz > -1.0 - reach && cz < -0.8 + reach;
		return (side && cz > -1.0 - reach && cz < 0.6 + reach) || back;
	};
	NavigationService service(1);
	const uint32_t world = open_world(service, walled(nook));
	SearchOptions options;
	options.escape_reach = 2.5;
	const Vec3f start(0.7f, 0.0f, 0.0f);
	const Vec3f goal(0.7f, 0.0f, 8.0f);
	const SearchOutput route = search(*service.world(world), pony(), start, goal, options);
	CHECK(route.status == RouteStatus::COMPLETE, "a route out of the nook");
	const ActorHandle actor = follower(service, world);
	GroundAccess ground(service.world(world)->snapshot(), service.world(world)->cache(), pony());
	auto allowed_floor = [&ground](const Motor &m) {
		const GroundAccess::Column column = ground.column(cell_coord(m.pose.x), cell_coord(m.pose.z));
		return column.chunk >= 0 && column.count > 0 && ground.allowed(ground.span(make_handle(uint32_t(column.chunk), column.first)));
	};
	for (int variant = 0; variant < 2; ++variant) {
		Motor motor;
		motor.pose.x = start.x + (variant == 0 ? 0.0 : 0.22);
		motor.pose.z = start.z;
		// Variant 1: stopped beside the room boundary, facing 20 degrees off the way out.
		motor.pose.yaw = variant == 0 ? 0.0 : PI_D - 20.0 * PI_D / 180.0;
		give_corridor(service, actor, route.path, motor, uint64_t(1 + variant), uint64_t(1 + variant));
		const FollowRun run = run_follower(service, actor, motor, 0.33, 60.0, goal.x, goal.z, allowed_floor);
		std::printf("  variant %d: arrived %d at %.1f s, stepping ticks %d, turned %.0f deg, failed %d, left floor %d\n", variant,
				run.arrivals, run.arrived_at, run.stepping, run.turned * 180.0 / PI_D, run.failed, int(run.left_room));
		CHECK(run.arrivals == 1 && run.failed == 0, "she gets out and arrives");
		CHECK(!run.left_room, "never steps onto a wall cell");
		CHECK(run.turned < 1.5 * PI_D, "no spin");
	}
}

void test_corner_with_neighbour() {
	section("crowd at a box corner: started in a corner's clearance with a pony standing close by");
	// A 4 m box x -2..2, z -20..-16 as the sampler sees it (cells whose 0.18 m cylinder touches it).
	auto box = [](int32_t x, int32_t z) {
		const double cx = (double(x) + .5) * CELL;
		const double cz = (double(z) + .5) * CELL;
		const double dx = std::max(std::max(-2.0 - cx, 0.0), cx - 2.0);
		const double dz = std::max(std::max(-20.0 - cz, 0.0), cz + 16.0);
		return std::hypot(dx, dz) < 0.18;
	};
	NavigationService service(1);
	const uint32_t world = open_world(service, walled(box));
	SearchOptions options;
	options.escape_reach = 2.5;
	const Vec3f start(2.35f, 0.0f, -15.65f);
	const Vec3f goal(-6.0f, 0.0f, -10.0f);
	const SearchOutput route = search(*service.world(world), pony(), start, goal, options);
	CHECK(route.status == RouteStatus::COMPLETE, "a route from the corner");
	const ActorHandle actor = follower(service, world);
	Motor motor;
	motor.pose.x = start.x;
	motor.pose.z = start.z;
	motor.pose.yaw = 128.0 * PI_D / 180.0;
	give_corridor(service, actor, route.path, motor, 1, 1);
	// A pony standing 1.3 m away, beside the way out (an observer row: a neighbour, no command).
	const Vec3f standing(3.4f, 0.0f, -14.9f);
	std::vector<int64_t> keys{ actor.slot, actor.generation, -1, 0 };
	std::vector<float> inputs(2 * INPUT_STRIDE, 0.0f);
	std::vector<float> commands, state;
	std::vector<Vec3f> preferred;
	std::string error;
	GroundAccess ground(service.world(world)->snapshot(), service.world(world)->cache(), pony());
	int arrived = 0;
	int failed = 0;
	bool unsafe = false;
	double closest = INF;
	const double dt = 1.0 / 60.0;
	for (double t = 0.0; t < 30.0 && arrived == 0 && failed == 0; t += dt) {
		inputs[INPUT_REQUESTED_SPEED] = 2.5f;
		const Vec3f positions[2] = { motor.position(), standing };
		const Vec3f velocities[2] = { motor.velocity(), Vec3f() };
		const float headings[2] = { float(motor.pose.yaw), 0.0f };
		service.follow_step(keys.data(), 4, positions, 2, velocities, 2, headings, 2, dt, inputs.data(), inputs.size(),
				commands, state, preferred, error);
		motor.apply(commands.data(), dt);
		for (const FollowEvent &event : service.take_follow_events()) {
			arrived += event.kind == EVENT_ARRIVED ? 1 : 0;
			failed += event.kind == EVENT_FAILED ? 1 : 0;
		}
		const GroundAccess::Column column = ground.column(cell_coord(motor.pose.x), cell_coord(motor.pose.z));
		unsafe = unsafe || column.chunk < 0 || column.count == 0 ||
				!ground.allowed(ground.span(make_handle(uint32_t(column.chunk), column.first)));
		closest = std::min(closest, std::hypot(motor.pose.x - standing.x, motor.pose.z - standing.z));
	}
	std::printf("  arrived %d, failed %d, closest to the standing pony %.2f m\n", arrived, failed, closest);
	CHECK(arrived == 1 && failed == 0, "she leaves the corner and arrives despite the neighbour");
	CHECK(!unsafe, "never on a blocked cell");
	CHECK(closest >= 0.5 * (0.45 + 0.45) + 0.1 - 0.02, "keeps the hard separation from the standing pony");

	// At the very edge of the room beside the box (0.56 m off its corner), facing along its face
	// where every short arc toward the route dips into the cells by the wall: a local repair turn.
	const Vec3f edge(2.02f, 0.0f, -15.44f);
	const Vec3f beyond(8.3f, 0.0f, -18.1f);
	const SearchOutput along = search(*service.world(world), pony(), edge, beyond, options);
	const ActorHandle walker = follower(service, world);
	Motor m;
	m.pose.x = edge.x;
	m.pose.z = edge.z;
	m.pose.yaw = -62.0 * PI_D / 180.0;
	give_corridor(service, walker, along.path, m, 1, 1);
	auto on_floor = [&ground](const Motor &state) {
		const GroundAccess::Column column = ground.column(cell_coord(state.pose.x), cell_coord(state.pose.z));
		return column.chunk >= 0 && column.count > 0 && ground.allowed(ground.span(make_handle(uint32_t(column.chunk), column.first)));
	};
	const FollowRun run = run_follower(service, walker, m, 2.5, 20.0, beyond.x, beyond.z, on_floor);
	std::printf("  edge of the room by the corner: arrived %d at %.1f s, failed %d, repairs %d\n", run.arrivals, run.arrived_at,
			run.failed, run.repairs);
	CHECK(run.arrivals == 1 && run.failed == 0, "a local repair turn gets her going along the wall");
	CHECK(!run.left_room, "never on a blocked cell");
}

void test_progress_monitor() {
	section("stall classification and deterministic escalation");
	const double dt = 1.0 / 60.0;
	ProgressMonitor monitor;
	ProgressSample stalled;
	stalled.permitted = 1.0;
	stalled.goal_distance = 10.0;
	std::vector<Escalation> entered;
	double t = 0.0;
	auto step = [&](double seconds, FollowClass klass, const ProgressSample &sample) {
		for (double until = t + seconds; t < until - 1e-9; t += dt) {
			const Escalation e = monitor.update(dt, klass, sample);
			if (e != Escalation::NONE) {
				entered.push_back(e);
			}
		}
	};
	step(3.0, FollowClass::FOLLOWING, stalled);
	CHECK(entered.empty(), "no verdict before 90 % of the stall window was spent following");
	step(1.3, FollowClass::FOLLOWING, stalled);
	CHECK(entered.size() == 1 && entered[0] == Escalation::LOCAL_REPAIR, "a stall starts a local repair");
	step(3.0, FollowClass::FOLLOWING, stalled);
	CHECK(entered.size() == 2 && entered[1] == Escalation::REPLAN && monitor.awaiting_route(),
			"the repair deadline escalates to a replan");
	step(10.0, FollowClass::FOLLOWING, stalled);
	CHECK(entered.size() == 2, "waiting for the replanned route is planning time, not escalation time");
	monitor.corridor_replaced(2);
	step(6.5, FollowClass::FOLLOWING, stalled);
	CHECK(entered.size() == 3 && entered[2] == Escalation::ALTERNATE, "still stalled on the new route: alternate route");
	monitor.corridor_replaced(3);
	step(9.0, FollowClass::FOLLOWING, stalled);
	CHECK(entered.size() == 4 && entered[3] == Escalation::FAILED, "then one terminal failure");
	step(5.0, FollowClass::FOLLOWING, stalled);
	CHECK(entered.size() == 4, "the failure is reported once");

	monitor.reset();
	entered.clear();
	t = 0.0;
	step(4.5, FollowClass::FOLLOWING, stalled);
	ProgressSample moving = stalled;
	moving.gained = 1.2 * dt;
	step(2.5, FollowClass::FOLLOWING, moving);
	CHECK(entered.size() == 1 && monitor.level() == Escalation::NONE, "progress clears a repair");
	const double history = monitor.total_stalled();
	monitor.corridor_replaced(9);
	CHECK(monitor.total_stalled() == history && history > 0.0, "a replacement route keeps the intent's stall history");

	monitor.reset();
	entered.clear();
	t = 0.0;
	step(3.9, FollowClass::TURNING, stalled);
	CHECK(entered.empty() && !monitor.stalled(), "a turn of under 4 s is not a stall");
	step(5.0, FollowClass::TURNING, stalled);
	CHECK(!entered.empty(), "turning on and on (over 4 s) counts as no progress");

	monitor.reset();
	entered.clear();
	t = 0.0;
	step(2.0, FollowClass::YIELDING, stalled);
	CHECK(entered.empty(), "a short yield is not a stall");

	ProgressTuning tuning;
	tuning.repair_seconds = 1000.0;
	monitor.set_tuning(tuning);
	monitor.reset();
	entered.clear();
	t = 0.0;
	tuning.total_stall_limit = 6.0;
	monitor.set_tuning(tuning);
	step(12.0, FollowClass::FOLLOWING, stalled);
	CHECK(!entered.empty() && entered.back() == Escalation::FAILED, "the total stall budget ends the intent");

	ProgressMonitor circle;
	t = 0.0;
	for (int i = 0; i < 600; ++i) {
		ProgressSample sample;
		sample.yaw = wrap_angle(i * dt * 1.2);
		sample.goal_distance = 8.0;
		sample.permitted = 0.0;
		circle.update(dt, FollowClass::FOLLOWING, sample);
	}
	CHECK(circle.circling() && circle.stalled() && std::string(circle.cause()) == "circling", "circling is a stall");
	ProgressMonitor bounce;
	for (int i = 0; i < 300; ++i) {
		ProgressSample sample;
		sample.raw_progress = 2.0 + 0.4 * std::sin(i * dt * 5.0);
		sample.goal_distance = 8.0;
		bounce.update(dt, FollowClass::FOLLOWING, sample);
	}
	CHECK(bounce.oscillating() && bounce.stalled(), "progress bouncing across a point is a stall");
	ProgressMonitor steady;
	for (int i = 0; i < 300; ++i) {
		ProgressSample sample;
		sample.raw_progress = i * dt;
		sample.gained = dt;
		sample.permitted = 1.0;
		sample.goal_distance = 20.0 - i * dt;
		steady.update(dt, FollowClass::FOLLOWING, sample);
	}
	CHECK(!steady.stalled() && !steady.circling() && !steady.oscillating(), "steady progress is not flagged");
}

void test_support_refused_alignment() {
	section("authored passage: motor support refusal realigns before forward travel");
	NavigationService service(1);
	const uint32_t world = open_world(service);
	const ActorHandle actor = follower(service, world);
	const Vec3f at(0, 0, 0), still;
	std::vector<int64_t> keys{ actor.slot, actor.generation };
	std::vector<float> inputs(INPUT_STRIDE, 0.0f), commands, state;
	std::vector<Vec3f> preferred;
	std::string error;
	inputs[INPUT_REQUESTED_SPEED] = 1.2f;
	inputs[INPUT_SPEED_SCALE] = 1.0f;
	uint64_t route = 0;
	for (int refusal : { REFUSAL_SUPPORT, REFUSAL_NONE, REFUSAL_TOUCH, REFUSAL_TURN_SUPPORT }) {
		for (float heading : { 1.040697f, -0.67946f }) {
			CorridorRequest request;
			request.points = { at, Vec3f(0.46551f, 0, -0.57624f), Vec3f(-0.66712f, 0, -1.39914f) };
			request.route = ++route;
			request.intent = route;
			request.authored = true;
			request.has_goal = true;
			request.goal = request.points.back();
			service.follow_set_corridor(actor, request, at, heading, still);
			inputs[INPUT_REFUSAL] = float(refusal);
			CHECK(service.follow_step(keys.data(), keys.size(), &at, 1, &still, 1, &heading, 1,
					1.0 / 60.0, inputs.data(), inputs.size(), commands, state, preferred, error), "support refusal batch accepted");
			const bool should_turn = refusal == REFUSAL_SUPPORT && heading > 0.0f;
			CHECK((int(commands[3]) == MODE_STEP_TURN) == should_turn,
					"only stopped support refusal across the route starts a supported step turn");
			if (should_turn) {
				CHECK(commands[1] == 0.0f && commands[2] < 0.0f, "step toward the route without forward travel");
				inputs[INPUT_REFUSAL] = float(REFUSAL_NONE);
				service.follow_step(keys.data(), keys.size(), &at, 1, &still, 1, &heading, 1,
						1.0 / 60.0, inputs.data(), inputs.size(), commands, state, preferred, error);
				CHECK(int(commands[3]) == MODE_STEP_TURN, "alignment continues when the motor clears forward refusal");
				const float aligned = -0.67946f;
				service.follow_step(keys.data(), keys.size(), &at, 1, &still, 1, &aligned, 1,
						1.0 / 60.0, inputs.data(), inputs.size(), commands, state, preferred, error);
				CHECK(int(commands[3]) == MODE_TRAVEL && commands[1] > 0.0f, "aligned pony resumes ordinary travel");
			}
		}
	}
}

void test_batch_wire_format() {
	section("step_batch wire format, observers, stale actors, NaN rejection and one arrival");
	NavigationService service(1);
	const uint32_t world = open_world(service);
	const ActorHandle a = follower(service, world);
	const ActorHandle b = follower(service, world);
	const ActorHandle gone = follower(service, world);
	service.unregister_actor(gone);
	Motor motor;
	motor.pose.z = 5.0;
	give_corridor(service, a, densify({ Vec3f(0, 0, 5), Vec3f(0, 0, 1) }), motor, 1, 1);
	std::vector<float> commands, state;
	std::vector<Vec3f> preferred;
	std::string error;
	const Vec3f nan(std::nanf(""), 0.0f, 0.0f);
	std::vector<int64_t> keys{ a.slot, a.generation, b.slot, b.generation, -1, 0, gone.slot, gone.generation, a.slot, a.generation };
	std::vector<Vec3f> positions{ motor.position(), Vec3f(3, 0, 3), Vec3f(-3, 0, 3), Vec3f(5, 0, 5), nan };
	std::vector<Vec3f> velocities(5, Vec3f());
	std::vector<float> headings(5, 0.0f);
	CHECK(!service.follow_step(keys.data(), keys.size() - 2, positions.data(), positions.size(), velocities.data(),
				  velocities.size(), headings.data(), headings.size(), 1.0 / 60.0, nullptr, 0, commands, state, preferred, error),
			"mismatched lengths are refused");
	CHECK(commands.size() == 20 && commands[0] == 0.0f, "a refused batch leaves every row invalid");
	std::vector<float> bad_inputs(7, 0.0f);
	CHECK(!service.follow_step(keys.data(), keys.size(), positions.data(), positions.size(), velocities.data(),
				  velocities.size(), headings.data(), headings.size(), 1.0 / 60.0, bad_inputs.data(), bad_inputs.size(),
				  commands, state, preferred, error),
			"an input array of the wrong stride is refused");
	CHECK(!service.follow_step(keys.data(), keys.size(), positions.data(), positions.size(), velocities.data(),
				  velocities.size(), headings.data(), headings.size(), std::nan(""), nullptr, 0, commands, state, preferred,
				  error),
			"a NaN delta is refused");
	CHECK(service.follow_step(keys.data(), keys.size(), positions.data(), positions.size(), velocities.data(),
				  velocities.size(), headings.data(), headings.size(), 1.0 / 60.0, nullptr, 0, commands, state, preferred,
				  error),
			"a well-formed batch steps");
	CHECK(commands[0] == 1.0f && int(commands[3]) == MODE_TRAVEL && commands[1] > 0.0f, "the follower travels");
	CHECK(commands[4] == 0.0f && commands[8] == 0.0f && commands[12] == 0.0f,
			"no corridor, an observer row and a stale actor are invalid rows");
	CHECK(commands[16] == 1.0f && commands[17] == 0.0f && int(commands[19]) == MODE_STOP &&
					int(state[4 * STATE_STRIDE + 5]) == REASON_INVALID_INPUT,
			"NaN input for a navigation-owned actor is a valid stop with a reason");
	const FollowRun run = run_follower(service, a, motor, 1.0, 20.0, 0.0, 1.0);
	CHECK(run.arrivals == 1, "the arrival event is emitted once");
	std::vector<int64_t> one{ a.slot, a.generation };
	const Vec3f here = motor.position();
	const Vec3f still;
	const float heading = float(motor.pose.yaw);
	service.follow_step(one.data(), 2, &here, 1, &still, 1, &heading, 1, 1.0 / 60.0, nullptr, 0, commands, state, preferred, error);
	CHECK(commands[0] == 1.0f && commands[1] == 0.0f && int(commands[3]) == MODE_STOP, "after arrival: a valid stop");
	CHECK(service.take_follow_events().empty(), "no second arrival");
	service.follow_clear(a);
	service.follow_step(one.data(), 2, &here, 1, &still, 1, &heading, 1, 1.0 / 60.0, nullptr, 0, commands, state, preferred, error);
	CHECK(commands[0] == 0.0f, "a cleared follower is an invalid row");
	service.unregister_actor(a);
	const ActorHandle reused = follower(service, world);
	CHECK(reused.slot == a.slot && reused.generation != a.generation, "the slot is reused with a new generation");
	service.follow_step(one.data(), 2, &here, 1, &still, 1, &heading, 1, 1.0 / 60.0, nullptr, 0, commands, state, preferred, error);
	CHECK(commands[0] == 0.0f && service.follow_state(a) == nullptr, "the old generation commands nothing");
}

void test_route_replacement() {
	section("route replacement while moving joins forward and keeps velocity and intent history");
	NavigationService service(1);
	const uint32_t world = open_world(service);
	const ActorHandle actor = follower(service, world);
	Motor motor;
	motor.pose.z = 10.0;
	give_corridor(service, actor, densify({ Vec3f(0, 0, 10), Vec3f(0, 0, -20) }), motor, 1, 1);
	run_follower(service, actor, motor, 2.5, 2.0, 0.0, -20.0);
	const double speed = motor.v;
	const double followed = service.follow_state(actor)->monitor.following_time();
	// The new route was searched from where she was 1 m ago and lies 0.2 m to her side.
	const std::vector<Vec3f> replacement = densify({ Vec3f(0.2f, 0, float(motor.pose.z + 1.0)), Vec3f(5.2f, 0, -20) });
	const CorridorReply reply = give_corridor(service, actor, replacement, motor, 2, 1);
	std::printf("  join at %.2f m (lateral %.2f m), speed %.2f m/s\n", reply.join_s, reply.join_lateral, speed);
	CHECK(reply.accepted && reply.join_s > 0.8 && reply.join_s < 1.3, "joins the new route beside her, not at its start");
	std::vector<float> commands, state;
	std::vector<Vec3f> preferred;
	std::string error;
	std::vector<int64_t> keys{ actor.slot, actor.generation };
	const Vec3f position = motor.position();
	const Vec3f velocity = motor.velocity();
	const float heading = float(motor.pose.yaw);
	std::vector<float> inputs(INPUT_STRIDE, 0.0f);
	inputs[INPUT_REQUESTED_SPEED] = 2.5f;
	service.follow_step(keys.data(), 2, &position, 1, &velocity, 1, &heading, 1, 1.0 / 60.0, inputs.data(), inputs.size(),
			commands, state, preferred, error);
	CHECK(commands[1] >= speed - 3.5 / 60.0 - 1e-3, "her speed carries over (no restart from zero)");
	CHECK(state[0] >= float(reply.join_s) - 1e-3, "progress continues from the join");
	CHECK(service.follow_state(actor)->monitor.following_time() >= followed, "the same intent keeps its history");
	give_corridor(service, actor, replacement, motor, 3, 2);
	CHECK(service.follow_state(actor)->monitor.following_time() < 1e-9, "a new intent starts a fresh history");
}

void test_neighbours_and_avoidance(float pace = 1.2f) {
	section("neighbours and avoidance: head-on traffic passes; zero answers yield with a reason");
	NavigationService service(1);
	const uint32_t world = open_world(service);
	const ActorHandle one = follower(service, world);
	const ActorHandle two = follower(service, world);
	Motor a, b;
	a.pose.z = 10.0;
	b.pose.z = -10.0;
	b.pose.yaw = PI_D;
	give_corridor(service, one, densify({ Vec3f(0, 0, 10), Vec3f(0, 0, -10) }), a, 1, 1);
	give_corridor(service, two, densify({ Vec3f(0, 0, -10), Vec3f(0, 0, 10) }), b, 1, 1);
	std::vector<int64_t> keys{ one.slot, one.generation, two.slot, two.generation };
	std::vector<float> commands, state;
	std::vector<Vec3f> preferred;
	std::vector<float> inputs(2 * INPUT_STRIDE, 0.0f);
	std::string error;
	double closest = INF;
	int arrived = 0;
	const double dt = 1.0 / 60.0;
	for (double t = 0.0; t < 40.0 && arrived < 2; t += dt) {
		inputs[INPUT_REQUESTED_SPEED] = pace;
		inputs[INPUT_STRIDE + INPUT_REQUESTED_SPEED] = pace;
		const Vec3f positions[2] = { a.position(), b.position() };
		const Vec3f velocities[2] = { a.velocity(), b.velocity() };
		const float headings[2] = { float(a.pose.yaw), float(b.pose.yaw) };
		service.follow_step(keys.data(), 4, positions, 2, velocities, 2, headings, 2, dt, inputs.data(), inputs.size(),
				commands, state, preferred, error);
		a.apply(commands.data(), dt);
		b.apply(commands.data() + COMMAND_STRIDE, dt);
		for (const FollowEvent &event : service.take_follow_events()) {
			arrived += event.kind == EVENT_ARRIVED ? 1 : 0;
		}
		closest = std::min(closest, std::hypot(a.pose.x - b.pose.x, a.pose.z - b.pose.z));
	}
	std::printf("  head-on %.1f m/s: closest %.2f m, arrived %d\n", pace, closest, arrived);
	CHECK(closest >= 0.45 + 0.45 + 0.1 - 0.05, "passing preserves both body radii without any avoidance answer");
	CHECK(arrived == 2, "both pass and arrive (no symmetric deadlock)");

	// Nose to nose and already inside the hard separation (0.55 m apart), each route running
	// through the other: they step round and part, never closer than they started.
	const ActorHandle left_one = follower(service, world);
	const ActorHandle right_one = follower(service, world);
	Motor e, f;
	e.pose.x = -20.0;
	e.pose.z = 0.275;
	f.pose.x = -20.0;
	f.pose.z = -0.275;
	f.pose.yaw = PI_D;
	give_corridor(service, left_one, densify({ Vec3f(-20, 0, 0.275f), Vec3f(-20, 0, -10) }), e, 1, 1);
	give_corridor(service, right_one, densify({ Vec3f(-20, 0, -0.275f), Vec3f(-20, 0, 10) }), f, 1, 1);
	std::vector<int64_t> pair{ left_one.slot, left_one.generation, right_one.slot, right_one.generation };
	double nearest_pair = INF;
	int parted = 0;
	int pair_failed = 0;
	for (double t = 0.0; t < 40.0 && parted < 2 && pair_failed == 0; t += dt) {
		inputs[INPUT_REQUESTED_SPEED] = 1.2f;
		inputs[INPUT_STRIDE + INPUT_REQUESTED_SPEED] = 1.2f;
		const Vec3f positions[2] = { e.position(), f.position() };
		const Vec3f velocities[2] = { e.velocity(), f.velocity() };
		const float headings[2] = { float(e.pose.yaw), float(f.pose.yaw) };
		service.follow_step(pair.data(), 4, positions, 2, velocities, 2, headings, 2, dt, inputs.data(), inputs.size(),
				commands, state, preferred, error);
		e.apply(commands.data(), dt);
		f.apply(commands.data() + COMMAND_STRIDE, dt);
		for (const FollowEvent &event : service.take_follow_events()) {
			parted += event.kind == EVENT_ARRIVED ? 1 : 0;
			pair_failed += event.kind == EVENT_FAILED ? 1 : 0;
		}
		nearest_pair = std::min(nearest_pair, std::hypot(e.pose.x - f.pose.x, e.pose.z - f.pose.z));
	}
	std::printf("  nose to nose at 0.55 m: closest %.2f m, arrived %d, failed %d\n", nearest_pair, parted, pair_failed);
	CHECK(parted == 2 && pair_failed == 0, "both step round and arrive");
	CHECK(nearest_pair >= 0.55 - 0.01, "never closer than they started");

	// Avoidance answers: zero means yield (a recorded reason) when somepony is near enough to
	// cause it, until the yield limit; alone, a zero answer is broken avoidance and never holds her.
	for (int crowd = 0; crowd < 2; ++crowd) {
		const ActorHandle lone = follower(service, world);
		Motor c;
		c.pose.x = 10.0 + 20.0 * crowd;
		c.pose.z = 10.0;
		const double x0 = c.pose.x;
		give_corridor(service, lone, densify({ Vec3f(float(x0), 0, 10), Vec3f(float(x0), 0, -10) }), c, 1, 1);
		run_follower(service, lone, c, 1.2, 1.0, x0, -10.0);
		const size_t rows = crowd ? 2 : 1;
		std::vector<int64_t> keys{ lone.slot, lone.generation, -1, 0 };
		std::vector<float> rows_inputs(INPUT_STRIDE * 2, 0.0f);
		rows_inputs[INPUT_REQUESTED_SPEED] = 1.2f;
		rows_inputs[INPUT_FLAGS] = float(INPUT_FLAG_AVOIDANCE);
		rows_inputs[INPUT_AVOID_AGE] = 0.02f;
		int yielded = 0;
		int resumed = 0;
		int travelled = 0;
		for (double t = 0.0; t < 3.5; t += dt) {
			// The neighbour walks alongside, 2 m to her left, out of her way.
			const Vec3f positions[2] = { c.position(), Vec3f(float(c.pose.x - 2.0), 0.0f, float(c.pose.z)) };
			const Vec3f velocities[2] = { c.velocity(), c.velocity() };
			const float headings[2] = { float(c.pose.yaw), float(c.pose.yaw) };
			service.follow_step(keys.data(), rows * 2, positions, rows, velocities, rows, headings, rows, dt,
					rows_inputs.data(), rows * INPUT_STRIDE, commands, state, preferred, error);
			if (int(state[5]) == REASON_YIELDING && int(commands[3]) == MODE_HOLD) {
				++yielded;
			} else if (yielded > 0 && int(commands[3]) == MODE_TRAVEL && commands[1] > 0.1f) {
				++resumed;
			}
			if (int(commands[3]) == MODE_TRAVEL && commands[1] > 0.1f) {
				++travelled;
			}
			c.apply(commands.data(), dt);
		}
		if (crowd) {
			CHECK(yielded > 60, "a zero avoidance answer with a pony near yields with the reason recorded");
			CHECK(resumed > 0, "past the yield limit she proceeds on neighbour-checked following");
		} else {
			std::printf("  alone with a zero answer: yielded %d ticks, travelled %d ticks\n", yielded, travelled);
			CHECK(yielded == 0 && travelled > 150, "alone, a zero avoidance answer does not hold her");
		}
	}
	// Pressure: avoidance asks for a velocity turned 40 degrees to her right.
	const ActorHandle pushed = follower(service, world);
	Motor d;
	d.pose.x = -10.0;
	d.pose.z = 10.0;
	give_corridor(service, pushed, densify({ Vec3f(-10, 0, 10), Vec3f(-10, 0, -10) }), d, 1, 1);
	run_follower(service, pushed, d, 1.2, 1.0, -10.0, -10.0);
	std::vector<int64_t> pushed_key{ pushed.slot, pushed.generation };
	std::vector<float> pushed_inputs(INPUT_STRIDE, 0.0f);
	pushed_inputs[INPUT_REQUESTED_SPEED] = 1.2f;
	pushed_inputs[INPUT_FLAGS] = float(INPUT_FLAG_AVOIDANCE);
	const double angle = -40.0 * PI_D / 180.0;
	double fx = 0.0, fz = 0.0;
	forward_of(d.pose.yaw + angle, fx, fz);
	pushed_inputs[INPUT_AVOID_VX] = float(fx * 1.2);
	pushed_inputs[INPUT_AVOID_VZ] = float(fz * 1.2);
	pushed_inputs[INPUT_AVOID_AGE] = 0.02f;
	const Vec3f position = d.position();
	const Vec3f velocity = d.velocity();
	const float heading = float(d.pose.yaw);
	service.follow_step(pushed_key.data(), 2, &position, 1, &velocity, 1, &heading, 1, dt, pushed_inputs.data(),
			pushed_inputs.size(), commands, state, preferred, error);
	CHECK(commands[2] < -0.05f, "an avoidance proposal to her right makes her curve right");
}

void test_wall_contact_evidence() {
	section("wall contact: no motion into the wall; repeated frontal contact marks it and replans");
	NavigationService service(1);
	const uint32_t world = open_world(service);
	const ActorHandle actor = follower(service, world);
	Motor motor;
	motor.pose.z = 5.0;
	motor.v = 1.0;
	give_corridor(service, actor, densify({ Vec3f(0, 0, 5), Vec3f(0, 0, -10) }), motor, 1, 1);
	std::vector<int64_t> keys{ actor.slot, actor.generation };
	std::vector<float> inputs(INPUT_STRIDE, 0.0f);
	std::vector<float> commands, state;
	std::vector<Vec3f> preferred;
	std::string error;
	const double dt = 1.0 / 60.0;
	int replans = 0;
	size_t blocked = 0;
	double into_wall = 0.0;
	// An obstacle the walk grid does not know (a cart): every physical move reports a wall whose
	// normal faces her (+Z), and the body does not get through it.
	for (double t = 0.0; t < 2.0; t += dt) {
		inputs[INPUT_REQUESTED_SPEED] = 1.0f;
		inputs[INPUT_FLAGS] = float(INPUT_FLAG_WALL);
		inputs[INPUT_WALL_NX] = 0.0f;
		inputs[INPUT_WALL_NZ] = 1.0f;
		inputs[INPUT_EXECUTED_SPEED] = float(motor.v);
		const Vec3f position = motor.position();
		const Vec3f velocity = motor.velocity();
		const float heading = float(motor.pose.yaw);
		service.follow_step(keys.data(), 2, &position, 1, &velocity, 1, &heading, 1, dt, inputs.data(), inputs.size(),
				commands, state, preferred, error);
		double fx = 0.0, fz = 0.0;
		forward_of(motor.pose.yaw, fx, fz);
		if (commands[1] > 0.05f && fz < -0.2) {
			into_wall += dt;
		}
		for (const FollowEvent &event : service.take_follow_events()) {
			if (event.kind == EVENT_REPLAN) {
				++replans;
				blocked = event.blocked.size();
			}
		}
		// The body stays where the obstacle holds it (the slide removed the motion into it).
		motor.v = std::min<double>(commands[1], 0.0);
	}
	std::printf("  %.2f s of commands into the wall, replans %d with %zu blocked disc(s)\n", into_wall, replans, blocked);
	CHECK(into_wall < 0.1, "no command keeps driving into a reported wall");
	CHECK(replans >= 1 && blocked >= 1, "repeated frontal contact marks the spot and asks for a replan around it");
}

void test_lost_floor_replans() {
	section("the walk grid loses her floor mid-route: replan at once instead of stalling");
	NavigationService service(1);
	const uint32_t world = open_world(service);
	const ActorHandle actor = follower(service, world);
	Motor motor;
	motor.pose.z = 10.0;
	give_corridor(service, actor, densify({ Vec3f(0, 0, 10), Vec3f(0, 0, -20) }), motor, 1, 1);
	run_follower(service, actor, motor, 2.0, 1.0, 0.0, -20.0);
	// A streamed republication puts the sampled floor 1 m below where she and her corridor are.
	const CellFn lower = [](int32_t, int32_t) { return std::vector<SpanInput>{ floor_at(-1.0f) }; };
	fill(*service.world(world), -2, -2, 1, 1, lower);
	std::vector<int64_t> keys{ actor.slot, actor.generation };
	std::vector<float> inputs(INPUT_STRIDE, 0.0f);
	std::vector<float> commands, state;
	std::vector<Vec3f> preferred;
	std::string error;
	const double dt = 1.0 / 60.0;
	double replanned_at = INF;
	for (double t = 0.0; t < 3.0 && !std::isfinite(replanned_at); t += dt) {
		inputs[INPUT_REQUESTED_SPEED] = 2.0f;
		const Vec3f position = motor.position();
		const Vec3f velocity = motor.velocity();
		const float heading = float(motor.pose.yaw);
		service.follow_step(keys.data(), 2, &position, 1, &velocity, 1, &heading, 1, dt, inputs.data(), inputs.size(),
				commands, state, preferred, error);
		motor.apply(commands.data(), dt);
		for (const FollowEvent &event : service.take_follow_events()) {
			if (event.kind == EVENT_REPLAN) {
				replanned_at = t;
			}
		}
	}
	std::printf("  replan requested %.2f s after the floor was lost\n", replanned_at);
	CHECK(replanned_at < 1.0, "a replan within a second, not a stall escalation");
}

void test_hill_speed_scale() {
	section("hill factor: the follower scales its target once, the motor does not compound it");
	NavigationService service(1);
	const uint32_t world = open_world(service);
	const ActorHandle actor = follower(service, world);
	Motor motor;
	motor.pose.z = 20.0;
	give_corridor(service, actor, densify({ Vec3f(0, 0, 20), Vec3f(0, 0, -20) }), motor, 1, 1);
	std::vector<int64_t> keys{ actor.slot, actor.generation };
	std::vector<float> inputs(INPUT_STRIDE, 0.0f);
	std::vector<float> commands, state;
	std::vector<Vec3f> preferred;
	std::string error;
	const double dt = 1.0 / 60.0;
	for (double t = 0.0; t < 4.0; t += dt) {
		inputs[INPUT_REQUESTED_SPEED] = 2.5f;
		inputs[INPUT_SPEED_SCALE] = 0.6f;
		const Vec3f position = motor.position();
		const Vec3f velocity = motor.velocity();
		const float heading = float(motor.pose.yaw);
		service.follow_step(keys.data(), 2, &position, 1, &velocity, 1, &heading, 1, dt, inputs.data(), inputs.size(),
				commands, state, preferred, error);
		motor.apply(commands.data(), dt);
	}
	std::printf("  speed after 4 s at a 0.6 hill factor: %.2f m/s (requested 2.5)\n", motor.v);
	CHECK(std::fabs(motor.v - 1.5) < 0.05, "she travels at the scaled target (1.5 m/s), not a crawl");
}

void test_search_blocked_and_goal() {
	section("search keeps out of blocked discs; arrival extends to the requested goal or reports an alternative");
	NavigationService service(1);
	auto wall_line = [](int32_t x, int32_t z) {
		const double cx = (double(x) + .5) * CELL;
		const double cz = (double(z) + .5) * CELL;
		return cz > -12.15 && cz < -11.85 && cx > -4.0 && cx < 4.0;
	};
	const uint32_t world = open_world(service, walled(wall_line));
	SearchOptions options;
	SearchBlock block;
	block.x = 0.0;
	block.z = 5.0;
	block.radius = 1.5;
	options.blocked.push_back(block);
	const SearchOutput around = search(*service.world(world), pony(), Vec3f(0, 0, 10), Vec3f(0, 0, 0), options);
	double nearest = INF;
	for (const Vec3f &point : around.path) {
		nearest = std::min(nearest, std::hypot(double(point.x), double(point.z) - 5.0));
	}
	CHECK(around.status == RouteStatus::COMPLETE && nearest > 1.5 - CELL, "the route goes round the blocked disc");
	const ActorHandle actor = follower(service, world);
	Motor motor;
	motor.pose.z = 10.0;
	CorridorRequest request;
	request.points = densify({ Vec3f(0, 0, 10), Vec3f(0.125f, 0, 2.125f) });
	request.route = 1;
	request.intent = 1;
	request.has_goal = true;
	request.goal = Vec3f(0.2f, 0, 2.0f);
	const CorridorReply open_goal = service.follow_set_corridor(actor, request, motor.position(), 0.0, motor.velocity());
	CHECK(open_goal.goal_appended && !open_goal.alternative, "an open-floor goal near the route end is appended");
	const FollowRun run = run_follower(service, actor, motor, 2.5, 20.0, 0.2, 2.0);
	CHECK(run.arrivals == 1 && run.miss <= 0.25, "arrival is judged at the requested goal");
	request.points = densify({ Vec3f(0, 0, -5), Vec3f(0.125f, 0, -11.125f) });
	request.goal = Vec3f(0.125f, 0, -11.7f);
	request.intent = 2;
	request.route = 2;
	Motor second;
	second.pose.z = -5.0;
	const CorridorReply wall_goal = service.follow_set_corridor(actor, request, second.position(), 0.0, second.velocity());
	CHECK(!wall_goal.goal_appended && wall_goal.alternative, "a goal inside wall clearance is a reported alternative");
}

} // namespace

int main() {
	test_coordinates();
	test_legacy_conversion();
	test_known_costs();
	test_bridge_over_floor();
	test_three_floors();
	test_random_vs_dijkstra();
	test_unreachable_and_frontier();
	test_coarse_components();
	test_budget_resume();
	test_cancellation();
	test_profiles_and_cache();
	test_service_lifecycle();
	test_determinism_threads();
	test_godot_convention();
	test_corridor_projection();
	test_speed_limits();
	test_follow_open_ground();
	test_follow_reversal();
	test_follow_walls();
	test_narrow_ramp_start();
	test_cramped_escape();
	test_wide_nook();
	test_corner_with_neighbour();
	test_progress_monitor();
	test_support_refused_alignment();
	test_batch_wire_format();
	test_route_replacement();
	test_neighbours_and_avoidance();
	test_neighbours_and_avoidance(3.1f);
	test_wall_contact_evidence();
	test_lost_floor_replans();
	test_hill_speed_scale();
	test_search_blocked_and_goal();
	std::printf("NAVIGATION_NATIVE_TESTS %s (%d checks, %d failures)\n", failures == 0 ? "PASS" : "FAIL", checks, failures);
	return failures == 0 ? 0 : 1;
}
