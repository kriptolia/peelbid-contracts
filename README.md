# peelbid escrow

USDC escrow for advertising campaigns on physical objects.

A sponsor pays to put their sticker on something someone owns — a car door, a laptop lid, a delivery van. The money sits in this contract and leaves in stages, each stage released against dated proof that the sticker is still applied. Neither party has to trust the other, and neither has to trust us.

**peelbid.com** · [Design document](./peelbid-escrow-design.md)

---

## Deployments

| Network | Address | Status |
|---|---|---|
| Base mainnet (8453) | [`0xf78257D41C8e78dD19e941146B58ebe9f9726635`](https://basescan.org/address/0xf78257D41C8e78dD19e941146B58ebe9f9726635) | Verified · owned by Safe · no funds yet |
| Base Sepolia (84532) | [`0x88064FC8D03f8745Fd131CFc2D902Bc1e2502A77`](https://sepolia.basescan.org/address/0x88064FC8D03f8745Fd131CFc2D902Bc1e2502A77) | Verified · campaign running |
| Arc testnet (5042002) | [`0xFE9b1D63552FE9566178E4d6dcd86A2222b52227`](https://testnet.arcscan.app/address/0xFE9b1D63552FE9566178E4d6dcd86A2222b52227) | Verified · campaign running |

Same bytecode on all three. The contract was written chain-agnostic from the first line — moving to Arc changed one address in an environment file and nothing else.

Live campaign state is readable at [peelbid.com](https://peelbid.com), straight from the chain.

---

## How a campaign works

The terms are agreed off-chain. The operator records them, the sponsor funds, and from that point the contract runs on time and proof alone.

**1. `createCampaign`** — records the owner, the sponsor, the total, the fee, and a tranche schedule. No money moves.

**2. `fund`** — the sponsor transfers USDC in. This starts a 14-day window to get the sticker applied.

**3. `submitProof(id, 0, hash)`** — the owner submits evidence that the sticker is on. **This is what starts the campaign clock**, not the payment. An owner who takes ten days to get something printed doesn't cost the sponsor ten days of their campaign.

**4. Monthly checkpoints** — each tranche becomes due at `appliedAt + offsetDays`. The owner submits fresh proof.

**5. `release(id, index)`** — pays out a tranche whose seven-day challenge window has closed. **Anyone can call this.** The owner's money must not depend on our servers being up.

The fee (8%, capped at 10%) comes out of each tranche as it releases, and only ever from the portion the owner actually receives.

### When things go wrong

| Situation | Function | Who calls it |
|---|---|---|
| Sponsor disputes a proof | `challenge` | sponsor, inside the 7-day window |
| Arbiter splits a frozen tranche | `resolve` | arbiter |
| Sticker removed early | `terminate` | arbiter |
| Sticker never applied in 14 days | `reclaimUnapplied` | sponsor — **no arbiter needed** |
| Owner silent on a checkpoint for 14 days | `reclaimMissedTranche` | sponsor — **no arbiter needed** |

A dispute freezes only the tranche it concerns. A disagreement about month three does not hold months four through six hostage.

---

## Design decisions worth knowing

**Tranches store day offsets, not dates.** `dueAt()` computes `appliedAt + offsetDays × 1 day` on read. The first draft stored absolute timestamps set at funding time; a test caught that this quietly charged the sponsor for the owner's printing delay.

**Release is permissionless.** If peelbid vanished, an owner could still call `release()` from a block explorer once the challenge window closed. This is the difference between escrow and a company holding money.

**The caps are constants, not settings.**

```solidity
uint256 public constant MAX_CAMPAIGN = 500e6;    // 500 USDC
uint256 public constant MAX_TOTAL    = 5_000e6;  // 5,000 USDC
```

There is no audit yet. Rather than assume the code is correct, the code bounds how wrong it can be. Raising these means redeploying, which makes it a deliberate and visible act. Do not turn them into admin setters.

**Checks-effects-interactions everywhere.** Every state write precedes every token transfer. `nonReentrant` sits first in the modifier list on anything that moves tokens.

**USDC has 6 decimals.** Including on Arc, where the ERC-20 interface is 6 and the native interface is 18 — the same balance, two views. This contract only ever touches the ERC-20 interface.

---

## Testing

```bash
forge test              # 27 scenario tests
forge test --match-contract EscrowInvariants -vv
```

Invariant testing drives nine actions in random order across 256 runs × 64 steps — 16,384 calls. Four properties must hold after every single one:

1. No campaign pays out more than was funded into it
2. The contract's USDC balance always covers what it owes
3. `totalEscrowed` equals the sum of every campaign's remainder
4. Money is never created or destroyed

Zero violations. Slither 0.11.4 reports no High or Medium findings; the full triage is in the design document.

---

## Building

```bash
forge install
forge build
forge test
```

Requires [Foundry](https://getfoundry.sh). OpenZeppelin v5.7, solc pinned to 0.8.36.

### Deploying

Every constructor argument comes from the environment. Nothing is hardcoded.

```bash
cp .env.example .env    # then fill it in
source .env

forge script script/Deploy.s.sol:Deploy \
  --rpc-url $RPC_URL \
  --broadcast
```

On mainnet, transfer ownership to a multisig in the same session:

```bash
cast send $ESCROW "transferOwnership(address)" $SAFE_ADDRESS \
  --rpc-url $RPC_URL --private-key $DEPLOYER_KEY
```

Deploy from a wallet used for nothing else. `.env` is gitignored and must stay that way.

---

## Status

The contract is complete. The listing builder, auction, and proof feed are not — they live in the application layer, which is in progress. Arc's public mainnet opens on 16 September and this contract deploys there on day one, alongside Base.

There is no audit. Fund accordingly.

## Licence

MIT
