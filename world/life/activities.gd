extends RefCounted
## Outdoor activities supported by existing movement and posture assets.
const KINDS := {
	"company": {
		"tags": ["rest"], "posture": "sit", "duration": 90.0, "company": true,
		"needs": {"social": 1.0}, "effects": {"energy": .06, "curiosity": -.05},
	},
	"rest": {
		"tags": ["rest"], "posture": "lie_down", "duration": 100.0, "company": false,
		"night_weight": .7,
		"needs": {"rest": 1.0}, "effects": {"energy": .24, "curiosity": -.05},
	},
	"cloudwatch": {
		"tags": ["view"], "posture": "sit", "duration": 75.0, "company": true,
		"needs": {}, "effects": {"energy": .09, "curiosity": -.05},
	},
	"stroll": {
		"tags": ["walk"], "posture": "stand", "duration": 50.0, "company": true,
		"min_distance": 12.0,
		"night_weight": -.25,
		"needs": {"curiosity": 1.0}, "effects": {"energy": -.045, "curiosity": -.35},
	},
	"explore": {
		"tags": ["walk"], "posture": "stand", "duration": 60.0, "company": true,
		"min_distance": 18.0,
		"night_weight": -.25,
		"needs": {"curiosity": 1.0}, "effects": {"energy": -.06, "curiosity": -.35},
	},
}
