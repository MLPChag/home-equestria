extends RefCounted
## Old briefcases holding foods that are no longer kept (world/food/retired_definitions.json,
## dev 2026-10-14: pre-made food only). On load each becomes the nearest pre-made food (a tomato
## a daisy sandwich, buns and patties a hayburger, an empty jam jar an empty cider mug). A stack
## larger than the new item allows is refunded in bits at the old price, so nothing is lost.
## Called by world/inventory/inventory_store.gd restore_document on its detached copy.
const FOOD := preload("res://world/food/food_catalog.gd")

## Rewrites retired ids in `doc` (slots and checked-out loans) in place; returns bits refunded.
static func migrate(doc: Dictionary) -> int:
	var refund := 0
	var slots: Array = doc.get("slots", [])
	for index: int in slots.size():
		var slot: Dictionary = slots[index]
		if slot.is_empty(): continue
		var old := str(slot.get("id", ""))
		var target := FOOD.replacement(old)
		if target.is_empty(): continue
		var count := int(slot.get("count", 0))
		var equipped := 0
		for loan: Dictionary in doc.get("checked_out", {}).values():
			if loan.get("equipped", false) and int(loan.get("slot", -1)) == index: equipped += 1
		var keep := clampi(count, equipped, maxi(_stack(target), equipped))
		refund += (count - keep) * FOOD.price_bits(old)
		slot.id = target
		slot.count = keep
		if not _bitten(target): slot.erase("bites")
		print("[inventory] retired %s x%d became %s x%d" % [old, count, target, keep])
	for loan: Dictionary in doc.get("checked_out", {}).values():
		var target := FOOD.replacement(str(loan.get("id", "")))
		if target.is_empty(): continue
		loan.id = target
		if not _bitten(target): loan.erase("bites")
	if refund > 0:
		doc.bits = int(doc.get("bits", 0)) + refund
		print("[inventory] refunded %d bits for retired food beyond a full stack" % refund)
	return refund

static func _stack(id: String) -> int:
	return maxi(1, int(FOOD.definition(id).get("stack", 1)))

## Only cupcakes keep visible bites.
static func _bitten(id: String) -> bool:
	return FOOD.slug(id) in ["cupcake", "strawberry-cinnamon-cilantro-cupcake"]
