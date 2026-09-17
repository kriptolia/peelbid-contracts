# peelbid — escrow contract

Escrow for sponsorship campaigns on physical objects. Sponsor funds in USDC,
owner is paid in tranches as proof of an applied sticker is submitted and
left unchallenged for 7 days.

Full design: peelbid-escrow-design.md (read it before touching the contract).

## Decisions already made — do not relitigate
- Only PeelbidEscrow is on-chain. Auctions, bids, approval are off-chain.
- Tranches store day offsets. The clock starts at first accepted proof
  (sticker applied), never at funding.
- release() is permissionless. Owner's payout must not depend on our server.
- Only the challenged tranche freezes. Others proceed.
- Fee (8%, max 10%) taken pro-rata per tranche, only on what the owner receives.
- Operator is arbiter in v1.
- Hard caps are constants: 500 USDC per campaign, 5,000 total. Not settable.
  They exist because there is no audit. Do not remove or soften them.
- USDC has 6 decimals.
- Checks-effects-interactions always. nonReentrant on anything moving tokens.

## Status (17 Sep 2026)
LIVE ON BASE MAINNET, verified, owned by the Safe.
  Address: 0xf78257D41C8e78dD19e941146B58ebe9f9726635
  Chain:   8453
  Owner / arbiter / feeRecipient: 0xc2C9F41778Dda1dd38C6D0b08eC730D675c7bA2C (Safe, 1/1)
  No campaign funded yet — waiting on the first proven release.

Also live on Base Sepolia, source verified.
  Address: 0x88064FC8D03f8745Fd131CFc2D902Bc1e2502A77
  Chain:   84532
27 tests + 4 invariants (16k random calls) green. Slither: no High/Medium.
solc pinned 0.8.36. Deploy script reads all args from .env.

First live campaign running:
  id 0x78bddf0d916c8835f47bf744c3a34936fd702cdc33f675af3a9c6015a9d41bf8
  12 USDC funded, sticker applied 7 Sep 16:24 UTC.
  Challenge window closes 14 Sep 16:24 UTC — call release(id, 0) after that.
  Expect 2.76 USDC to owner, 0.24 fee, 9 USDC left in escrow.

NEXT DATES, both load-bearing:
  14 Sep 19:24 Istanbul — Base Sepolia challenge window closes. Set the
    keeper repo variable DRY_RUN=false, then Actions -> Run workflow.
    This is the last unproven step in the lifecycle: release() has never
    paid out on a real chain, and it doubles as the keeper's first real run.
    Expect 2.76 USDC to owner, 0.24 fee, 9 USDC left in escrow.
  15 Sep — Arc testnet's first tranche. Same command, other chain.
    Also: activate the Safe on Arc, fund the deploy wallet.
  16 Sep — Arc mainnet. Follow arc-mainnet-runbook.md. Three checks that
    morning before deploying: the mainnet USDC address (Circle had not
    published it as of 9 Sep), the gas price, and whether the mainnet RPC
    sits on the same ad-blocked arc.io domain.
    DO NOT fund a campaign on the 16th.

ESCROW V2 + AUCTION: written and tested 14-15 Sep. See design doc §16 and
auction-design.md. 39+52 scenario tests, 8 invariants, all green.
  Escrow v2 adds campaignCreator (narrow role, Safe-appointed, revocable)
  and fundOnBehalf (auction funds the campaign; sponsor stays the brand,
  so every refund path still pays the right address).
  via_ir = true is now required — the auction won't compile without it.

ARC MAINNET — DONE, 16 Sep, day one.
  0xCDfad58266dAe603c542984A7C8e8e72b8c617C9  (chain 5042)
  Verified. Safe-owned. campaignCreator = 0, deliberately.
  Deploy cost 0.068 USDC.
  USDC on Arc mainnet is 0x3600...0000, same as testnet. RPC is
  https://rpc.mainnet.arc.io (NOT rpc.arc.io — that doesn't resolve).

GAS ON ARC: mainnet is ~35 gwei, about 300x cheaper than the testnet
figures we measured in launch week. Our per-campaign cost is cents, not
2.43 USDC. The plan to raise the Arc floor price above 50 USDC is
WITHDRAWN — design doc §9 and §13 warnings no longer apply.
Lesson: a testnet measured the week before its mainnet opens tells you
about the crowd, not the chain.

AUCTION LIVE ON ARC TESTNET — 17 Sep. See design doc §17.
  Escrow v2  0x74a0610c0d27744e704f5032edd1d2abbaf7a8a3
  Auction    0x3264107f701b0a3a8e241f75f18fbb7f2b3f8d84
  campaignCreator is set. First cycle open: 300 USDC bid over 3 months,
  30 USDC deposit held. Settlement waits on the 24h minimum.
  Testnet only: deployer is its own arbiter. Never do that on mainnet.

STILL TO DO:
  Redeploy Base mainnet and Base Sepolia on v2. None hold
  funds worth migrating; ten minutes each now, a migration later.
  Superseded v1 addresses are listed in arc-mainnet-runbook.md.
  Auction contract to testnet, full cycle, before it holds any deposit.

Then: builder mockup renderer, scale calibration, proof feed.

## Peels (waitlist points) — see design doc §12
In-house on Vercel serverless + Supabase, deliberately not on Zealy/Galxe.
+25 email, +10 X handle (unverified on purpose), +50 per referral.
Biggest allocation reserved for approved real listings — that's the anti-farm.
Reward is stated upfront: early access, Founding Lister perks, and a share of
protocol fees in USDC (~10% year one, % not yet public).
No token promised, none denied. Both would be wrong.
Lawyer must review the fee share before the first payout.

## Marketplace — see design doc §15
The site is a working two-sided product, not a waiting list.
Sign in (Privy, email) -> role question -> dashboard.
Owners list; brands bid; owners approve.

GATING, and it is asymmetric on purpose:
  Listing is INVITE-ONLY. `invited` on the waitlist row, set by hand.
  Bidding is OPEN to anyone signed in.
  Supply quality is what a marketplace is judged on. Demand is what we
  want more of. Do not "fix" this by gating bids.

PRIVY v2 TRAP: embedded wallet config is nested.
  embeddedWallets: { ethereum: { createOnLogin: "users-without-wallets" } }
  A flat createOnLogin is silently ignored — no error, no wallet.

BIDS: ranked by MONTHLY RATE, never headline total. Artwork comes with the
bid and one approval covers both. One revision request per bid. Approving
sets the panel to `reserved`, never `sold` — sold means funded, and funding
is still manual from the Safe.
No deposit: needs the auction contract we haven't written.

NOTIFICATIONS are derived from bids, not stored in a feed. One column,
seen_by_bidder_at. Don't build a notifications table.

DB helper rule: sbUpdate sends exactly the columns you pass. It used to
append updated_at, which broke every write to `bids` silently. Don't let a
helper add columns you didn't ask for.

Tables: listings · bids · profiles · waitlist
Buckets: listing-photos · bid-artwork

## Site — Next.js, see design doc §14
peelbid.com runs from the private repo `peelbid-web` (Next App Router, JS,
no TS, no Tailwind). The old static single-file site is retired.
Routes: / · /examples · /examples/[slug] · /builder · /privacy
        /api/join · /api/leaderboard
Shared: components/ for Header, Footer, PanelMap, Waitlist, Leaderboard,
LiveEscrow, Sticker, Marquee, Reveal. globals.css holds every design token.

NEXT 15: params is a Promise in dynamic routes. Use
  export default async function Page({ params }) { const { slug } = await params; }
Reading params.slug directly gives a silent 404.

Four worked examples live at /examples — car, laptop lid, backpack, cabin
case. Real photos, panels placed with our own builder, real cm, real prices.
Nothing is bookable: no CLAIM buttons, waitlist is the only CTA.
Each example carries context + an owner-voice pitch + one lesson. The car's
lesson is that our own photo is badly shot; we say so on the page.

Panel quads are [x,y] fractions of the image, drawn as an SVG overlay with
viewBox 0 0 100 100 and preserveAspectRatio="none".
Place them with /builder, never by estimating coordinates — that was tried
and failed three times.

## Site plan — see site-plan.md
Order: email first (nobody is told anything today), then context-writing
help in the builder, then wire the site to the auction contract, then
panel suggestion + plate scale, then the proof feed.

## Machine assistance — see design doc §13 and site-plan.md
Planned, not scheduled. Never labelled "AI" anywhere in the product.
Order: mockup renderer (pure homography, no model), plate-based scale,
panel suggestion, proof checking. Proof checking is assistive only —
it flags for review, never rejects. No chatbots, no bidding agents,
no auto-approving sponsors (the owner's veto is the premise).

## Keeper
Separate private repo `peelbid-keeper`. Node + ethers. Sweeps configured
campaigns, releases tranches past their challenge window. No privileges,
holds only gas — release() is permissionless, the keeper is just early.
DRY_RUN defaults true. staticCall before every send. MAX_GAS_NATIVE ceiling.
Runs by hand for now; automate after 14-15 Sep.
Keeper wallet: 0x46fD85467f739b3A41B29Bd603DD47E8e86FD90A

## Things that are NOT done
- No email anywhere. Nobody is told anything unless they open the site.
- No public directory of listings — a published listing can only be reached
  by knowing its URL. Biggest visible gap on the demand side.
- Bids never expire.
- Nothing connects an approved bid to createCampaign. The operator reads the
  approval and sets the campaign up from the Safe by hand. The auction
  contract closes this gap once campaignCreator is appointed.
- Nothing is funded on Arc mainnet.
- setArbiter and setCampaignCreator emit no event. Flagged by the linter,
  still unfixed. Access control changing with no on-chain trace is a real
  gap — fix it before the Base redeployments, that is the last cheap moment.
- Four auction paths have never run on a chain: outbid-and-withdraw,
  decline, missed payment, expiry.
- No keeper bot. Contracts don't self-execute; a due tranche sits unpaid
  until someone calls release(). Permissionless by design, but users need
  a claim button plus a bot that sweeps daily.
- Arbiter and feeRecipient are an EOA on testnet. On mainnet both must be
  a Safe multisig before any real money is accepted.
- Builder has no scale calibration.
- /builder is gated behind ?key=peel-it and shows "Built. Not open to
  everyone." to everyone else.
- Mockup renderer is BUILT but SHELVED — see design doc §14. The geometry in
  lib/warp.js is correct; the lighting isn't, and one blend formula can't
  serve aluminium, canvas and car paint. Don't retry with blend modes.
  NOT an image-model job either — checked Sep 17. Generative compositing
  distorts logos and text, which is the one thing that must not change.
  When it returns it returns as better compositing with per-surface
  lighting the owner sets, not as a generated image.
- /builder is gated: ?key=peel-it opens it, remembered in localStorage.
- Keeper runs by hand. Automate after 14–15 Sep.
- No audit. The hard caps are the substitute.

## Working style
Function → test → forge test. Test refusals, not just happy paths.
Author is new to Solidity — explain what the code does and why.
Never write a private key into any file in this repo.
