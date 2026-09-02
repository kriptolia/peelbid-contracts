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

## Status (2 Sep 2026)
Contract complete: createCampaign, fund, submitProof, release, challenge,
reclaimMissedTranche, resolve, terminate, reclaimUnapplied, admin.
27 tests + 4 invariants (16k random calls) green. Slither: no High/Medium.
solc pinned 0.8.36.
Next: deploy script, Base Sepolia, one full manual campaign on testnet.

## Working style
Function → test → forge test. Test refusals, not just happy paths.
Author is new to Solidity — explain what the code does and why.
Never write a private key into any file in this repo.
