# Site plan — from here

Written 17 September, after Arc mainnet and with the auction contract mid-cycle
on testnet.

---

## Where the site actually is

Working: waitlist and Peels, invite-gated listing, the builder, published
listing pages, a public directory, off-chain bidding with artwork and owner
approval, in-app notifications, four worked examples, a live escrow reader
across four chains.

Missing, in the order it hurts:

1. **Nobody is told anything.** A bid arrives and the owner finds out only by
   visiting the dashboard. This is the single biggest gap and it is unglamorous.
2. **The site doesn't use the contract.** Bids live in Postgres. The auction
   contract exists, holds a real deposit on testnet, and the site doesn't know.
3. **Listings are thin where it matters.** The context paragraph is what a
   sponsor buys, and most people will write "great visibility" unless helped.
4. **No proof feed.** The differentiator, still unbuilt.

---

## The AI question, re-examined

Checked against what the tooling actually does in September 2026, not against
what it did when §13 was written.

### The mockup: generative models are the wrong tool, and that is now provable

The plan had been to revisit the mockup with an image model. Current tooling
says don't. The consistent complaint across product-photography tools is that
generated output distorts exactly what must not change — "shapes, text, and
logos on products are frequently distorted".

A sponsor's logo is the one thing in the frame that has to survive byte for
byte. An image model that gets the lighting right and the wordmark subtly wrong
is worse than no mockup, because it is wrong in a way the owner won't catch and
the sponsor will.

The industry's own answer is the one we already implemented: keep the product
pixels untouched, composite them in, and let the model handle only the
surroundings. Our `lib/warp.js` does the compositing correctly. What failed was
the relighting pass, and that is a compositing problem, not a model problem.

**Revised position:** the mockup stays shelved, and when it comes back it comes
back as better compositing — per-surface lighting parameters the owner sets
once — not as a generated image. §13's "probably an image-model job" was wrong.

### Where a model does earn its place

**Writing the context paragraph.** The highest-value use and the cheapest. A
listing lives or dies on "Kadıköy to Levent every weekday, 2,800 km a month,
street parking in Moda" versus "great visibility". Most people write the second.

A short interview — where does it go, how often, who sees it — turned into a
draft the owner edits. Text model, fractions of a cent, and it lifts the one
thing that decides whether a listing gets bids. Nothing is published without the
owner editing it.

**Panel suggestion.** Segment the photo into flat surfaces and propose panels
the owner then drags. Commodity now. Assistive only: the owner's adjustment is
the truth, and a suggestion that crosses a door shut would teach someone to
violate the print spec in §7b.

**Scale from a reference.** Number plates are 520×110 mm across the EU and
Turkey. Detect one and every other dimension follows, removing the step most
likely to make somebody give up. Narrow detection problem, well-scoped.

**Proof checking.** Strategically the most valuable — verification is the gap
the whole category leaves open — and the hardest. Permanently assistive: it
flags a proof for human review, never rejects one. A false rejection costs an
owner a tranche they earned and the contract cannot undo a release.

### Still not doing
Chatbots. Agents bidding on anyone's behalf. Auto-approving sponsors — the
owner's veto is the product, and delegating it to a model gives away the thing
being sold. Anything "agentic" that exists in order to be described as agentic.

---

## Order of work

### 1. Email
Nothing else matters if people aren't told. Bid received, bid approved, bid
declined, revision requested, tranche released, invited from the waitlist.

Six templates, one provider, an unsubscribe link. Unglamorous and overdue.

### 2. Context-writing help in the builder
Three questions, a drafted paragraph, the owner edits it. Ships in a day and
raises the quality of every listing that follows.

Two guardrails: nothing is published without the owner editing it, and the
prompt must refuse to invent specifics. A model that writes "covers 3,000 km a
month" when the owner said "quite a lot" has manufactured a claim a sponsor will
later rely on.

### 3. Wire the site to the auction contract
Only after the testnet walkthrough finishes, including the four paths that have
never run on a chain.

The shape: the site keeps the catalogue — listings, photos, panel geometry,
artwork files — and the contract keeps the money and the ranking. A bid becomes
a transaction from the bidder's embedded wallet. The site reads state from the
chain rather than from its own tables.

Artwork stays off-chain with its hash on-chain, which is what makes the owner's
single approval binding on both the sponsor and the creative.

### 4. Panel suggestion and plate-based scale
After there are real listings to test against. Building either on four stock
photos would be guessing twice.

### 5. Proof feed
The differentiator. Capture in-app, timestamp, show on the campaign page, hash
to the contract. Deserves its own design pass.

---

## What not to do next

**Don't open listing to everyone.** The gate is what makes the waitlist mean
something, and the first listings set the standard for every one after.

**Don't fund a mainnet campaign yet.** Two testnet releases prove the cycle;
they don't prove this build of it.

**Don't add a second chain's worth of surface area** before the auction has run
its four remaining paths on one.
