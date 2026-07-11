# Ship manufacturer design languages

Carried over from Classic (source: "Distant Horizon: Ship Manufacturer Design Cues" writeup
+ `DistantHorizonClassic/client/sprites/ships/{PHE,Rijay,RADI}`). Each manufacturer is a
parts sub-vocabulary + palette in the composer (`manufacturers.py`). New manufacturers get
added here first, as cues, before they get parts.

Classic sprite facts worth keeping: in-game sprites are 20–64 px tall (all art must read at
that scale), and ships used `c1`/`c2`/`constant_color` layers — two player-tintable livery
channels over fixed detail. The composer's accent system should preserve that: two
player-color channels per hull, manufacturer colors fixed.

## Porter Heavy Engineering / "PHE"
- Low-speed long-haul cargo and passenger transports.
- Industrial and utilitarian; aggressively non-aerodynamic; blocky unadorned parts connected
  by skeletal linkages; cockpits have lots of struts.
- Palette: white/light-gray truss, orange pods, gray modules, cyan glass.
- Ships: **Thumper 24** (large container freighter), **Thumper 6** (small container
  freighter), **Longhorn** (barebones passenger liner).

## Rijay Drive Yards / "Rijay"
- Fast but not flashy: fast freight, data-runners, smuggling, interceptors.
- Speed above all else; compromise designs — sleek unless it impacts practicality; large,
  very visible engines relative to body; cockpits placed forward.
- Palette: bright blue hull, white dorsal stripe, dark-blue practical bits.
- Ships: **Mockingbird** (medium fast freighter), **Swallow** (interceptor, carrier- or
  station-based). Classic also had Pegasus and Crusader sprites.

## Royal Aratori Design Institute / "RADI"
- Very fast, very flashy, very expensive: yachts, VIP charters, smuggling, interceptors.
  Overlaps Rijay in the fast-transport market — "like a mac; slightly better, probably not
  worth the price."
- Very sleek; recessed, hidden engines; central set-back cockpit near mid-ship; split bow.
- Palette: deep red hull, gray trim, cyan canopy.
- Ships: **kx6 XR** (long-haul passenger/yacht), **kx6 SR** (smaller sibling), **y-series**
  (long-range interceptor, popular with pirates).

## To be designed (new for the rewrite)
- A yard for the big container infrastructure side (or PHE covers it?).
- A military/security yard (patrol ships, when combat lands).
- A utility/tender yard (shuttles, lighters, stevedore-adjacent small craft) — candidates
  for the anchorage/lightering fleet.
