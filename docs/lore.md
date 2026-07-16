# Intro

none of this is set in stone, vibes only, suggestions welcome — except items marked **Decided** (2026-07-15), which we've committed to

# Original DH CLassic Lore

https://github.com/Dibujaron/DistantHorizonClassic/blob/main/balancer/About.html

# Inspirations

- FTL for gameplay
- Firefly and The Expanse for world
- Skyrim for race-vibes
- The Culture for forward-looking tech; it's too far in the future to copy directly but it's got some influence
- Star Citizen a bit, mostly around ship manufacturers

# Canon vs. Seed

**Decided: recurring cast, procedural stage.** The world regenerates every run (see ../DESIGN.md), so lore attaches to the *cast*, not the *map*. FTL is the precedent: the Federation and the Engi are canon; the map never is.

- **Canonical (exists in every universe):** factions, races, religions, ship manufacturers, the UCE, the bank, and the signatory law.
- **Per-seed:** the map itself — which stars and worlds exist, who holds them, where the profitable routes are.
- If named-place attachment ever feels missing, the middle path is *anchor institutions* that exist in every seed (there's always a UCE core, always the bank, maybe always one named cathedral station) — just arranged differently.

# Geography

- The game takes place entirely in one multi-star system, like Firefly's "The 'Verse". 
- Secondary stars orbit a primary star, and planets orbit the various stars, with moons orbiting many of the planets.
- The exact number of stars/planets and their configuration varies per world-seed.
- This star system does not contain Earth; it was settled from earth on generation ships.
- Because all of the planets are relatively close, interplanetary trade makes economic sense.
- Relatively few or zero planets were naturally habitable; terraforming tech was used to make them habitable.
    - This tech is imperfect and expensive.

# Technology

- FTL travel doesn't exist; travel between stars is done on generation ships.
- One-big-lie: extremely efficient engines exist which allow for "flip-and-burn" style engines without expelling huge quantities of mass.
- Terraforming is possible but very costly and takes decades.
- News and occasional colonists are carried between star systems by long-haul ships
    - any such journey is a one-way trip always, as everyone you know back home will be dead by the time you get anywhere
- Human-parity AI exists, but superhuman AI proved to be impossible, because **minds can be ported but never copied** (Decided). A consciousness — human or artificial — transfers cleanly to a new substrate, but any attempt to *duplicate* one degrades into noise. One rule, three payoffs: no superintelligence bootstrap (you can't iterate on a mind you can't copy), Senti are mortal (no backups — destroy the substrate before transfer and they're gone), and Senti aren't tied to one hull (portable, just not copyable).
- Space elevators exist on lower-gravity planets

# Politics

- Shamelessly like firefly (and the expanse), the central planets form a single, wealthy state called the United Citizens of Earth, which claims universal authority
- In practice the more distant planets are loosely ruled, de-facto independent, or are truly independent offshoots
- The UCE welcome immigrants (on generation ships) from other star systems in an attempt to more thoroughly tame the border planets
    - Most immigrants are not welcome to settle on the central planets, which are 'full'; they are pushed to barely-habitable border worlds
- **The signatory law (Decided):** banks — and most charters and licenses of consequence — require a *natural-born human* signatory. Senti personhood is legally real but economically hollow: a Senti can be a person in court and still be unable to hold a ship's note. Everyone in-world knows it's prejudice with a legal veneer, but per themes.md (Moral Ambiguity) the law's defenders have real arguments too: a signatory who can die is a hostage to fortune, while a mind that can port to a new hull the moment the repo crew docks is genuinely hard to hold accountable; personhood law is young, and law lags.
- **Signatories of convenience ("paper captains"):** the workaround is an institution. Broke humans rent out their personhood to Senti crews — sit in a bunk, draw a wage, legally exist. The most capable being on the ship is the least legally real. (Mechanics: ../DESIGN.md, the signatory rule under Multiplayer & crew design.)

# Population

**Decided: Variant 2 — human-descended races, no aliens (yet).** Moral ambiguity among peoples who did this to themselves — or had it done to them — within remembered history is sharper than rubber-forehead aliens; prejudice against Senti or Mixers implicates the player's own society. Aliens are hinted at in-world, but not widely known if they exist at all.

- Humans have splintered into a few distinct categories.
- Human Basics
    - Unmodified or lightly genetically altered basic humans (e.g. no more cancer)
    - Still the majority species of the UCE
- Altered Humans
    - Acquatics?
    - Weird cultists who modified themselves in XX way?
- Senti: Human-equivalent AI which have legal personhood
    - Personhood is real but economically hollow — see the signatory law under Politics. A person in court, and still unable to hold a ship's note.
    - Mortality and hull-independence both fall out of the no-cloning rule under Technology: minds port but never copy, so no backups (mortal) and no single fixed hull (not lame).
    - How they got personhood is still open — bought their freedom? A court case? Something uglier?
    - The dogs-and-pigs point stands: humans feel no contradiction treating Senti as people and ship robots as appliances, the same way a dog is family and a pig is food. Crew robots are non-sentient by design (and possibly by law).
    - Playable eventually: a Senti start is a variety unlock, not the default (see ../DESIGN.md, meta-progression). Humans are the default start; the Senti layer is discovered depth, not the pitch.
- Mixers: Genetically or cybernetically 'enhanced' humans?
    - Cyperpunk vibes?
    - Maybe they have shorter lives or something

## Parked: Aliens (possible future expansion)

- A few alien races ala FTL, who canonically made peaceful first contact with humanity in the distant past and are now integrated into their space (to greater and lesser extents)
- Decapods
    - "Decs"
    - A squidlike species native to acquatic habitats that is the best-integrated alien species with humanity. 
    - Requires a helmet around their core 'head' to breathe, but arms can be exposed to human atmo and they can walk on land.
        - Is this ridiculous? If you're adapted to swim, being on land sucks. Seems like we wouldn't mix that much.
        - Resolution if we ever use them: lean into it — Decs on land are *rare*, their presence on stations felt through water-filled districts, and meeting one in person is memorable. Scarcity serves the loneliness theme instead of fighting it.
    - Their ships and habitats are underwater (or something water-ish).
- What else could we do that's not a ripoff of FTL?

# Spaceports

- Level 0: You have to land on the planet (Requires atmospheric capability)
- Level 1: Orbital station (If over a planet, either has a space elevator or a shuttle system)
- Level 2: Orbital station with container cranes

# Ships

- All travel is done with "flip-and-burn" technology
    - later maybe solar sailers at some point? That'd be niche.
- Ships typically have big engines on one end and a cockpit on the other
- Many larger ships never enter atmosphere, docking only with stations and therefore lacking wings
    - Ships capable of atmospheric landing will usually have at least some fins
- The largest cargo ships are container ships, requiring crane infrastructure to operate
    - Container ships generally never land planetside
- Ships are usually either cargo or passenger
    - passenger ships accelerate smoothly at 1G, cargo ships can be jerkier 
        - Are cargo ships maybe faster? inversion of the usual passenger-fast principle?
    - Ships can be configured for both but it's rarer (as it is for planes)

## Ship Manufacturers

Ship manufacturers are roughly equivalent to car companies. They're also load-bearing lore: in a game where the map changes every run, "who built your ship" is one of the few identities always with you — manufacturers-as-cultures can carry as much of the world's character as governments do. 

### Rijay Drive Yards

- A ubiqitous, everyday manufacturer but nonetheless respected. Does a bit of everything.
    - At the high end offers some sporty or flashier models, but also offers very basic craft.
- Real-world equivalent: Toyota
- Star Citizen equivalent: Roberts Space Industries
- The Mockingbird
    - Flagship product
    - Also the game's flagship ship overall
    - a midsize generalist ship
        - configurable for cargo, passenger, or both
        - One of the largest ships capable of landing planetside
    - Resembles the Republic Cruiser from Star Wars, with the neck and cockpit of the Firefly
    - Engine block is three large engines with ornamental fins on the sides and tops
    - Best as a tramp ship
    - Has two docking ports at the waist of the ship
- The Sparrow
    - The Toyota Corolla of space fighters
    
### Porter Heavy Engineering

- Very practical, means business. Industrial vibes. 
- Real-world equivalents: Caterpillar, Ford, John Deere.
- Star Citizen equivalent: Drake
- The Thumper series
    - bestselling product, their equivalent of Ford's F-series trucks
    - midsize-to-large container vessels which carry containers on external racks and have very little interior space
        - The Thumper 6 has 3x2 racks; The Thumper 24 has 6x4, etc
    - Repairs require EVAs
- The Longhorn
    - Similar niche as the Mockingbird but not capable of atmospheric landing on most full-grav planets
    - A spartan passenger/cargo convertible ship

### Aratori Royal Design Institute

- Luxury space vehicles. Yachts, luxury liners, cruise ships.
- Real world equivalents: Porsche or BMW; yachts in general
- Star Citizen equivalent: Origin
- Can still definitely carry weapons and punch hard (for a high price).
- The fastest ships around.
- Good for VIP passenger transport missions.
- Kx series
    - Kx3, Kx6, Kx9
    - sleek VIP transports from ~6 passenger up to ~30
    - Kx9 is about the same size as the mockingbird but far fewer passengers
    - Capable of atmospheric landings without wings, using thrust alone