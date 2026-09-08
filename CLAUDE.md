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

## Status (8 Sep 2026)
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

Next: release tranche 0 on 14 Sep, Arc testnet, Arc mainnet 16 Sep.
Then: keeper bot, listing builder, proof feed.

## Peels (waitlist points) — see design doc §12
In-house on Vercel serverless + Supabase, deliberately not on Zealy/Galxe.
+25 email, +10 X handle (unverified on purpose), +50 per referral.
Biggest allocation reserved for approved real listings — that's the anti-farm.
Reward is stated upfront: early access, Founding Lister perks, and a share of
protocol fees in USDC (~10% year one, % not yet public).
No token promised, none denied. Both would be wrong.
Lawyer must review the fee share before the first payout.

## Site
peelbid.com is one page. Waitlist and Peels stay; a "What we're building"
section shows six capabilities with honest status chips (five in build/soon,
escrow live); a "The escrow, live" section reads the contract directly via
ethers and renders the running campaign. No backend, no database.
Do NOT split this into separate pages — the site is the product to a
visitor, the contract is plumbing nobody asks to see.

Known: ad blockers block rpc.testnet.arc.io (arc.io is on filter lists from
its previous owner). All Circle RPCs are *.arc.io subdomains, so there's no
client-side fix. The page detects it and says so. Check whether Arc mainnet
uses the same domain.

## Machine assistance — see design doc §13
Planned, not scheduled. Never labelled "AI" anywhere in the product.
Order: mockup renderer (pure homography, no model), plate-based scale,
panel suggestion, proof checking. Proof checking is assistive only —
it flags for review, never rejects. No chatbots, no bidding agents,
no auto-approving sponsors (the owner's veto is the premise).

## Things that are NOT done
- No keeper bot. Contracts don't self-execute; a due tranche sits unpaid
  until someone calls release(). Permissionless by design, but users need
  a claim button plus a bot that sweeps daily.
- Arbiter and feeRecipient are an EOA on testnet. On mainnet both must be
  a Safe multisig before any real money is accepted.
- No frontend at all yet.
- No audit. The hard caps are the substitute.

## Working style
Function → test → forge test. Test refusals, not just happy paths.
Author is new to Solidity — explain what the code does and why.
Never write a private key into any file in this repo.
