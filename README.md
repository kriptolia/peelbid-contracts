# peelbid contracts

USDC escrow and on-chain auctions for advertising placements on physical objects.

A brand pays to put their artwork on something somebody owns — a car door, a
laptop lid, a case that travels to conferences. The money sits in escrow and
leaves in stages, each stage released against dated proof that the placement is
still there. Neither party has to trust the other, and neither has to trust the
operator.

**peelbid.com** · [Escrow design](./peelbid-escrow-design.md) · [Auction design](./auction-design.md)

---

## Contracts

### PeelbidEscrow
Holds a campaign's USDC and releases it in tranches against proof.

| Network | Address | |
|---|---|---|
| Arc (5042) | [`0xCDfad58266dAe603c542984A7C8e8e72b8c617C9`](https://arcscan.app/address/0xCDfad58266dAe603c542984A7C8e8e72b8c617C9) | verified · Safe-owned · deployed on Arc's launch day |
| Base (8453) | [`0xf78257D41C8e78dD19e941146B58ebe9f9726635`](https://basescan.org/address/0xf78257D41C8e78dD19e941146B58ebe9f9726635) | verified · Safe-owned |
| Arc testnet | [`0x74a0610c0d27744e704f5032edd1d2abbaf7a8a3`](https://testnet.arcscan.app/address/0x74a0610c0d27744e704f5032edd1d2abbaf7a8a3) | v2, paired with the auction |
| Base Sepolia | [`0x88064FC8D03f8745Fd131CFc2D902Bc1e2502A77`](https://sepolia.basescan.org/address/0x88064FC8D03f8745Fd131CFc2D902Bc1e2502A77) | one campaign completed |

### PeelbidAuction
Runs the auction for one panel, holds bid deposits, and settles the winner
directly into the escrow.

| Network | Address | |
|---|---|---|
| Arc testnet | [`0x3264107f701b0a3a8e241f75f18fbb7f2b3f8d84`](https://testnet.arcscan.app/address/0x3264107f701b0a3a8e241f75f18fbb7f2b3f8d84) | first cycle running |

Same bytecode on every network. The contracts were written without
chain-specific assumptions; deploying to Arc changed one address in an
environment file and nothing else.

---

## How a campaign works

Terms are agreed in the auction, or off-chain for campaigns arranged by hand.
From funding onward the contract runs on time and evidence alone.

**1. `createCampaign`** records the owner, the sponsor, the total, the fee and a
tranche schedule. No money moves.

**2. `fund`** — the sponsor transfers USDC in, starting a 14-day window to get
the placement applied. (`fundOnBehalf` does the same from the auction contract,
leaving the sponsor recorded as the brand so refunds reach the right address.)

**3. `submitProof(id, 0, hash)`** — the owner evidences the placement. **This is
what starts the campaign clock**, not the payment. An owner who takes ten days
to get something printed doesn't cost the sponsor ten days of their campaign.

**4. Monthly checkpoints** — each tranche becomes due at
`appliedAt + offsetDays`. Fresh proof each time.

**5. `release(id, index)`** pays out a tranche whose seven-day challenge window
has closed. **Anyone can call it.** An owner's money must not depend on anyone's
servers being up.

The fee — 8%, capped at 10% — comes out of each tranche as it releases, and only
from the portion the owner actually receives.

### When things go wrong

| Situation | Function | Who calls it |
|---|---|---|
| Sponsor disputes a proof | `challenge` | sponsor, inside the 7-day window |
| Arbiter splits a frozen tranche | `resolve` | arbiter |
| Placement removed early | `terminate` | arbiter |
| Never applied within 14 days | `reclaimUnapplied` | sponsor — **no arbiter needed** |
| Owner silent on a checkpoint for 14 days | `reclaimMissedTranche` | sponsor — **no arbiter needed** |

A dispute freezes only the tranche it concerns. A disagreement about month three
does not hold months four through six hostage.

---

## Design decisions worth knowing

**The default is to pay.** A sponsor must act to withhold money, not act to
approve it. An escrow that requires positive approval to release hands one party
a silent veto over the other's completed work.

**Release is permissionless.** If peelbid disappeared, an owner could call
`release()` from a block explorer once the challenge window closed. This is the
difference between escrow and a company holding money.

**Tranches store day offsets, not dates.** `dueAt()` computes
`appliedAt + offsetDays × 1 day` on read. An earlier draft stored absolute
timestamps set at funding; a test caught that this quietly charged the sponsor
for the owner's printing delay.

**Bids rank by monthly rate, never by total.** 600 USDC over twelve months is 50
a month; 330 over three is 110. The second wins. Ranking by total would mean a
long cheap run always beats a short valuable one.

**Refunds are claimed, not pushed.** Being outbid credits a balance the bidder
withdraws themselves. Pushing a refund inside the outbid path would let a
contract that rejects transfers make itself impossible to outbid.

**The auction never holds campaign money.** Deposits only. The winner's balance
passes through to the escrow inside the settling transaction.

**The caps are constants, not settings.**

```solidity
uint256 public constant MAX_CAMPAIGN = 500e6;    // 500 USDC
uint256 public constant MAX_TOTAL    = 5_000e6;  // 5,000 USDC
```

There is no audit. Rather than assume the code is correct, the code bounds how
wrong it can be. Raising these means redeploying, which makes it a deliberate
and visible act. **Do not turn them into admin setters.**

**USDC has 6 decimals** — including on Arc, where the ERC-20 interface is 6 and
the native interface is 18 for the same balance. These contracts only ever touch
the ERC-20 interface.

---

## Testing

```bash
forge test
```

| Suite | |
|---|---|
| `PeelbidEscrow.t.sol` | 39 scenarios |
| `EscrowInvariants.t.sol` | 4 invariants |
| `PeelbidAuction.t.sol` | 52 scenarios |
| `AuctionInvariants.t.sol` | 4 invariants |

Invariant testing drives every action in random order across 256 runs × 64
steps. The escrow's four properties: no campaign pays out more than was funded;
the balance always covers what is owed; `totalEscrowed` equals the sum of
remainders; money is never created or destroyed. The auction's four are the
equivalents for deposits.

**Two of these found real faults rather than code faults.** A scenario test
using a twelve-month bid revealed that no such bid could exist under the
campaign cap at the minimum floor price — the design was wrong, not the test. An
invariant found, on its first run, a path where a bidder improved their offer
while locking a smaller deposit, leaving money the contract held and owed to
nobody. Both are documented with their reasoning in the design notes.

Slither 0.11.4 reports no High or Medium findings.

---

## Building

```bash
forge install
forge build
forge test
```

Requires [Foundry](https://getfoundry.sh). OpenZeppelin v5.7, solc pinned to
0.8.36, `via_ir = true` — the auction contract will not compile without it.

### Deploying

Every constructor argument comes from the environment. Nothing is hardcoded.

```bash
cp .env.example .env    # then fill it in
source .env

forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --broadcast
```

On mainnet, transfer ownership to a multisig in the same session:

```bash
cast send $ESCROW "transferOwnership(address)" $SAFE_ADDRESS \
  --rpc-url $RPC_URL --private-key $DEPLOYER_KEY
```

Deploy from a wallet used for nothing else. `.env` is gitignored and must stay
that way.

### Pairing the auction with the escrow

The auction creates campaigns through a narrow role. Appoint it from the
escrow's owner:

```bash
cast send $ESCROW "setCampaignCreator(address)" $AUCTION \
  --rpc-url $RPC_URL --private-key $KEY
```

`campaignCreator` may call `createCampaign` and nothing else — it cannot pause,
change the arbiter, or move money. Revoke by passing the zero address.

---

## Status

The contracts are complete and deployed. The auction is running its first cycle
on Arc testnet and holds no real deposits yet.

There is no audit. Fund accordingly.

## Licence

MIT
