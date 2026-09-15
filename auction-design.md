# PeelbidAuction — design

Decided 14 September. Written before the contract so the reasoning survives it.

Sits beside `PeelbidEscrow`, holds bid deposits, and on settlement creates and
funds the campaign through the `campaignCreator` role added in escrow v2.

---

## What it does

1. An owner opens an auction on one panel: a floor rate, the run lengths they
   will accept, and an end time.
2. Brands bid. A bid is a total and a run length; the contract ranks by
   **monthly rate**, never by headline total.
3. A deposit is locked with each bid. Being outbid credits it back, claimable
   at any time.
4. When the auction ends the owner approves the leader, which reserves the
   panel and starts a payment window.
5. The winner pays the balance. The contract creates the campaign in escrow
   and funds it in one transaction.
6. If the winner doesn't pay, their deposit goes to the owner and the auction
   closes.

---

## Decisions

### Bids rank by monthly rate
600 USDC over twelve months is 50 a month. 330 over three is 110. The second
wins. Ranking by total would mean a long cheap run always beats a short
valuable one, and the owner could never compare them.

### The deposit is `max(10 USDC, 10% of the bid)`
A flat percentage leaves 50 USDC bids with a 5 USDC deposit, which deters
nobody. A tiered rate — 20% below 100, 10% above — creates a cliff at the
threshold where bidding 101 locks less than bidding 99, and people would find
it. A floor does the same job with no edge to game, and the amount only ever
rises with the bid.

### Refunds are claimed, not pushed
Being outbid credits `refunds[bidder]`; they withdraw when they like.

Pushing a refund inside the outbid path would mean an outbid transfer can
fail, and a bidder who is a contract rejecting transfers could make themselves
impossible to outbid. Sending money to a stranger in the middle of someone
else's transaction is how auctions get held hostage.

### The tranche schedule is fixed in the contract
First tranche 25%, last 20%, the rest split evenly across the months between.
One month has no middle, so it is 40/60.

| Run | Percentages | Day offsets |
|---|---|---|
| 1mo | 40 / 60 | 0, 30 |
| 3mo | 25 / 27.5 / 27.5 / 20 | 0, 30, 60, 90 |
| 6mo | 25 / 11 ×5 / 20 | 0, 30 … 180 |
| 12mo | 25 / 5 ×11 / 20 | 0, 30 … 360 |

Taking the schedule as a parameter would let whoever triggers settlement
choose it. Letting owners set it per listing invites a 95%-up-front schedule
that a sponsor discovers only after winning. Fixed means a bidder knows the
payment shape before bidding, and the rule itself is universal: the first
tranche covers printing, the last is a completion bond.

### Who sets what
- **Owner:** which panels, floor rate, acceptable run lengths, end time.
- **Brand:** run length (from the owner's list) and amount.
- **Contract:** tranche schedule and fee.

### Auction length: 24 hours to 10 days
Shorter than a day lets an owner open, tip off a friend, and close before
anyone else sees it. Longer than ten days keeps a bidder's deposit locked for
no good reason.

### Anti-snipe: 15 minutes
A bid inside the last 15 minutes pushes the end out by 15 minutes. It can
extend repeatedly; in practice it settles in two or three rounds. Without it
the auction rewards whoever has the fastest connection at the deadline rather
than whoever values the panel most.

### Approval is explicit and it can be a refusal
The auction ending does not award anything. The owner approves the leader, and
may decline them — the whole product rests on an owner keeping the final say
over what goes on their property.

**Declining ends the auction; it does not pass to the runner-up.** This was the
original plan and it doesn't survive contact with the refund rule above. A
losing bidder gets their deposit back the moment they are outbid, so at most
one deposit exists per auction at any time and there is nobody below the leader
still holding one to be promoted into.

The alternative — hold every deposit until the auction resolves — makes
promotion work, and costs every losing bidder up to nineteen days of locked
money (ten bidding, seven deciding, two paying) for a case that will be rare.
Not worth it. The owner opens a fresh auction and the site tells the other
bidders it is open.

Same reasoning applies when a winner fails to pay.

**One week to decide.** After that, everyone's deposit is claimable and the
auction expires. An owner who disappears cannot strand a bidder's money.

### Artwork is a hash
The image can't go on-chain. The bid carries `keccak256` of the file, and the
site shows the image. The hash proves the artwork approved is the artwork
supplied — the owner approves the sponsor and their creative in one act, and
neither side can swap it afterwards.

### Payment window: 48 hours
After approval the winner pays the balance. Miss it and the deposit goes to the
owner as compensation for the wasted time, and the auction closes.

`paymentMissed` is permissionless: an owner should not have to watch a clock to
be compensated.

---

## What it deliberately does not do

**It does not hold campaign money.** The balance goes straight through to the
escrow in the settling transaction. The auction contract holds deposits and
nothing else, so a bug in it can't reach a running campaign.

**It does not own the escrow.** It holds `campaignCreator`, which can only
create campaigns. The Safe can revoke it in one transaction.

**It does not decide disputes.** The arbiter is a separate role, held by the
Safe. A bug here cannot resolve a dispute in its own favour.

**It does not register listings.** Panels are identified by a hash the site
supplies. Putting the listing catalogue on-chain would cost gas for data
nobody queries on-chain.

---

### Not every run length fits at every floor
`MAX_BID` is 500 USDC because the escrow refuses to hold a campaign larger
than that. A twelve-month run at the 50 USDC floor would be 600 USDC, so it
cannot exist. At a 100 USDC floor, six months is already 600 and out.

The contract checks this when the auction opens and refuses a run mask that
promises a length nobody could bid on. Found by a test, not by reasoning:
`test_RankingIsByMonthlyRateNotTotal` used a twelve-month bid and reverted
with `BidTooLarge`, which turned out to be the design telling us something
rather than the test being wrong.

Checking at open time matters more than it sounds. Without it, an owner ticks
"12 months", the listing goes live, and no bid ever arrives — with nothing
anywhere explaining why. `longestRunAt(floorRate)` lets the site show the
ceiling before they choose.

Both limits lift together when the caps do, after an audit.

## Limits, same reasoning as the escrow

```
MIN_FLOOR_RATE   50e6      // 50 USDC a month
MAX_BID          500e6     // one campaign's cap
MAX_TOTAL_HELD   5_000e6   // across all deposits
```

There is no audit. Exposure is bounded by what the code allows rather than by
assuming the code is right.
