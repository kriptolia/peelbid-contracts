# peelbid — escrow and data model

**Status:** escrow v2 on Arc mainnet · auction contract live on Arc testnet, first cycle running · 17 September 2026
**Purpose:** settle the mechanics on paper before any Solidity is written.

---

## 1. Principles

Four rules that decide every argument below.

**peelbid never holds a balance.** There is no wallet, no deposit account, no withdrawal. Money moves from the sponsor's wallet into a per-campaign escrow, then out to the owner or back to the sponsor. We are never the counterparty to anyone's funds. This is not a design preference — holding pooled user funds is a licensed activity in most jurisdictions, and there is nothing to gain by touching that line.

**Default to paying out.** Every automated decision resolves toward releasing money to the owner. The sponsor must take an action to stop it. If the reverse were true, sponsors could hold owners hostage by simply not clicking approve.

**We verify nothing physical.** No contract can know whether a sticker is still on a car. Everything downstream is designed around that limitation instead of pretending it away.

**Ship the risk in stages.** There is no audit budget yet, so exposure is capped in code rather than assumed away. See §11.

**One arbiter in v1, and we say so.** Disputes are resolved by the operator. Decentralised arbitration is months of work that the first fifty campaigns do not need. It goes in the terms in plain language.

### Non-goals for v1

- No account balances, no internal transfers
- No secondary market for won panels
- No automated physical verification
- No cross-chain anything
- No token
- No auction logic on-chain — the contract holds money, nothing else

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
floor_price_usdc                     -- owner sets it, minimum 50 USDC
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
artwork_ref          -- REQUIRED. submitted with the bid, not after.
deposit_tx, deposit_amount   -- 10% of amount
status
```

**Artwork is submitted with the bid.** This closes the gap where an owner approves a sponsor, then refuses the creative they send, with money already in escrow and nobody at fault. One approval covers the sponsor *and* the artwork, so that second failure mode never exists. It costs the bidder nothing — a brand placing a bid already has its logo — and it gives the owner the thing they actually care about: seeing what will go on their property before saying yes.

The owner may request **one revision** before deciding, with 48 hours for the bidder to resubmit. That's the soft alternative to a flat rejection.

**Panels have a 50 USDC floor.** The owner pays for printing out of pocket and is reimbursed by the first tranche. On a 300 USDC campaign that first tranche is 75 USDC against a 15–30 USDC print — comfortable. On a 75 USDC campaign it is 18 USDC against the same print, and the owner has worked for nothing. Below 50 USDC the economics stop making sense for the person doing the physical work, so listings can't go there.

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
       → won → revision_requested → active   (owner wants different artwork; 48h)
             → approved → paid → (becomes a campaign)
                        → forfeited          (didn't pay in 48h; deposit to owner)
             → rejected → refunded           (owner said no to sponsor or artwork; full refund)
```

Rejection refunds in full. The bidder did nothing wrong by being turned down, and charging them would make the approval step feel like a trap.

### Campaign
```
awaiting_application → active
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
Owner approves the winning bidder — **sponsor and artwork together, one decision**. The bidder then has **48 hours** to deposit the remaining 90% into the campaign escrow.

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

## 7b. Application: window, cost and quality

### Who pays for printing
The owner does, up front. The first tranche is 25% precisely to cover it — a die-cut cast vinyl print runs roughly 15–30 USDC and the first tranche on a mid-size campaign is several times that. The owner is out of pocket for about eight days, then reimbursed with margin.

Later, peelbid may print and ship stickers itself: quality becomes controllable, bulk printing is cheaper, and it becomes a second revenue line. Not in v1 — the operational load would swamp everything else.

### The window
**14 days from funding to apply the sticker.** Contour-cut cast vinyl takes 2–5 days at a print shop, so 14 is generous without being lax.

**The campaign clock starts at application, not at payment.** Tranche due dates are computed when the first proof is accepted. Otherwise an owner who dawdles for twelve days costs the sponsor twelve days of a campaign they already paid for.

**Miss the window and the sponsor is refunded in full.** The owner isn't penalised financially — they have no deposit at stake — but the account is flagged and can't list again. Off-chain reputation is enough at this scale.

### Print specification — mandatory

- **Cast vinyl, not calendered.** Calendered film lifts at the edges within months, fades, and shrinks back from the cut line. Cast film conforms to the surface and lasts 5–7 years. This single line is the difference between a campaign that looks good in month five and one that embarrasses both parties.
- Minimum **3-year outdoor-rated** film
- **UV laminate** required on vehicle panels
- **Contour cut** to the shape of the mark, not a rectangular block
- Applied to a clean, dry, degreased surface, **above 10°C**

### Not permitted

- Over damaged paint, rust or deep scratches
- Bridging panel gaps or door shuts
- On flexible plastic trim
- On glass, except the rear window, and there only as perforated one-way film

### First proof — what's required

Remote inspection is impossible, so the proof itself is the inspection.

1. **Close-up still** — cut quality and edge adhesion visible
2. **Still from two metres** — placement and overall look
3. **A short video pan**, roughly 10–15 seconds, moving continuously from the whole object in to the sticker. A continuous take is far harder to fake than a still, and this is the highest-stakes proof in the campaign.
4. **The print invoice or order slip**, with the film type on it

The fourth is the quietly effective one. Requiring an invoice pushes the owner to order the right material in the first place, before anything is stuck to anything.

### Proof media by tranche

| Tranche | Required |
|---|---|
| Application | Two stills, video pan, print invoice |
| Monthly checkpoints | One still with the freshness token visible |
| Unscheduled request | Video pan with the freshness token visible |
| Completion | Two stills and a video pan |

Video only where it earns its cost. Asking for a video every month burns the owner's patience and mobile data, and patience is what keeps a campaign alive to month six.

### If quality fails
The seven-day challenge window on the first tranche *is* the quality check — the sponsor sees the proof and objects if it's wrong. No separate approval step.

But if an arbiter finds the work below spec, the owner gets **7 days to reprint and resubmit** before any refund is considered. Otherwise the owner loses both the print cost and the campaign for a fixable mistake, which is out of proportion to the error.

---

## 8. Disputes

**Who can raise one:** the sponsor, during a challenge window. The owner, if a tranche is withheld unfairly.

**What freezes:** the disputed tranche only.

**Who decides in v1:** the operator. Stated plainly in the terms — no pretence of decentralisation.

**Outcomes:** release to owner · refund to sponsor · split at the arbiter's discretion.

**Early termination:** if a dispute establishes the sticker was removed early, remaining escrow returns to the sponsor. Already-released tranches stay with the owner — they were paid for months that were served.

**Target:** resolve within 5 business days. Publish the count of disputes and their outcomes. A platform that hides its dispute rate is a platform with a bad one.

---

## 9. Contract — as implemented

`src/PeelbidEscrow.sol`, Foundry, OpenZeppelin v5.7, solc pinned to 0.8.36. 27 scenario tests, 4 invariants over 16,384 random calls, Slither with no High or Medium findings.

### Functions

| Function | Who | What |
|---|---|---|
| `createCampaign(id, owner, sponsor, total, feeBps, percents[], offsetDays[])` | operator | Records terms. No money moves. |
| `fund(id)` | sponsor | Pulls USDC in. Starts the 14-day application window. |
| `submitProof(id, index, hash)` | owner | Index 0 = sticker applied; sets `appliedAt` and starts the clock. Others gated by `appliedAt + offsetDays`. |
| `release(id, index)` | **anyone** | Pays the tranche once the 7-day window has passed unchallenged. Fee taken pro-rata. |
| `challenge(id, index)` | sponsor | Freezes that tranche only, inside the window. |
| `resolve(id, index, ownerShareBps)` | arbiter | Splits a frozen tranche. Fee only on the owner's portion. |
| `terminate(id)` | arbiter | Sticker removed early. Refunds everything not yet released. |
| `reclaimUnapplied(id)` | sponsor | Sticker never applied within 14 days. Full refund, **no arbiter needed**. |
| `reclaimMissedTranche(id, index)` | sponsor | Owner went silent on a due checkpoint for 14 days. That tranche refunds, no arbiter. |
| `pause` / `unpause` / `setArbiter` / `setFeeRecipient` | operator | Admin. |

### Decisions baked into the code

**Tranches store day offsets, not dates.** `dueAt(id, index)` computes `appliedAt + offsetDays * 1 day` on the fly. This is what makes the clock start at application rather than at payment — the first draft got this wrong and a test caught it.

**`release()` is permissionless.** If peelbid's server is down, an owner can still trigger their own payout after the window closes. The money does not depend on us.

**Only the challenged tranche freezes.** `test_ChallengeOnlyFreezesThatTranche` proves month 3 proceeds while month 2 is in dispute.

**Fees only on money the owner actually receives.** A 50/50 resolution charges 8% on the owner's half, nothing on the sponsor's refund.

**`terminate` leaves released tranches alone.** Served months stay paid.

**The caps are constants.** `MAX_CAMPAIGN = 500e6`, `MAX_TOTAL = 5_000e6`. Not admin-settable. Raising them means redeploying — deliberately.

**Checks-effects-interactions everywhere.** Every state write precedes every token transfer. `nonReentrant` on every function that moves tokens.

### Accounting invariant
For every campaign: `paidOut + refunded <= total`. For the contract: `USDC balance >= totalEscrowed`, and `totalEscrowed == Σ outstanding(id)`. Enforced by invariant tests (next step) and asserted in the full-lifecycle test: 300 in, 276 to owner + 24 fee out, 0 stuck.

### Known dust
Tranche amounts are `total * percentBps / 10_000` with integer division. Across 13 tranches the rounding remainder is at most 13 micro-USDC per campaign, left in the contract. Acceptable; noted.

### Static analysis — Slither 0.11.4
32 results, none High or Medium. Breakdown:

- `assembly`, `pragma`, `solc-version` — all from OpenZeppelin and forge-std, not our code. Our contract is pinned to 0.8.36; the listed historical bugs don't apply.
- `timestamp` — expected. Every window is measured in days; a ±15s miner drift is irrelevant. Slither also files unrelated comparisons (`index >= length`, `fee > 0`) under this heading — tool quirk.
- `divide-before-multiply` in `resolve` — two floor divisions in sequence. Fee may be short by at most 1 micro-USDC versus the exact figure. Direction is conservative (never overpays), totals still reconcile exactly, and invariants confirm it. Left as is.
- `uninitialized-local`, `naming-convention`, `cyclomatic-complexity`, `unindexed-event-address` — cosmetic.

### Invariants — as enforced
Handler drives nine actions in random order across 256 runs × 64 steps. After every step:
1. `paidOut + refunded <= total` for every campaign
2. `USDC balance >= totalEscrowed`
3. `totalEscrowed == Σ outstanding(id)`
4. `Σ total − Σ paidOut − Σ refunded == totalEscrowed`

### Deployed — Arc mainnet
| | |
|---|---|
| Contract | `0xCDfad58266dAe603c542984A7C8e8e72b8c617C9` |
| Chain | Arc (5042) |
| Deploy tx | `0xe8f4a9f48663d2e3621c8cde97f8bde3847d471bc1b33dd09b72612349f57899` |
| Block | 21149738 · 16 Sep 2026, the day Arc's public mainnet opened |
| USDC | `0x3600000000000000000000000000000000000000` |
| Owner / arbiter / fee recipient | `0xc2C9F41778Dda1dd38C6D0b08eC730D675c7bA2C` (Safe) |
| `campaignCreator` | zero — deliberately unset |
| Source | Verified |
| Cost | **0.068 USDC** |

This is escrow **v2**: the `campaignCreator` role and `fundOnBehalf`, compiled through via-IR. Deployed from a wallet used for nothing else, handed to the Safe in the same session.

`campaignCreator` stays at zero until the auction contract has run a full cycle on testnet. Until then v2 behaves exactly as v1 did — only the Safe can create a campaign.

### Gas on Arc: the testnet numbers were wrong

The measurements in §9 said our own cost would be about 2.43 USDC per campaign, and that a 50 USDC campaign would lose 60% of its fee to gas. That was going to force a higher floor price on Arc.

Mainnet, day one:

| | Testnet | Mainnet |
|---|---|---|
| Gas price | 2,800–16,000 gwei | **35 gwei** |
| Deploying the escrow | 20.95 USDC | **0.068 USDC** |

Three hundred times cheaper. The testnet figures were launch-week congestion, not the fee model — Circle's designed base fee is what mainnet actually charges.

**So the floor stays at 50 USDC on Arc.** The §13 note about raising it, and the §9 warning about campaign economics, are both withdrawn.

Worth remembering as a general point: a testnet measured in the week before its mainnet opens tells you about the crowd, not about the chain.

### Deployed — Base mainnet
| | |
|---|---|
| Contract | `0xf78257D41C8e78dD19e941146B58ebe9f9726635` |
| Chain | Base (8453) |
| Deploy tx | `0xb5dd908cc4c76f750781f2512dc1f2972e99b412f84d0522b8eaa4a6a27a40a7` |
| Block | 51038762 · 8 Sep 2026 |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Arbiter / fee recipient | `0xc2C9F41778Dda1dd38C6D0b08eC730D675c7bA2C` (Safe) |
| Owner | Same Safe — ownership transferred immediately after deploy |
| Source | Verified on Basescan |
| Cost | 0.000023 ETH |

Deployed from a fresh wallet used for nothing else, then handed to the Safe. The deployer key has no authority over the contract. No campaign has been funded yet — that waits until `release()` has been proven end to end on testnet.

### Deployed — Arc testnet
| | |
|---|---|
| Contract | `0xFE9b1D63552FE9566178E4d6dcd86A2222b52227` |
| Chain | Arc testnet (5042002) |
| USDC (ERC-20) | `0x3600000000000000000000000000000000000000` |
| Source | Verified |
| Cost | 20.95 USDC |

Full campaign run through funding and first proof. Same bytecode as Base; the only change was one address in the environment.

### Arc: what testnet taught us

**USDC has two faces.** Native is 18 decimals, the ERC-20 interface is 6 — the same balance, two views. The contract only touches the ERC-20 interface, so `500e6` still means 500 USDC. Confirmed on-chain: the escrow read `5000000` via `balanceOf` and `5000000000000000000` via `cast balance` for the same 5 USDC.

**Funding emits two Transfer logs.** One from the EIP-7708 system emitter at `0xffff…fffe` (18 decimals), one from the ERC-20 contract (6 decimals), for a single movement. Any indexer must filter by emitter or it will double-count. This matters for the proof feed and the campaign page.

**No `receive()` needed.** `safeTransferFrom` into the escrow works unchanged despite USDC being the native asset.

**Ad blockers break Arc in the browser.** Requests to `rpc.testnet.arc.io` fail with `ERR_BLOCKED_BY_CLIENT` for anyone running a common blocker — `arc.io` sat on filter lists from a previous owner (a P2P CDN) and the lists haven't caught up. Every alternate RPC Circle publishes is an `*.arc.io` subdomain, so there is no way around it from the client side. The site detects this specific failure and explains it rather than showing a generic error. **Worth watching before mainnet:** if the mainnet RPC uses the same domain, every browser-side read is affected, and any frontend on Arc has the same problem.

**Gas is real money, and it moves.** Observed prices swung between roughly 2,800 and 16,000 gwei within a few hours:

| Action | Gas | Cost at ~3,500 gwei |
|---|---|---|
| `createCampaign` | 255,819 | 1.03 USDC |
| `fund` | 91,491 | 0.30 USDC |
| `submitProof` | 67,689 | 0.28 USDC |
| `release` (est.) | ~100,000 | ~0.35 USDC |

Our own cost per campaign — one `createCampaign` plus four `release` calls — is roughly **2.43 USDC**. On a 50 USDC campaign the 8% fee is 4 USDC, so gas eats 60% of revenue. On Base the same work costs fractions of a cent.

Two consequences to decide before Arc mainnet: raise the panel floor on Arc (75–100 USDC rather than 50), or have owners pay their own `release` gas with the keeper as a fallback rather than the default.

### Deployed — Base Sepolia
| | |
|---|---|
| Contract | `0x88064FC8D03f8745Fd131CFc2D902Bc1e2502A77` |
| Chain | Base Sepolia (84532) |
| Deploy tx | `0x2d8606c0c846d71d88a44580cd4000196b25a6fae284cadceee3484fecea49e6` |
| Block | 46514405 · 7 Sep 2026 16:04 UTC |
| USDC | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` (Circle test USDC) |
| Source | Verified on Basescan and Sourcify |

`script/Deploy.s.sol` reads every constructor argument from `.env`. Nothing is hardcoded, so the same script deploys to Base mainnet and Arc by changing the RPC and USDC address.

### First live campaign
| | |
|---|---|
| Campaign id | `0x78bddf0d916c8835f47bf744c3a34936fd702cdc33f675af3a9c6015a9d41bf8` |
| Total | 12 USDC · 8% fee · tranches 25 / 27.5 / 27.5 / 20 |
| Applied at | 1788798288 (7 Sep 2026 16:24 UTC) |
| Tranche 1 due | 1791390288 — exactly `appliedAt + 30 days` |
| Challenge window closes | 14 Sep 2026 16:24 UTC |

The day-offset design was confirmed on-chain: the gap between `appliedAt` and `dueAt(1)` is exactly 2,592,000 seconds. Timestamps are Unix/UTC, so time zones never enter the contract — the frontend localises for display only.

Expected on release of tranche 0: 2.76 USDC to owner, 0.24 USDC fee, 9 USDC remaining in escrow.

### Contracts do not run themselves
There is no scheduler on-chain. A tranche that is due and unchallenged does not pay out until somebody sends a transaction calling `release()`. This is why the function is permissionless.

In production this needs three layers:
1. **A claim button** in the owner's dashboard — the normal path.
2. **A keeper bot** that sweeps for due, unchallenged tranches once a day and calls `release()` on the owner's behalf, paying its own gas. Owners who forget still get paid.
3. **The block explorer**, as the fallback that needs nobody's cooperation. If peelbid disappears, an owner calls `release()` from Basescan's Write Contract tab.

The same applies to `reclaimUnapplied` and `reclaimMissedTranche` — the sponsor triggers their own refund.

### Repo
`README.md` documents the campaign lifecycle, the design decisions and their reasons, and the deploy procedure. `.env.example` carries the USDC address for each network with a note to re-verify against Circle before any mainnet deploy. The repo stays private until launch; the deployed source is verified on all three explorers regardless.

### Keeper — built 9 September
`peelbid-keeper` (separate private repo). Node, ethers, no framework. Reads each configured campaign, finds tranches whose proof is in and whose challenge window has closed, and calls `release()`.

**It has no privileges and holds no funds.** `release()` is permissionless, so the keeper is only somebody calling it on time. It carries gas and nothing else. If its key leaked, the worst an attacker could do is trigger a payout to the campaign's registered owner — which is what was going to happen anyway.

Safety rails: dry-run default; `staticCall` simulation before every send, so a wrong view of state costs nothing; a `MAX_GAS_NATIVE` ceiling that skips the run rather than draining the wallet in a fee spike; and a `paused()` check to avoid guaranteed reverts.

Verified against both testnets on 9 September — countdowns matched the site's independently, 125.2h on Base Sepolia and 143.8h on Arc.

**Not yet done:** it runs by hand. Cron or a GitHub Action comes after the first real releases on 14–15 September. Campaign ids live in `.env`, which is right at this scale and wrong at fifty.

### Before mainnet
- **Confirm Arc mainnet's USDC address.** Circle's docs currently state that only testnet addresses are published. `0x3600…0000` is a system predeploy and will probably carry over, but it is immutable once in the constructor — check it on the morning of the 16th.
- Watch the first campaign through a full tranche release (14 Sep)
- Keeper bot (not required for correctness, required for usability)
- Arbiter and fee recipient must be a Safe multisig on mainnet, not an EOA
- Aderyn as a second static pass (optional; Slither was clean)

---

## 10. Decisions still open

1. **Multi-panel bidding** — can one sponsor take five panels on one object at once, or is that five separate auctions? Defaulting to separate.
2. **Whether an owner can offer a twelve-month run at the minimum floor.** They currently cannot: at 50 USDC a month the total exceeds `MAX_CAMPAIGN`, so `openAuction` refuses the run mask. Both limits lift together after an audit, and the constraint disappears on its own.

*Withdrawn:* raising the floor price on Arc. That was based on testnet gas figures of 2,800–16,000 gwei, which turned out to be launch-week congestion. Mainnet runs at about 35 gwei — deploying the escrow cost 0.068 USDC — so the campaign economics that prompted it never existed.

Resolved since the first draft: artwork rejection (artwork now arrives with the bid), auction length (owner-set), freshness token (system-generated), chain order (both — same bytecode, Base mainnet and Arc from launch day).

---

## 11. Rollout phases

No audit budget. Exposure is capped by *what the contract is allowed to hold*, not by hoping the code is correct.

### Phase 0 — Safe multisig, manual release — **skipped**
The original plan was to run the first 10–15 campaigns through a per-campaign Safe with no bespoke code, learning what the contract needed before writing it.

We skipped it. The contract was finished, tested and deployed in roughly a week — faster than the manual phase would have taken — so the reason for the detour disappeared. The learning it was meant to provide now has to come from the first real campaigns instead, which is a real loss: we are shipping a design we reasoned our way to rather than one we watched fail.

Worth remembering if something in the tranche schedule or the proof rules turns out to be wrong in practice. It will not be the contract's fault.

### Phase 1 — Testnets · **done, 7–8 September**
`PeelbidEscrow` deployed and verified on Base Sepolia and Arc testnet. Funded campaigns running on both: USDC in, sticker applied, proof on-chain, challenge window open. 27 scenario tests, 4 invariants across 16,384 randomized operations, Slither clean.

**Outstanding:** `release()` has not yet paid out on a real chain. The Base Sepolia challenge window closes 14 September; that is the last unproven step in the lifecycle.

### Phase 2 — Base mainnet, capped · **deployed 8 September, unfunded**
Live and verified at `0xf78257D41C8e78dD19e941146B58ebe9f9726635`, owned by the Safe from the same session. Caps enforced as constants. **No campaign funded yet, deliberately** — nothing goes in until a full release cycle has completed on testnet.

**Exit:** audit completed.

### Phase 2b — Arc mainnet, 16 September
Same bytecode, same caps. Blocking checks on the morning: the mainnet USDC address (Circle has not published it), gas price at launch, and whether the mainnet RPC sits on the same ad-blocked `arc.io` domain.

### Phase 3 — Raise the caps
Only after audit. First real revenue goes here before anything else.

### On bug bounties
A bounty is not a substitute for an audit. An audit is paying for the code to be examined; a bounty is offering to pay *if someone happens to look*. On a small, unknown contract, generally nobody looks — serious researchers are on protocols holding millions. Run a bounty on Immunefi or Cantina once there is real value at stake, and treat it as defence in depth, never as the primary control.

---

---

## 12. On-chain bidding

Decided 13 September, built 14–15 September. Full design in `auction-design.md`.

The site's bidding works and is entirely off-chain. This replaces it with two
contracts that settle without us: `PeelbidAuction` holds deposits and, when an
owner approves a winner, creates and funds the campaign in `PeelbidEscrow`
inside a single transaction.

### Escrow v2, and why it had to come first
`createCampaign` was `onlyOwner`, meaning the Safe. An auction contract that
settles a won panel must create the campaign holding the money, and couldn't.

Two bad answers and one good one. Giving the auction contract ownership hands
it `pause`, `setArbiter` and everything else to obtain one function. Letting it
hold the money itself means writing escrow logic twice and holding funds in two
places. Instead there is a narrow `campaignCreator` role that may call
`createCampaign` and nothing else, appointed and revocable by the Safe in one
transaction.

`fundOnBehalf` came out of the same work. `fund()` requires
`msg.sender == campaign.sponsor`, and at settlement the winner's money sits in
the auction contract, not with the brand. Naming the auction as sponsor would
have "fixed" it and broken every refund path in the escrow — `terminate`,
`resolve`, `reclaimUnapplied` and `reclaimMissedTranche` all pay
`campaign.sponsor`, so refunds would have gone to a contract instead of the
brand that paid. `fundOnBehalf` pulls from the caller and leaves the sponsor as
the brand.

Found before deployment, which is the only reason it was cheap.

### Two things the tests found that reasoning didn't

**A run length nobody could bid on.** `MAX_BID` is 500 USDC because the escrow
won't hold a larger campaign. At the 50 USDC floor a twelve-month run needs 600
USDC, so it cannot exist — and an owner could tick "12 months", go live, and
never learn why no bid arrived. `openAuction` now rejects a run mask it can't
honour, and `longestRunAt(floorRate)` lets the site show the ceiling first.

Surfaced by a scenario test using a twelve-month bid and reverting with
`BidTooLarge`. The test wasn't wrong; the design was.

**Money owed to nobody.** Ranking is by monthly rate and the deposit follows
the total, so a bidder can improve their offer while locking *less*: six months
at 300 is 50 a month, one month at 60 is 60 a month on a fifth of the money.
`_reprice` wrote the smaller deposit and left `totalHeld` alone, stranding the
difference — held by the contract, owed to no one.

An invariant caught it on its first run, in a three-call sequence. No scenario
test would have, because writing one requires first thinking the sentence
"a bidder raises their bid and locks less", and nobody thinks it.

**This is the argument for invariants in one paragraph.** Scenario tests check
the paths you imagined. Invariants check that no ordering of any paths, in
16,384 random calls, breaks the accounting.

### Coverage
| Suite | Tests |
|---|---|
| `PeelbidEscrow.t.sol` | 39 scenarios |
| `EscrowInvariants.t.sol` | 4 invariants |
| `PeelbidAuction.t.sol` | 52 scenarios |
| `AuctionInvariants.t.sol` | 4 invariants |

Auction invariants: the balance equals live deposits plus what is owed;
`totalHeld` matches the deposits that actually exist; the cap holds; and the
contract can always pay what it owes.

### via-IR
`PeelbidAuction` holds a fourteen-field struct and calls a seven-argument
function. The legacy pipeline runs out of stack slots, and the error names no
function. `via_ir = true` with the optimizer is the normal setting for a
contract this shape.

It changes the escrow's bytecode too, which is fine only because v2 is a fresh
deployment everywhere. It would not have been fine if v1 were staying put.

### Not deployed yet
The auction contract is a day old. It goes to testnet first and holds nobody's
deposit until it has run a full cycle there. Arc mainnet tomorrow is escrow v2
alone, with `campaignCreator` left unset.

---

## 13. The auction on a chain

Deployed to Arc testnet on 17 September, the day after Arc's mainnet opened.

| | |
|---|---|
| Escrow v2 | `0x74a0610c0d27744e704f5032edd1d2abbaf7a8a3` |
| `PeelbidAuction` | `0x3264107f701b0a3a8e241f75f18fbb7f2b3f8d84` |
| Link | `setCampaignCreator` — `CampaignCreatorChanged(0x0 → 0x3264…)` |

Escrow v2 had to go first: the auction calls `fundOnBehalf`, which v1 doesn't have.

On testnet the deployer is its own arbiter and fee recipient, which makes the walkthrough one wallet instead of three. Never on mainnet.

### The first cycle

Opened at a 50 USDC monthly floor, runs 1/3/6, 24 hours, 8% fee. Then one bid: 300 USDC over three months, artwork hash attached.

What the chain confirmed, read straight off the logs:

- `AuctionOpened` carries floor `0x2faf080` (50 USDC) and mask `7` — the run lengths the owner will accept, as a bitmask.
- `minimumBid(id, 3)` returns exactly `150000000`. Three months at the floor.
- `BidPlaced` records the total, the run length, **and the monthly rate the contract derived** — `0x5f5e100`, 100 USDC. Ranking is on-chain, not a convention the site upholds.
- `totalHeld` is `30000000`. The deposit is real money the contract is holding, not a promise in a database.

Settlement waits on the 24-hour minimum. `MIN_DURATION` exists so an owner can't open, tip off a friend and close before anyone else notices, and it is now inconveniencing us exactly as designed.

### Arc's double Transfer log, again
Funding the deposit emitted two transfers for one movement: the EIP-7708 system emitter at `0xffff…fffe` in 18 decimals, and the ERC-20 contract in 6. Same 30 USDC, twice.

Noted in §9 and still true. Any indexer reading auction deposits has to filter by emitter or it will double-count every one of them.

### What settlement has to prove

The tests assert it and the chain hasn't yet:

| Check | Expected | Why it matters |
|---|---|---|
| `totalHeld` | 0 | the deposit stops being held |
| USDC in the auction | **0** | it never sits on campaign money |
| USDC in the escrow | 300000000 | the balance went through in one transaction |
| Campaign sponsor | **the brand** | every refund path pays `campaign.sponsor` |
| Tranches | 4 | the fixed schedule was used |

The fourth row is `fundOnBehalf`'s entire reason for existing. If the sponsor were recorded as the auction contract, `terminate`, `resolve`, `reclaimUnapplied` and `reclaimMissedTranche` would all refund to a contract instead of the brand that paid.

### Still to run on testnet
Outbid-and-withdraw, decline, missed payment, expiry. Each needs its own auction id and about ten minutes, and each tests a safety property that currently only passes in a simulator.
