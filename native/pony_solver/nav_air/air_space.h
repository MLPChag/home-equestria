#pragma once
#include <cstdint>
#include <vector>
namespace nav_air {
struct Vec3 { float x, y, z; };
struct Aabb { Vec3 min, max; };
enum class Cell : uint8_t { UNKNOWN = 0, FREE = 1, SOLID = 2 };
// Additive (AIR_SEARCH, 2026-10-02): sizes from the line below, and the grid convention the search
// and supercover traversal assume: tile (tx, ty, tz) covers [t*32, t*32 + 32) on each axis (world
// origin 0, Godot Y up); coarse/fine cells are aligned to that grid.
constexpr float AIR_TILE_SIZE = 32.0f;
constexpr float AIR_COARSE_SIZE = 4.0f;
constexpr float AIR_FINE_SIZE = 0.5f;
// level 0 = coarse 4 m cell, level 1 = fine 0.5 m cell; tile = 32 m; local = x + 8*(y + 8*z) in its level.
struct CellId { int32_t tx, ty, tz; uint16_t coarse; uint16_t fine; uint8_t level; };  // fine unused when level 0
struct Face { CellId to; Aabb overlap; };  // actual shared face rectangle (degenerate box)
class AirSpace {  // one instance per flight profile: occupancy already inflated by that profile's envelope
public:
  virtual ~AirSpace() = default;
  virtual bool locate(const Vec3 &p, CellId &out) const = 0;        // leaf cell containing p (any state)
  virtual Cell state(const CellId &c) const = 0;
  virtual Aabb bounds(const CellId &c) const = 0;
  virtual void neighbours(const CellId &c, std::vector<Face> &out) const = 0;  // FREE face neighbours only, seams enumerated
  virtual Cell sample(const Vec3 &p) const = 0;                     // UNKNOWN where no tile
  virtual uint64_t tile_revision(int32_t tx, int32_t ty, int32_t tz) const = 0;  // 0 = absent

  // ---- Additive extension (AIR_SEARCH, 2026-10-02). Not pure: storage may override for speed. ----
  // True when any region across a face of c is UNKNOWN (missing tile or UNKNOWN cell). The search
  // uses it to tell WaitingForGeometry from Unreachable, because neighbours() lists FREE cells only.
  // Default: probe just outside each face centre with locate()/state(); where a coarse cell faces a
  // subdivided coarse cell, probe every fine cell along that face with sample().
  virtual bool touches_unknown(const CellId &c) const {
    const Aabb b = bounds(c);
    const float lo[3] = {b.min.x, b.min.y, b.min.z};
    const float hi[3] = {b.max.x, b.max.y, b.max.z};
    const float size = hi[0] - lo[0];
    const float step = AIR_FINE_SIZE;
    const float out = AIR_FINE_SIZE * 0.25f;
    for (int axis = 0; axis < 3; ++axis) {
      const int u = (axis + 1) % 3, v = (axis + 2) % 3;
      for (int side = 0; side < 2; ++side) {
        float p[3];
        p[axis] = side ? hi[axis] + out : lo[axis] - out;
        p[u] = 0.5f * (lo[u] + hi[u]);
        p[v] = 0.5f * (lo[v] + hi[v]);
        CellId n;
        if (!locate(Vec3{p[0], p[1], p[2]}, n)) return true;
        if (n.level == 0 || size <= step * 1.01f) {
          if (state(n) == Cell::UNKNOWN) return true;
          continue;
        }
        const int count = int(size / step + 0.5f);
        for (int i = 0; i < count; ++i) {
          for (int j = 0; j < count; ++j) {
            p[u] = lo[u] + (float(i) + 0.5f) * step;
            p[v] = lo[v] + (float(j) + 0.5f) * step;
            if (sample(Vec3{p[0], p[1], p[2]}) == Cell::UNKNOWN) return true;
          }
        }
      }
    }
    return false;
  }
};
}
