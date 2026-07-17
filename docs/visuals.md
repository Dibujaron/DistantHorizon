# Distant Horizon: Visual Direction

The success criterion is M3.5's exit test (see ../DESIGN.md): **a stranger watching thirty
seconds of the game can tell what it wants to feel like.** Every section below should earn
its keep against that test.

## The pitch

- The umbrella genre is **cassette futurism / the "used future"**: Alien's Nostromo,
  classic Star Wars, working machines with grime on them. Technology that is old to the
  people using it.
- **Pixel world, era-coded interfaces.** The world (ships, planets, interiors, people) is
  pixel art; the UI plays a smarter game with nostalgia than pixels alone (see Interface).
- **Diegetic-first.** Every UI element should be a physical thing somewhere in the fiction.
  We can afford this rule because you *walk*: UI appears when you use a console, so it's
  naturally that console's screen.
- The void is beautiful and doesn't care that it is (see themes.md, Awe).

## The void

- Background of distant stars, slowly moving, with parallax. Classic had this and it looked
  awesome; keep it.
- **Restraint is the direction.** Mostly-empty screens, low star density, no nebula soup.
  This is a deliberate divergence from FTL, whose backgrounds are candy. Awe comes from
  emptiness and scale, not decoration.
- **Scale contrast:** your 20–64 px shabby freighter against a planet that doesn't fit on
  screen. The player should regularly feel small.
- **One hard light source:** no atmosphere means no scattered light — everything is lit by
  the system's sun from one direction, bright side and dark side, crisp edges. Baked
  shading can't do this (ships rotate freely; a painted-in lit side would orbit the hull),
  so the plan is **real 2D lighting**: sprites authored unlit (flat albedo) plus a normal
  map, lit at runtime by a `DirectionalLight2D` sun. Shipforge can emit height maps per
  part (it draws the parts, it knows their shapes) and derive normals mechanically, so
  every composed ship is light-ready for free. Guardrail: **quantize the lighting** to 2–3
  steps in-shader so it reads as pixel-art shading that moves, not a plasticky 3D render
  (see Graveyard Keeper's writeup, Songs of Conquest). Hand-drawn assets (planets, people,
  interior tiles) skip normals and opt out. *Gate passed 2026-07-17:*
  `tools/artspike/lightspike.py` (offline sheet, eyeballed and approved) +
  `tools/artspike/godot/` (same textures live in Godot 4.7: CanvasTexture +
  DirectionalLight2D + quantize shader; conventions documented in the shader). Spike
  caveat, load-bearing for M3.5: the spike derives height from silhouette doming, which
  only works on blob-shaped hulls — **production height maps come from the part
  composer** (each part emits its height profile alongside its color; heights compose in
  painter's order like albedo), and lit-pipeline albedo is authored flat, with no painted
  highlights.
- Palette carries over from Classic: heavy on blues, yellows, and purples for ambient
  space. This already encodes the classic warm-key/cool-ambient trick — yellows are
  sunlight, blues and purples are shadow. Keep leaning on it.
- Planets are pixelated sprites, as in Classic.

## Places (interiors and concourses)

- Interiors are cramped, cluttered, low-ceilinged. **The window is the payoff**: walking
  the hold while a station slides past outside is the Awe theme made playable. The
  contrast between tight inside and vast outside is the whole trick.
- Concourse tone follows themes.md (Loneliness): transactional, a little alienating,
  "lived-in" means traces of lives you don't share — shuttered stalls, someone else's
  coffee cup. Never cozy.
- **Signage is cheap vibe.** Concourses get a spaceport wayfinding language: departure
  boards, dock numbers, hazard pictograms. Reference: **Ron Cobb's Semiotic Standard**,
  the icon system designed for the Nostromo's interiors — practically a blueprint for a
  game about walking around working ships. Decals, stencils, and hazard stripes are the
  cheapest vibe-per-pixel we can buy.

## Machines (ships and stations)

- Manufacturer design languages are the backbone — see `tools/artspike/MANUFACTURERS.md`
  for the cues (PHE industrial, Rijay fast-practical, RADI fast-flashy).
- Ships are **assembled from parts** (shipforge pipeline), stations assembled from station
  data. Silhouette-first: a PHE hull and a RADI hull must read differently at 20 px.
- **Two player-tintable livery channels** per hull, over fixed manufacturer detail colors.
  This carried over from Classic and it's nice; the composer preserves it.

## People

- FTL-scale sprites; FTL is the honest reference for what a person on a deck plan looks
  like.
- Themes.md says "there is no generic NPC" — that's a visual requirement, not just a
  writing one. The tool is **variation axes**: faction (distinct silhouettes per faction),
  gender, build, outfit choice, color, and what they're holding. A few axes multiplied
  together beat any amount of hand-placed uniqueness.
- Rule of thumb: every NPC gets at least one odd thing — a garment, a prop, a color — that
  implies a story (the Selkie in the dry suit, the Wake pilgrim).

## Interface

- **Thesis: UI design has stabilized in the future.** Minimalism was a reaction to
  skeuomorphism, which was a reaction to ignorance; the pendulum settled. Future UI is
  big, clunky, and designed to be *used* — nobody in the future thinks you're cool because
  your UI merely hints at things. It mostly gets out of the way (except for us it's also
  an end in itself, because it carries this theme).
- **The nostalgia eras ARE the manufacturers.** Instead of betting the game on one retro
  register (pixels? Win95? Frutiger Aero?), each yard gets an era as its dialect:
    - **PHE** — analog cassette-futurism: stencil lettering, 7-segment readouts, toggle
      switches, hazard stripes.
    - **Rijay** — 90s-computing pragmatism: dense monospace terminals, function-key menus,
      amber-on-dark. The FTL register lives here.
    - **RADI** — Frutiger Aero: glossy, aqua, humane, slightly smug. "Like a Mac; probably
      not worth the price."
- **Ship UIs are manufacturer-driven.** Same information architecture across yards,
  different visual dialect — like real aircraft cockpits. You should get a brief "oh shit
  how do I fly this" on a new ship, gone in under a minute.
- **Station consoles** speak the station's manufacturer's dialect. Dialogue with people
  uses one common shell with a small faction badge/nameplate — no per-faction dialogue
  skinning, that's too much.
- **The game shell** (main menu, settings, run setup) speaks Rijay, the starter ship's
  yard, and doesn't change per run. Menus that silently reskin themselves read as a bug.
- Pixelated text is fine, if it's small. Smoother text is fine, if it's big. It's the
  future, they've invented font rendering, it's silly to pretend they haven't.

## Typography

Three named slots, plus manufacturer accents on top:

1. **Small/diegetic** — a pixel font, for console readouts and in-world text.
2. **Large/reading** — a clean plain sans-serif, for dialogue, menus, anything you
   actually read.
3. **Markings** — a stencil face, for hull names, dock numbers, cargo containers.

## Production constraints (style must survive the pipeline)

- Everything is procedurally assembled — ships from parts, stations from data — so the
  style must be **composable**: chunky parts, strong silhouettes, strict per-manufacturer
  palettes, the two livery channels. Nothing that requires hand-painting per asset.
- All art must read at game scale: ships 20–64 px tall.
- Decals, stencils, signage, and hazard stripes are the escape valve: modular by nature,
  huge vibe per pixel.

## References

- **FTL** — clarity and board-game legibility; rip that off shamelessly. Diverge on
  nebula-soup backgrounds and on diegesis (their UI is an overlay; ours is in the world).
- **Alien (1979) / Ron Cobb's Semiotic Standard** — the used future, and the icon system
  for working spaceships.
- **Classic Star Wars** — retro-tech, machines with grime.
- **Hardspace: Shipbreaker** — trucker-in-space competence; corporate branding as
  worldbuilding.
- **Objects in Space** — diegetic retro-tech UI in a space trader.
- **Citizen Sleeper** — station loneliness, transactional warmth.
- **Prey (2017)** — corporate design languages doing worldbuilding (TranStar's retro-future
  identity system).
