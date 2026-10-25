extends RefCounted
## Handheld placement only: the existing book mesh/pages are unchanged.
## Book +Y is the readable face, -Z is the printed page's top, +X the reader's right.
## Rule (dev 2026-10-15): the back cover rests on the palm, the open pages face the eyes upright
## and read left to right, and the hands hold it from behind, never over the pages.

## VR: one hand under the spine. An open book's pages take the side of the hand that faces the
## eyes; the palm sample gives the axis, not the side. Its sign is not trusted for reading: the
## visible Anon hand reported the back of the hand until a separate fix on 2026-10-15 (measured in
## tools/books/review_book_grip.gd), which turned the book away from the reader, and the physics
## hand fallback is another rig. `current` (the book's present basis) keeps the side while the
## hand is edge-on, so the book does not hop across it. A closed book follows the palm as given,
## so it can be turned over to see the cover art on its back.
static func from_hand(sample: Dictionary, view: Transform3D, current: Basis = Basis(), face_eyes := true) -> Transform3D:
	var pose: Transform3D=sample.get("pose",Transform3D.IDENTITY)
	var point: Vector3=sample.get("grip_position",pose.origin)
	var normal: Vector3=sample.get("palm",-pose.basis.y)
	if not point.is_finite() or not normal.is_finite() or normal.length_squared()<.5:
		return pose
	normal=normal.normalized()
	var to_eye := view.origin-point
	var facing := normal.dot(to_eye.normalized()) if to_eye.length_squared()>.0001 else 1.0
	if face_eyes:
		if absf(facing)<.2 and current.y.is_finite() and current.y.length_squared()>.5:
			if current.y.dot(normal)<0.0: normal=-normal
		elif facing<0.0:
			normal=-normal
	var up := view.basis.y.slide(normal)
	if up.length_squared()<.01: up=(-view.basis.z).slide(normal)
	if up.length_squared()<.01: up=pose.basis.x.slide(normal)
	up=up.normalized()
	var right := up.cross(normal).normalized()
	# Palm supports the lower back cover under the spine. The open hand's resting finger and thumb
	# curl reaches about 7 cm toward the book, so the boards sit 9 cm out from the palm centre and
	# the fingertips rest on the back instead of coming through the printed pages.
	return Transform3D(Basis(right,normal,-up),point+normal*.09+up*.08)

## Desktop reading: a visible hand behind each lower outer corner of the open book, palm on the
## back board, fingers up behind it. `book` is the open book's frame. Returned in the rig's
## controller convention (fingers -Z, thumb +Y, left palm +X, right palm -X; see
## tools/anon/check_hand_orientation.gd), so the thumb points outward behind the book.
## Palm centre in the book frame: outer lower corner, low enough that the forearm passes under
## the bottom edge, deep enough that the presentation's half-closed fingers stay inside the boards.
const DESKTOP_HAND := Vector3(.21, -.075, .12)
static func reader_hand(book: Transform3D, side: String) -> Transform3D:
	var b := book.basis.orthonormalized()
	var outward := 1.0 if side == "right" else -1.0
	var hand_basis := Basis(-b.y, b.x, b.z) if side == "right" else Basis(b.y, -b.x, b.z)
	return Transform3D(hand_basis, book * Vector3(DESKTOP_HAND.x * outward, DESKTOP_HAND.y, DESKTOP_HAND.z))
