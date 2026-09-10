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

## Status (10 Sep 2026)
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

NEXT TWO DATES, both load-bearing:
  14 Sep 19:24 Istanbul — Base Sepolia challenge window closes. Run the
    keeper with DRY_RUN=false. This is the last unproven step in the
    lifecycle: release() has never paid out on a real chain.
    Expect 2.76 USDC to owner, 0.24 fee, 9 USDC left in escrow.
  16 Sep — Arc mainnet. Three checks that morning before deploying:
    the mainnet USDC address (Circle had not published it as of 9 Sep),
    the gas price, and whether the mainnet RPC sits on the same
    ad-blocked arc.io domain.

Then: builder mockup renderer, scale calibration, proof feed.

## Peels (waitlist points) — see design doc §12
In-house on Vercel serverless + Supabase, deliberately not on Zealy/Galxe.
+25 email, +10 X handle (unverified on purpose), +50 per referral.
Biggest allocation reserved for approved real listings — that's the anti-farm.
Reward is stated upfront: early access, Founding Lister perks, and a share of
protocol fees in USDC (~10% year one, % not yet public).
No token promised, none denied. Both would be wrong.
Lawyer must review the fee share before the first payout.

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

## Machine assistance — see design doc §13
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
- No keeper bot. Contracts don't self-execute; a due tranche sits unpaid
  until someone calls release(). Permissionless by design, but users need
  a claim button plus a bot that sweeps daily.
- Arbiter and feeRecipient are an EOA on testnet. On mainnet both must be
  a Safe multisig before any real money is accepted.
- Builder has no scale calibration and no mockup renderer. The mockup is
  the highest-value piece per design doc §13 and needs no model at all —
  it is a homography onto the quad the owner already drew.
- Keeper runs by hand. Automate after 14–15 Sep.
- No audit. The hard caps are the substitute.

## Working style
Function → test → forge test. Test refusals, not just happy paths.
Author is new to Solidity — explain what the code does and why.
Never write a private key into any file in this repo.
