class_name Palette
extends RefCounted
## Typed view of the wire protocol's `palette` field (server/colors.json), a
## flat array of 16 hex strings forwarded on welcome (issue #29). Index IS
## the NE-corner colour slot an author writes in a deck plan: 0-9 = '0'-'9',
## 10-15 = 'a'-'f'. Sprites are authored greyscale and MULTIPLIED by the slot
## colour at render (see colors.json's description).

var colors: Array[Color] = []


static func from_dict(data: Variant) -> Palette:
	var p := Palette.new()
	if data is Array:
		for hex: Variant in data:
			p.colors.append(Color(str(hex)))
	return p


## Slot 0-15 -> Color; white for an out-of-range slot (safe default).
func color(slot: int) -> Color:
	if slot < 0 or slot >= colors.size():
		return Color.WHITE
	return colors[slot]
