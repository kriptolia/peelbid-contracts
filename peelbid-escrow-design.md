# peelbid — escrow and data model

**Status:** draft for review · 29 August 2026
**Purpose:** settle the mechanics on paper before any Solidity is written.

---

## 1. Principles

Four rules that decide every argument below.

**peelbid never holds a balance.** There is no wallet, no deposit account, no withdrawal. Money moves from the sponsor's wallet into a per-campaign escrow, then out to the owner or back to the sponsor. We are never the counterparty to anyone's funds. This is not a design preference — holding pooled user funds is a licensed activity in most jurisdictions, and there is nothing to gain by touching that line.

**Default to paying out.** Every automated decision resolves toward releasing money to the owner. The sponsor must take an action to stop it. If the reverse were true, sponsors could hold owners hostage by simply not clicking approve.

**We verify nothing physical.** No contract can know whether a sticker is still on a car. Everything downstream is designed around that limitation instead of pretending it away.

**One arbiter in v1, and we say so.** Disputes are resolved by the operator. Decentralised arbitration is months of work that the first fifty campaigns do not need. It goes in the terms in plain language.

### Non-goals for v1

- No account balances, no internal transfers
- No secondary market for won panels
- No automated physical verification
- No cross-chain anything
- No token

---

## 2. On-chain vs off-chain

The contract holds money and enforces time. Everything else lives in Postgres.

| On-chain | Off-chain |
|---|---|
| Bid deposits and refunds | Listings, photos, panel geometry |
| Escrow per campaign | Auction UI, bid history display |
| Tranche release schedule and timers | Owner approval decisions |
| Dispute freeze flag | Proof media and metadata |
| Fee split | Messaging, notifications |
| Hash of each accepted proof | Everything a human reads |

**Why proof hashes go on-chain but proof media doesn't.** Storing the media hash makes the evidence tamper-evident without paying to store images on a blockchain. If a dispute ever goes outside the platform, both parties can prove what was submitted and when.

Media goes to object storage with a content hash. IPFS is optional and adds nothing at this stage — revisit if a sponsor asks for it.

---

## 3. Entities

### Listing
The physical object.

```
id, owner_address, title, object_type
context_text          -- REQUIRED. where it goes, how often, who sees it.
reference_photo       -- side / rear / whatever the panels sit on
reference_measurement -- one real dimension in mm, anchors panel scale
allowed_durations[]   -- subset of [1, 3, 6, 12] months
status                -- see state machine
created_at, published_at
```

`context_text` is required and cannot be empty. It is the only thing a sponsor can actually evaluate. A guitar case is worth nothing; a guitar case that plays a named café every Thursday is worth something.

### Panel
A rentable zone on a listing.

```
id, listing_id, name, position_json  -- x/y/w/h in mm on the reference photo
width_mm, height_mm                  -- true size, derived from reference_measurement
floor_price_usdc                     -- owner sets it
status
```

### Auction
One per panel per cycle.

```
id, panel_id, opens_at, closes_at
min_increment_usdc   -- default 10
status
```

### Bid

```
id, auction_id, bidder_address
amount_usdc, duration_months
monthly_rate_usdc    -- amount / duration. THE RANKING FIELD.
deposit_tx, deposit_amount   -- 10% of amount
status
```

**Bids rank on `monthly_rate_usdc`, not on total.** Without this, a twelve-month bid always beats a one-month bid regardless of value, and the owner cannot compare them. The UI shows both numbers on every bid so nobody has to do arithmetic.

### Campaign
Created when a bid wins and is approved.

```
id, panel_id, sponsor_address, owner_address
total_usdc, duration_months, escrow_contract_address
artwork_ref, starts_at, ends_at
status
```

### Tranche

```
id, campaign_id, sequence, percent, amount_usdc
due_at, released_at
status   -- pending | proof_submitted | challenge_window | released | frozen | refunded
```

### Proof

```
id, campaign_id, tranche_id, captured_at, capture_method
media_ref, media_hash, freshness_token, notes
status   -- submitted | accepted | challenged | rejected
```

### Dispute

```
id, campaign_id, tranche_id, raised_by, reason, evidence_refs[]
resolution   -- release | refund | split
resolved_by, resolved_at, rationale_text
```

---

## 4. State machines

### Listing
```
draft → published → paused → published
                  → archived
```
A listing can only be archived when it has no active campaigns.

### Auction
```
open → closed_won        (had bids)
     → closed_no_bids
     → cancelled          (owner pulled the listing; all deposits refunded)
```

### Bid
```
active → outbid → refunded
       → won → approved → paid → (becomes a campaign)
                        → forfeited        (didn't pay in 48h; deposit to owner)
             → rejected → refunded         (owner said no; full refund, no penalty)
```

Rejection refunds in full. The bidder did nothing wrong by being turned down, and charging them would make the approval step feel like a trap.

### Campaign
```
awaiting_artwork → awaiting_application → active
active → tranche cycle (see §6) → completed
       → terminated_early   (dispute upheld; remaining escrow returns to sponsor)
       → abandoned          (sticker never applied; full refund)
```

---

## 5. Money flow

### At bid time
Sponsor locks **10% of the bid** as a deposit.

- Outbid → refunded automatically, same block as the higher bid
- Won and rejected by owner → refunded in full
- Won, approved, didn't pay within 48h → **deposit goes to the owner**, panel offered to the next bidder

The forfeit is the entire point of the deposit. It makes a fake bid cost something and compensates the owner for a wasted auction. Without it, anyone can bid $5,000, win, vanish, and the owner has lost three weeks.

### At approval
Owner approves the winning bidder. **48 hours** to deposit the remaining 90% into the campaign escrow.

Approval sits *after* the auction closes, not before bidding. Screening every bidder up front is too much work for the owner and too much friction for the auction.

### During the campaign
Escrow releases in tranches. Our **8% fee is taken pro-rata from each tranche** as it releases, not up front — if the campaign terminates early, we haven't been paid for months that never happened.

### Refunds
Always to the originating address. No alternate-address refunds; that is an attack surface for no benefit.

---

## 6. Tranche schedule

**Rule:** first tranche 25% on application, last tranche 20% on completion, the remaining 55% split evenly across the intermediate monthly checkpoints.

| Duration | Schedule |
|---|---|
| 1 month | 40% on application · 60% on completion |
| 3 months | 25% · 27.5% · 27.5% · 20% |
| 6 months | 25% · 11% × 5 · 20% |
| 12 months | 25% · 5% × 11 · 20% |

**Why the last tranche is the biggest.** With even splits, the owner's incentive to keep the sticker on decays every month — by month five they have most of the money and little reason to care. A heavy final tranche is a completion bond. Removing the sticker in month five costs them the single largest payment.

### Release cycle per tranche

```
tranche due
  → owner submits proof
  → 7-day challenge window opens
  → sponsor does nothing  → released automatically
  → sponsor challenges    → frozen → arbiter decides
  → owner submits nothing within 14 days → tranche refunds to sponsor,
                                            campaign flagged, later tranches at risk
```

Optimistic release. The sponsor has to act to stop the money, not act to permit it.

**Only the disputed tranche freezes.** A challenge on month three does not lock months four through six. Otherwise one bad-faith challenge kills the whole campaign.

---

## 7. Proof protocol

This is where the design is most exposed, so it gets the most attention.

**Attack:** owner photographs the sticker once on day one, submits the same shot for six months, and removes the sticker in week two.

**Countermeasures, in order of importance:**

**In-app capture only.** No gallery uploads. The photo is taken through the app, timestamped server-side on receipt. This alone defeats the lazy version of the attack.

**A freshness token must be visible in the shot.** The system issues a short code when a proof is requested; the owner writes it on paper, or shows it on a phone screen, in frame next to the sticker. Cheap for an honest owner, and it makes each photo non-reusable.

**A changing element.** For vehicles, the odometer in the same frame. It moves, it is hard to fake, and it doubles as evidence the object is actually being used — which is what the sponsor bought.

**One unscheduled proof request per campaign.** The sponsor can call for a proof at any time, once, with 72 hours to respond. Unlimited requests would let a sponsor harass an owner into abandoning the campaign; one is enough to make continuous compliance the cheapest strategy.

**Open question:** should the freshness token be sponsor-chosen or system-generated? Sponsor-chosen is stronger evidence and better theatre. System-generated is one less thing for the sponsor to do. Leaning system-generated for v1.

---

## 8. Disputes

**Who can raise one:** the sponsor, during a challenge window. The owner, if a tranche is withheld unfairly.

**What freezes:** the disputed tranche only.

**Who decides in v1:** the operator. Stated plainly in the terms — no pretence of decentralisation.

**Outcomes:** release to owner · refund to sponsor · split at the arbiter's discretion.

**Early termination:** if a dispute establishes the sticker was removed early, remaining escrow returns to the sponsor. Already-released tranches stay with the owner — they were paid for months that were served.

**Target:** resolve within 5 business days. Publish the count of disputes and their outcomes. A platform that hides its dispute rate is a platform with a bad one.

---

## 9. Contract sketch

Not final Solidity — the shape, so the data model and the contract agree.

```
PeelbidEscrow

  createCampaign(campaignId, owner, sponsor, totalAmount,
                 trancheePercents[], trancheeDueDates[], feeBps)
  fund(campaignId)                      -- sponsor transfers USDC in
  submitProof(campaignId, trancheIndex, proofHash)
  challenge(campaignId, trancheIndex)   -- sponsor only, within window
  release(campaignId, trancheIndex)     -- anyone can call after window closes
  resolve(campaignId, trancheIndex, outcome, ownerShareBps)  -- arbiter only
  refundRemaining(campaignId)           -- arbiter only, on upheld termination

PeelbidAuction

  placeBid(auctionId, amount, durationMonths)   -- pulls 10% deposit
  withdrawOutbidDeposit(bidId)
  settle(auctionId)                             -- marks winner, starts 48h clock
  forfeit(bidId)                                -- after 48h, deposit to owner
```

`release()` being callable by anyone matters: the money must not depend on our server staying up. If peelbid disappears, an owner can still trigger their own release once the challenge window has passed.

### Security notes before writing any of this

- USDC has 6 decimals, not 18. Fixing this after launch means a migration.
- Use `SafeERC20`. USDC is upgradeable and its behaviour can change.
- Reentrancy guards on every function that moves tokens.
- No unbounded loops over tranches — twelve is small, but bound it anyway.
- Pausable, with a documented and narrow reason for pausing.
- **Get an audit before real money.** Not optional. Budget for it, or cap total escrow value until it's done.

---

## 10. Decisions still open

1. **Auction length** — owner-set, or fixed at 21 days? Owner-set is more flexible; fixed is easier to explain and to market.
2. **Freshness token** — sponsor-chosen or system-generated?
3. **Artwork rejection** — the owner approved the sponsor, then the sponsor sends artwork the owner won't apply. Where does that money go? Currently unhandled and it *will* happen.
4. **Multi-panel bidding** — can one sponsor take five panels on one object in a single transaction, or five separate auctions?
5. **Chain** — Base first, Arc after mainnet. Confirm the contract stays chain-agnostic EVM so this is a deploy, not a rewrite.

Item 3 is the real gap. Everything else can ship with a reasonable default.
