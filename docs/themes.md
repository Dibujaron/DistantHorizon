# Distant Horizon: Themes

What feelings are we trying to invoke in users when they play this game? What are we trying to say?

## Loneliness

DH Classic was conceptualized during the pandemic and ended up, I think, infused with a flavor of loneliness and technology-driven isolation.
The player navigates the universe at frightening speeds, very far away from any other player. Players can only interact indirectly at great distance.
The only interactions the player has with the world are stops at trading stations, which still hold you at a distance from the worlds they orbit.
You get brief glimpses that things are happening on the worlds - hints of unrest, or prosperity - through short flavor texts that randomly show up,
but that's all you get. You spend most of your time alone, with only the mind-breakingly infinite void for company.

At least in the game, this was something you'd chosen; a life by yourself out on the frontier, jockeying a spaceship. There was supposed to
be real beauty in the void, and the challenge of piloting, even if nobody saw it other than you.
There was also supposed to be pleasure in 'helping' people by bringing them goods, even if you barely got to see them.

Our 2026 remake of DH should still capture some of this feeling, I think; there's something in it that I like. The run structure
(see ../DESIGN.md) already encodes it well for single-crew ships: in shared universes, other crews appear mostly as burns seen across
the system — interaction at great distance, just like Classic. The thing to protect going forward is that **concourse density and tone
are a loneliness dial**: stations should stay sparse, transactional, and a little alienating — a few brokers, security, signage, quiet.
Nobody should later "improve" them into bustling taverns without noticing that it spends this theme.

Multi-crew ships will be different, obviously, because you're not alone; this becomes more like the Firefly fantasy, of a tight-knit
crew together, alone against the universe. Then it becomes more unambiguously a positive loneliness.

## Awe

Loneliness's other half. The same pandemic that infused Classic with isolation also included, for me, moments of stunning, stark
beauty that never would've come about otherwise — and the game should carry both. The void is beautiful and doesn't care that it is.
Awe is the payoff that makes the solitude worth choosing; without it, loneliness is just deprivation.

This makes the "world outside the window" feature (see ../DESIGN.md, open questions) theme-critical rather than a nice-to-have:
walking the cargo hold while a station slides past *is* this theme. Cutting thrust to coast should feel like something. And nothing
should ever reward looking — no screenshot achievements, no scenic-route bonuses. The moment beauty pays, it becomes a collectible.
It has to stay indifferent to you; that's the point.

## Competence, Not Power

Almost every game answers "what does the player become?" with *more powerful*. We answer it with *better at your job*. The design
already says this everywhere without naming it — the seat test asks whether the work itself is fun, meta-progression is variety-not-power,
and debt is escaped by doing your job well — so the theme should say it out loud: the fantasy is the clean dock, the perfect flip
point, the route math that saves the evening. Trucker in space. We do the job, we get paid.

This forbids things: no trade-bonus perks, no stat trees, no power curve inside a run. Skill expression lives in the player's hands
and choices, never in a number that grew. It's also part of why the loneliness is bearable: competence is company.

## Self-Sufficiency

In the black, there's nobody who's coming to save you. Crews should be encouraged to solve problems on their own in creative ways. We should facilitate
creative-problem solving however we can. For example, when we get to doing repairs, parts should be highly interchangeable, allowing choices like
"well we can fix the oxygen but only if we lose the ability to turn left". We should reward out-of-the-box thinking when we can; this is mostly
through "emergent gameplay" where we set up systems with clear rules and the system allows the player broad leeway within those rules. Modularity
helps with this. Rickety shoe-string contraptions match the vibe definitely.

Just as importantly, this theme forbids things: no rescue services or tow trucks (the desperation levers in ../DESIGN.md are things you
*do*, not things done for you), no cheap insurance that makes failure painless (robot respawn bills the wallet; foreclosure ends the run),
and no quest markers or handed-down solutions (contracts state problems; crews find approaches).

## Trust

Within a crew, trust is total and mechanical: anyone aboard can fly the ship, spend the wallet, vent the air. The game deliberately
does not protect you from your crewmates — that's what makes crew mean something. Letting someone aboard is the most meaningful
choice in the game; the Firefly fantasy isn't "a crew," it's *people who could ruin you and don't*. So: no permission tiers, no
ownership locks, no anti-betrayal systems inside the airlock.

The airlock is the boundary. In shared universes, other crews are outsiders — docking rights, boarding, and (eventually) piracy need
real permissions, for their sake and ours. Trust is a gift you give your crew, not a default the universe extends to strangers.

## Moral Ambiguity

Fights that initially appear morally obvious should often turn out to have two sides — and the interesting ones are where both sides
are partly right. Reversals have to be earned, though: no cheap shock-value twists ("actually they were innocent babies the whole
time!"); looking back, the player should be able to see the evidence was there all along. There should be quests that put you in
"Stanford Prison Experiment" like situations, if possible; you do a small bad thing, and become more willing to do a larger bad thing,
until you're a monster. "It is difficult to make a man understand something, if his salary depends upon him not understanding" is a key lesson
to demonstrate, ideally by making the player that man — and the debt clock (see ../DESIGN.md) is how. The run's shape, desperate then
solvent then greedy, is that staircase already built: if contract margins correlate with their moral griminess, the player's own loan
math walks them down it. The bank never asks you to become a monster; your payment schedule does.

The Senti question (see lore.md) is where this theme proves itself, and it doubles as the tone guardrail for the game's AI politics.
The signatory law reads at first glance as naked prejudice, and mostly is — but its defenders need real arguments: a signatory who can
die is a hostage to fortune, while a mind that can port to a new hull the moment the repo crew docks is genuinely hard to hold
accountable; personhood law is young, and law lags. Players who arrive sympathetic to the Senti should occasionally catch the Senti
side being wrong, and vice versa. A game built in deep cooperation with AI gets to make a wry, sad joke about AI — but it's a joke and
a question, never a sermon. Humans are the default start; the Senti layer is discovered depth, not the pitch.

## Consequences

The universe is small enough that your actions as a trader can have real impact on young settlements, and the run structure keeps those
consequences legible: they don't need to persist forever, just for a run. If you fail a contract to deliver water to a settlement, that
settlement should die out substantially — and it's unambiguously *your* failure, because contracts are first-come (see ../DESIGN.md),
so nobody's failure aggregates anonymously across strangers. Furthermore, there should be situations where you have to make impossible
choices; say, you end up having to choose to let a settlement die in favor of saving a different one. People should send out bounty
hunters to kill you as a result of those choices. All of it — bounty hunters, cold shoulders, dying settlements — arrives within the
run's few hours, which is what makes it dramatic instead of a database entry. And though the run ends, in the fiction the universe
doesn't: the settlement you saved — or starved — is still out there, in a world that keeps going without you. You were a citizen of
that world, never its protagonist, and the mark you left doesn't need you around to be real.

## Clout

In addition to monetary currency, you should be able to develop reputations, with individuals and also with factions. A good reputation
gets you good jobs and "friend" prices. A bad reputation gets you subtle cold shoulders, and eventually outright banned or hunted.
Reputation is per-run (see ../DESIGN.md): fresh world, fresh relationships, generated alongside the faction control map — so clout is
something you build and spend within an evening, a story beat rather than a meta-currency you grind.

## Panic

The game should not reward panic or twitch behavior if possible. Games reinforce this human instinct badly, I think.
In the modern world it's almost always best to take 30 seconds and think about a problem before you act on it. If possible, we
should make the knee-jerk solution in a crisis the wrong one; the best solution should be the one you find by stopping to think.
Put positively: crises should reward diagnosis and triage. FTL — already our inspiration — is secretly a pause-and-plan game wearing a
real-time costume; that's the model. The paper-captain grace window (see ../DESIGN.md) is an example already in the design: your ship's
legal person dies, and the winning move is not a frantic burn but thirty seconds of route math about which port can sell you a new
signatory in time.

## Faith

Everyone's done it, but exploring religion in space is always interesting. Space Catholics? The Expanse did Space Mormons already.
Being part of a religion, and having faith, is enormously beneficial regardless of whether the religion is true. I wonder if it's
possible to model that. The naive version — you say religious words to a religious guy and he gives you better prices — doesn't feel
like it'd feel the same as it does in real life: players will never really be part of the religion, so they could only ever choose
those options falsely.

The more solvable version is that real faith's worldly benefits are largely **costly signaling and community insurance**. Tithe;
observe constraints that genuinely cost you (no flying on holy days? certain cargo refused?); and in exchange the congregation bails
you out when you're stranded and broke. That models "faith is beneficial regardless of whether it's true" without needing the player
to believe anything — the cost is real either way. Lying remains its own path: "untruths are like debts which must eventually be
repaid, with interest". Saying the words without paying the costs is a dice-roll gamble, and failing that roll *really* gets you in
hot water with the fanatics.

## Governance

The game should depict both left-wing and right-wing governments, and should portray them with both positive and negative characteristics.
The aim is portrait, not lecture — though the line is razor-thin, because a good portrait *is* pedagogy; good art is what changes us.
The difference is aim: paint each system honestly, flaws rendered with the same care as virtues, and let players conclude what they
conclude. The moment a player feels targeted — "hey, this is strawmanning my political system!" — the portrait has failed as art and
as argument both.

That being said, given the sparseness of the universe, a firefly-like libertarian bent is pretty natural, and a skepticism
of all government is sort of implicit if you're a space peddler. Successful-looking governments should be small, not spread too thin.
That's itself a political stance, not neutrality — better to own it as the game's creative lean, with the left/right even-handedness
above applying *within* that frame, than to pretend to a neutrality we don't have. Pretending is how you end up strawmanning.
