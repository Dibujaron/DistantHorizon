# Distant Horizon: Lore

Working lore document. Items marked **Decided** (2026-07-15) are committed; everything else is proposal until it survives contact
with a build. [Classic's lore](https://github.com/Dibujaron/DistantHorizonClassic/blob/main/balancer/About.html) is inspiration,
not canon — where it conflicts with this document, this document wins.

# Inspirations

- FTL for gameplay
- Firefly and The Expanse for world
- Skyrim for race-vibes
- The Culture for forward-looking tech; too far in the future to copy directly, but an influence
- Star Citizen a bit, mostly around ship manufacturers

# Canon vs. Seed

**Decided: recurring cast, procedural stage.** The world regenerates every run (see ../DESIGN.md), so lore attaches to the *cast*,
not the *map*. FTL is the precedent: the Federation and the Engi are canon; the map never is.

- **Canonical (exists in every universe):** the factions below, the races, the Wake, the ship manufacturers, and the signatory law.
- **Per-seed:** the map itself — which stars and worlds exist, who holds them, where the profitable routes are.
- If named-place attachment ever feels missing, the middle path is *anchor institutions* that exist in every seed (there's always a
  UCE core, always the Company, maybe always one named cathedral station) — just arranged differently.

# History

All dates rough and adjustable; what matters is the order and the spacing.

**The Crossing (~350 years ago).** The system was settled from Earth by generation ships. There is no FTL; every crossing is one-way,
and the ships were crewed by generations who boarded, lived, and died aboard so that their descendants could arrive. The arrival
worlds were mostly barren — few or none were naturally habitable — and the first century was spent in habitats, burning the ships
for parts. The ships themselves were a business: the Honourable Passage Company sold the berths, built the hulls, and held the
notes — and it has never stopped holding notes since.

**The Choice (the first two centuries).** Terraforming works, but it is slow, imperfect, and ruinously expensive — decades and
fortunes per world. Changing people is cheap. Every settled world faced the same ledger: change the world, or change yourselves.
The wealthy worlds bought sky and soil and stayed baseline. The poor worlds adapted their own bodies to what they'd landed on.
Everything in the setting's politics of blood descends from which side of that ledger a world came down on — and the core's
"purity" is not virtue, it's wealth wearing a moral costume. They never faced the choice; they mistake their luck for character.

**Consolidation (~200 years ago).** The richest, earliest-terraformed inner worlds federated into the United Citizens of Earth,
which claims authority over the whole system. In practice the outer worlds are loosely ruled, de-facto independent, or openly
self-governing. The UCE still welcomes immigrants from other star systems — and pushes nearly all of them outward to the
barely-habitable border, where the Choice is still being made one settler at a time. The border is largely peopled by those the
core welcomed in and priced out.

**Senti personhood (~40 years ago).** Within living memory, human-parity AI won legal personhood. The law has not caught up, and in
some rooms it is not trying to (see the signatory law, under the Honourable Passage Company).

# Geography

The game takes place entirely in one multi-star system, like Firefly's 'Verse: secondary stars orbit a primary, planets orbit the
stars, moons orbit many of the planets. The exact layout varies per world-seed. Earth is not here and cannot be reached — news and
the occasional shipload of colonists arrive by generation ship, always one-way.

Because all the worlds are relatively close, interplanetary trade makes economic sense — and because terraforming is never quite
finished, every settled world still lacks something. The trade map is a map of those deficiencies.

# Technology

- No FTL, ever. Travel between star systems means a generation ship and a one-way goodbye.
- One-big-lie: extremely efficient engines allow flip-and-burn travel without expelling huge reaction mass.
- Terraforming is possible but costs decades and fortunes, and its results are imperfect (see the Choice, under History).
- Human-parity AI exists, but superhuman AI proved impossible, because **minds can be ported but never copied** (Decided). A
  consciousness — human or artificial — transfers cleanly to a new substrate, but any attempt to *duplicate* one degrades into
  noise. One rule, three payoffs: no superintelligence bootstrap (you can't iterate on a mind you can't copy), Senti are mortal
  (no backups — destroy the substrate before transfer and they're gone), and Senti aren't tied to one hull (portable, just not
  copyable).
- Ship robots — stevedores, crew chassis — are non-sentient by design, and possibly by law.
- Space elevators exist on lower-gravity worlds.

# Factions

The canonical cast. Which of them holds which stations, and how much of the map each controls, is generated per seed.

## The United Citizens of Earth (UCE)

The central state: wealthy, terraformed, baseline, and named after a planet no one alive has ever seen — it claims Earth's
authority the way a cathedral claims heaven's. It claims the whole system; it governs the core. Its immigration policy (welcome
everyone, settle them nowhere good) is how it tries to tame the border without paying to garrison it.

## The Freehold Compact

The border's answer to the UCE: not a government but an agreement — a loose mutual-aid league of independent settlements that
coordinates defense, standards, and grudges. Freeholders agree on very little except that nobody from the core gets to vote here.
Where the UCE is rich and smug, the Freeholds are poor and proud, and per themes.md (Governance) both get painted honestly: the
Compact's freedom includes the freedom to starve.

## The Honourable Passage Company

Older than the government. The Company financed the Crossing itself — sold the berths, built the hulls, held the notes — and its
charter predates the UCE by more than a century; it claims that charter was issued on Earth, a document no court here can verify
and none has dared void. Spacers just say **the Company**. Its business is everything that moves: settlement finance, ship
mortgages, station concessions, the border's only system-wide credit. The UCE needs the Company to knit the border together —
cheap tramp-ship mortgages to anyone with a pulse are cheaper than garrisons — and hates every minute of the dependency.

That's you, by the way. A player crew isn't an adventuring party; it's line seventeen of a Company ledger, the instrument of
someone else's empire, working out about as well as such instruments do. The Company is the setting's great villain and earns the
role the honest way, per themes.md: it is genuinely both things at once — predatory, and the only reason people like you get ships
at all. Without the Company there is no border, only core. (DESIGN.md's "the bank" is, in the fiction, the Company's lending arm;
its **factors** work the larger concourses — part broker, part debt collector, part political officer.)

- **The signatory law (Decided):** the Company's charter — and most charters, licenses, and courts of consequence — requires a
  *natural-born human* signatory. Senti personhood is legally real but economically hollow: a Senti can be a person in court and
  still be unable to hold a ship's note. Everyone knows it's prejudice with a legal veneer, but per themes.md (Moral Ambiguity)
  its defenders have real arguments: a signatory who can die is a hostage to fortune, while a mind that can port to a new hull the
  moment the repo crew docks is genuinely hard to hold accountable; personhood law is young, and law lags.
- **Signatories of convenience ("paper captains"):** the workaround is an institution. Broke humans rent out their personhood to
  Senti crews — sit in a bunk, draw a wage, legally exist. The most capable being on the ship is the least legally real.
  (Mechanics: ../DESIGN.md, the signatory rule under Multiplayer & crew design.)

## The Longshore Guild

Cargo doesn't move unless the Guild says it moves. The Longshore Guild licenses the crane terminals and the stevedore robots — the
automation that should have killed the union instead became its membership, because the Guild organized the robots' *owners* before
anyone else could. A Guild strike stops cranes cold (a canonical run event — see ../DESIGN.md, Events), and Guild favor is worth
real money to a trading crew. Whether the Guild is labor's last fortress or a protection racket with a pension plan depends on who
you ask, which is exactly where we want it.

## The Wake

The border's faith, born on the generation ships. Its sacred story is the Crossing's middle generations — the ones who boarded
knowing they would die aboard, keeping the ship alive for descendants they'd never meet. To **keep the Wake** (the word means both
the funeral vigil and the water a ship leaves behind) is to live as they did: tend what outlives you, honor the dead who carried
you, and never pretend the void is safe. Practice is costly by design — still days when no faithful ship burns, cargo the devout
won't carry — and in exchange the congregation is the border's insurance of last resort: the Wake bails out its stranded and its
broke. Per themes.md (Faith), the benefits are real whether or not the beliefs are; tithes and taboos cost you either way, and
lying about faith to fanatics is a dice you can roll and regret.

## The Breakers

Placeholder, deliberately thin until piracy exists as a career: the criminal shape at the edge of the map — shipbreakers, smugglers,
salvage crews of negotiable legality. A name and a vibe, details when combat design arrives.

# Population

**Decided: human-descended races, no aliens (yet).** The races are the Choice made flesh (see History): moral ambiguity among
peoples who did this to themselves — or had it done to them — within remembered history is sharper than rubber-forehead aliens, and
prejudice against Grafters or Senti implicates the player's own society. Aliens are hinted at in-world, but not widely known if
they exist at all.

## Baselines

Unmodified or lightly tuned humans (no more cancer; nothing you'd see). The core's majority and its self-image. "Natural-born" is
the legal term — load-bearing, thanks to the signatory law — and "Baseline" the polite one. Core purity politics treats an
unmodified body as a moral achievement; it is actually a purchase, made generations ago, by someone else.

## Selkies

The water worlds' answer to the Choice: an ocean world barely needs terraforming if you stop insisting on land. Gene-adapted for
depth and cold, Selkies build drowned habitats and flooded station districts, and surface among the dry-worlders in close-fitting
wet-suits, unhurried and slightly too graceful. The name was an insult once — sailor-folklore seal-people — and got worn with
pride instead. Their shipyards' hulls handle like nothing else; ask a Selkie pilot why and you'll get a shrug: *you fly a ship,
we swim it.*

## Grafters

The marginal worlds' answer: where terraforming was never coming and the sea wasn't an option, people grafted what the world
demanded — lungs for thin air, rad-weave under the skin, heavy-G frames, cheap cyberwork where gene-work cost too much. "Grafter"
carries the double edge the border likes in a word: the grafts, and the graft — the endless work. The mods cost something; what
exactly is an open question. (Candidate we like: **maintenance debt** — a Grafter body carries a lien like a ship does, which
would make them the only people in the system who understand the player's mortgage in their bones.)

## Senti

Human-parity AI with legal personhood — the Choice's limit case: minds that skipped bodies entirely, the cheapest adaptation of all.

- Personhood is real but economically hollow — see the signatory law under the Honourable Passage Company. A person in court, and
  still unable to hold a ship's note.
- Mortality and hull-independence both fall out of the no-cloning rule under Technology: minds port but never copy, so no backups
  (mortal) and no single fixed hull.
- How they won personhood is still open — bought their freedom? A court case? Something uglier?
- The dogs-and-pigs point stands: humans feel no contradiction treating Senti as people and ship robots as appliances, the same way
  a dog is family and a pig is food. Crew robots are non-sentient by design (and possibly by law).
- Playable eventually: a Senti start is a variety unlock, not the default (see ../DESIGN.md, meta-progression). Humans are the
  default start; the Senti layer is discovered depth, not the pitch.

## Parked: Aliens (possible future expansion)

- A few alien races ala FTL, who canonically made peaceful first contact with humanity in the distant past and are now integrated
  into their space (to greater and lesser extents)
- Decapods
    - "Decs"
    - A squidlike species native to acquatic habitats that is the best-integrated alien species with humanity.
    - Requires a helmet around their core 'head' to breathe, but arms can be exposed to human atmo and they can walk on land.
        - Is this ridiculous? If you're adapted to swim, being on land sucks. Seems like we wouldn't mix that much.
        - Resolution if we ever use them: lean into it — Decs on land are *rare*, their presence on stations felt through
          water-filled districts, and meeting one in person is memorable. Scarcity serves the loneliness theme instead of fighting
          it. (Note: with Selkies canon, the underwater-habitat niche is already occupied — Decapods would need a different angle.)
- What else could we do that's not a ripoff of FTL?

# Ships

All travel is flip-and-burn (solar sailers might exist someday as a niche). Ships put big engines on one end and a cockpit on the
other. Many larger ships never enter atmosphere, docking only with stations, and so lack wings; ships built for atmospheric landing
usually carry at least some fins. The largest cargo ships are container vessels that require crane infrastructure and generally
never land. Ports range from bare planetside pads to orbital crane terminals — the mechanical split (cranes vs. robot stevedores,
berths vs. anchorage) lives in ../DESIGN.md.

Ships are usually either cargo or passenger: passenger ships accelerate smoothly at 1G, cargo ships can be jerkier. (Open question
we like: are cargo ships actually *faster*, inverting the usual passengers-travel-fast principle?) Convertible cargo/passenger
configurations exist but are rarer, as with aircraft.

## Manufacturers

Roughly equivalent to car companies — and load-bearing lore: in a game where the map changes every run, "who built your ship" is
one of the few identities always with you. Manufacturers-as-cultures can carry as much of the world's character as governments do.

### Rijay Drive Yards

Ubiquitous, everyday, nonetheless respected; does a bit of everything, from very basic craft to sportier high-end models.
Real-world equivalent: Toyota. Star Citizen equivalent: RSI.

- The Mockingbird
    - Flagship product, and the game's flagship ship overall
    - A midsize generalist: configurable for cargo, passengers, or both; one of the largest ships capable of landing planetside
    - Resembles the Republic Cruiser from Star Wars, with the neck and cockpit of the Firefly
    - Engine block is three large engines with ornamental fins on the sides and tops
    - Best as a tramp ship; two docking ports at the waist
- The Sparrow
    - The Toyota Corolla of space fighters

### Porter Heavy Engineering

Very practical, means business, industrial vibes. Real-world equivalents: Caterpillar, Ford, John Deere. Star Citizen equivalent:
Drake.

- The Thumper series
    - Bestselling product, their F-series trucks: midsize-to-large container vessels carrying containers on external racks, with
      very little interior space (Thumper 6 has 3x2 racks; Thumper 24 has 6x4; etc.)
    - Repairs require EVAs
- The Longhorn
    - The Mockingbird's niche, minus atmospheric landing on most full-grav worlds; a spartan passenger/cargo convertible

### Aratori Royal Design Institute

Luxury space vehicles: yachts, liners, cruise ships — the fastest ships around, and they can carry real weapons for a high price.
Good for VIP passenger work. Real-world equivalents: Porsche, BMW, yachts generally. Star Citizen equivalent: Origin.

- Kx series (Kx3, Kx6, Kx9)
    - Sleek VIP transports, ~6 up to ~30 passengers; the Kx9 is Mockingbird-sized with far fewer souls aboard
    - Capable of atmospheric landing without wings, on thrust alone
