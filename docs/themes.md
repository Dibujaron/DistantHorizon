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

Our 2026 remake of DH should still capture some of this feeling, I think; there's something in it that I like.
I imagine it could translate fairly well with single-crew ships. Multi-crew ships will be different, obviously, because you're not alone;
this becomes more like the Firefly fantasy, of a tight-knit crew together, alone against the universe. 
Then it becomes more unambiguously a positive loneliness.

The run structure (see ../DESIGN.md) already encodes the solo version well: in shared universes, other crews appear mostly as burns
seen across the system — interaction at great distance, Classic's loneliness upgraded rather than lost. The lever to protect going
forward: **concourse density and tone are a loneliness dial.** Stations should stay sparse, transactional, and a little alienating —
a few brokers, security, signage, quiet. Nobody should later "improve" them into bustling taverns without noticing that it spends this theme.

## Self-Sufficiency

In the black, there's nobody who's coming to save you. Crews should be encouraged to solve problems on their own in creative ways. We should facilitate
creative-problem solving however we can. For example, when we get to doing repairs, parts should be highly interchangable, allowing choices like
"well we can fix the oxygen but only if we lose the ability to turn left". We should reward out-of-the-box thinking when we can; this is mostly
through "emergent gameplay" where we set up systems with clear rules and the system allows the player broad leeway within those rules. Modularity
helps with this. 

Rickety shoe-string contraptions match the vibe definitely.

A theme earns its place by forbidding things. This one rules out:

- Rescue services and tow trucks. Nobody is coming; the desperation levers (see ../DESIGN.md) are things you *do*, not things done for you.
- Cheap insurance that makes failure painless. Robot respawn bills the wallet; foreclosure ends the run.
- Quest markers and handed-down solutions. Contracts state problems; crews find approaches.

## Moral Ambiguity

Fights that initially appear morally obvious, should later be revealed to not be. There are two sides to every argument.
Everything you think is right can be wrong in a different place and time. There should be quests that put you in
"Stanford Prison Experiment" like situations, if possible; you do a small bad thing, and become more willing to do a larger bad thing,
until you're a monster. "It is difficult to make a man understand something, if his salary depends upon him not understanding" is a key lesson
to demonstrate, ideally by making the player that man.

**Debt is the corruption engine.** The run's shape — desperate, then solvent, then greedy (see ../DESIGN.md) — is the Stanford staircase
already built. Contracts whose margins correlate with their moral griminess let the player's own loan math walk them down it: the bank
never asks you to become a monster; your payment schedule does. "Salary depends on not understanding" becomes literal.

**The Senti question is where this theme proves itself — and it's the tone guardrail for the game's AI politics.** The signatory law
(see lore.md) reads at first glance as naked prejudice, and mostly is. But per this theme its defenders must have real arguments: a
signatory who can die is a hostage to fortune, while a mind that can port to a new hull the moment the repo crew docks is genuinely
hard to hold accountable; personhood law is young, and law lags. Players who arrive sympathetic to the Senti should occasionally catch
the Senti side being wrong, and vice versa. A game built in deep cooperation with AI gets to make a wry, sad joke about AI — but it's
a joke and a question, never a sermon. Humans are the default start; the Senti layer is discovered depth, not the pitch.

## Consequences

The universe is small enough that your actions as a trader can have real impact on young settlements.
If you fail a contract to deliver water to a settlement, that settlement should die out substantially.
Furthermore, There should be situations where you have to make impossible choices, say, you end up having to choose to let a
settlement die in favor of saving a different one. People should send out bounty hunters to kill you as a result of those choices.

(Recast for the run structure — this section was originally written with Classic's persistent world in mind.) Consequences don't need
to persist forever; they need to persist *for a run*, which is exactly the scale where they stay legible. Fail the water contract and
by retirement that port is a ghost town — and it's unambiguously yours, because contracts are first-come (see ../DESIGN.md), so nobody's
failure aggregates anonymously across strangers. Bounty hunters, cold shoulders, and dying settlements all arrive within the run's few
hours, which is what makes them dramatic instead of a database entry.

## Clout

In addition to monetary currency, you should be able to develop reputations, with individuals and also with factions. A good reputation
gets you good jobs and "friend" prices. A bad reputation gets you subtle cold shoulders, and eventually outright banned or hunted.

Reputation is per-run (see ../DESIGN.md): fresh world, fresh relationships, generated alongside the faction control map. Clout is
therefore something you build and spend *within an evening*, not a standing you grind — which keeps it a story beat rather than a
meta-currency.

## Panic

The game should not reward panic or twitch behavior if possible. Games reinforce this human instinct badly, I think.
In the modern world it's almost always best to take 30 seconds and think about a problem before you act on it. If possible, we
should make the knee-jerk solution in a crisis the wrong one; the best solution should be the one you find by stopping to think.

The positive version: crises should reward diagnosis and triage. FTL — already our inspiration — is secretly a pause-and-plan game
wearing a real-time costume; that's the model. An example already in the design: the paper-captain grace window (see ../DESIGN.md) —
your ship's legal person dies, and the winning move is not a frantic burn but thirty seconds of route math about which port can sell
you a new signatory in time.

## Faith

Everyone's done it, but exploring religion in space is always interesting. Space Catholics? The Expanse did Space Mormons already.
Being part of a religion, and having faith, is enormously beneficial regardless of whether the religion is true.
I wonder if it's possible to model that. Certainly the reputation system could help with that; if you're willing to say
religious words to a religious guy he'll give you better prices.

Somehow that doesn't feel like it'd feel the same as it does in real life. Players will never really be part of the religion,
so they could only ever choose those options falsely. Maybe the player could have 'true' beliefs and lying about them
costs you somehow, morally? Hmm. "Untruths are like debts which must eventually be repaid, with interest". Maybe it's a dice
roll to lie, and failing that roll *really* gets you in hot water with the fanatics.

The more solvable version: real faith's worldly benefits are largely **costly signaling and community insurance**. Tithe; observe
constraints that genuinely cost you (no flying on holy days? certain cargo refused?); and in exchange the congregation bails you out
when you're stranded and broke. That models "faith is beneficial regardless of whether it's true" without needing the player to
believe anything — the cost is real either way. The dice-roll-to-lie idea then covers the impostor path: saying the words without
paying the costs is the gamble, and failing the roll with fanatics is how it goes wrong.

## Governance

The game should depict both left-wing and right-wing governments, and should portray them with both positive and negative characteristcs.
Ideally, politically-minded people should instantly be drawn to the one that matches their predilictions, and then should gently
realize *on their own* some of the real shortcomings of the system. This should be done delicately, subtly, and in a way
that people go "ahhh interesting" and not "hey, this is strawmanning my political system!"

That being said, given the sparseness of the universe, a firefly-like liberatarian bent is pretty natural, and a skepticism
of all government is sort of implicit if you're a space peddler. Successful-looking governments should be small, not spread too thin.

Honesty note: "skepticism of all government" plus "successful governments are small" is itself a political stance, not neutrality.
Own it as the game's creative lean — the left/right even-handedness above applies *within* that frame, and pretending otherwise is
how you end up strawmanning.
