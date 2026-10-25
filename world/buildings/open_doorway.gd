extends Node
## A doorway with no door leaf: house travel asks the "FrontDoor" for passage, this always
## lets her through.
func request_passage(_pony: Node) -> bool: return true
func release_passage(_pony: Node) -> void: pass
