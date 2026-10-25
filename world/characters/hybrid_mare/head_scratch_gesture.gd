extends RefCounted
## Contact + deliberate back-and-forth travel. Head movement alone earns no stroke.
var previous_hand:=Vector3.INF
var previous_local:=Vector3.INF
var direction:=Vector3.ZERO
var stroke:=0.0
var travel:=0.0
var contact_time:=0.0
var active_time:=0.0
var reactions:=0
func reset() -> void:
	previous_hand=Vector3.INF;previous_local=Vector3.INF;direction=Vector3.ZERO
	stroke=0.0;travel=0.0;contact_time=0.0;active_time=0.0
func advance(delta:float,contact:bool,hand:Vector3,head:Transform3D,center:Vector3) -> bool:
	if not contact or not hand.is_finite() or delta<=0 or delta>.1:
		reset();return false
	var local:Vector3=head.affine_inverse()*hand
	active_time=maxf(0,active_time-delta)
	contact_time+=delta
	if previous_hand.is_finite():
		var moved:Vector3=local-previous_local
		var normal:Vector3=(local-center).normalized()
		moved-=normal*moved.dot(normal)
		var distance:=minf(moved.length(),hand.distance_to(previous_hand))
		if distance>.0004 and distance/delta<1.5:
			var along:=moved.normalized()
			if direction!=Vector3.ZERO and along.dot(direction)<-.4 and stroke>.01:
				if contact_time>=.18 and travel>=.025:
					active_time=.45;reactions+=1;travel=0.0
				stroke=0.0;direction=along
			if direction==Vector3.ZERO:direction=along
			stroke+=distance;travel+=distance
			if active_time>0.0:active_time=.45
	previous_hand=hand;previous_local=local
	return active_time>0.0
