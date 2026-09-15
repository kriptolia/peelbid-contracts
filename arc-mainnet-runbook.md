# Arc mainnet — 16 September

> **Updated 15 September.** Two things changed since this was written.
>
> **Deploy escrow v2, not v1.** It adds a `campaignCreator` role and
> `fundOnBehalf`, both needed by the auction contract. It also compiles through
> via-IR now, so the bytecode differs from what is verified on Base mainnet and
> the testnets today. All three chains get redeployed; the old addresses stay
> on-chain and are listed at the bottom so nobody mistakes one for current.
>
> **The auction contract does not go out tomorrow.** It is one day old. 52
> tests and 4 invariants pass, and one of those invariants found a real bug on
> its first run — which is the argument for letting it live on testnet before
> it holds anyone's deposit. Escrow only.

Written on 11 September so that nothing has to be worked out on the day.

Everything below has been rehearsed on Arc testnet. The contract is the same bytecode already verified on Base mainnet, Base Sepolia and Arc testnet. What is *not* rehearsed is three unknowns, and they are checked first.

---

## Before anything: three checks

These decide whether the day proceeds. Do them before touching a deploy command.

### 1. The mainnet USDC address

As of 9 September, Circle's docs state plainly that only testnet addresses are published. On testnet it is `0x3600000000000000000000000000000000000000`, a system predeploy, and predeploys usually carry across — but **this address is immutable once it's in the constructor.** Getting it wrong produces a contract that looks fine and can never hold a cent.

Check, in this order:
- `docs.arc.io` → References → Contract addresses
- Circle's own `developers.circle.com/stablecoins/usdc-contract-addresses`
- The explorer at the candidate address: it must answer `symbol()` with `USDC` and `decimals()` with `6`

```bash
export ARC_RPC=<mainnet rpc>
export ARC_USDC=<candidate address>
cast chain-id --rpc-url $ARC_RPC          # expect the Arc mainnet id, not 5042002
cast call $ARC_USDC "symbol()(string)"   --rpc-url $ARC_RPC
cast call $ARC_USDC "decimals()(uint8)"  --rpc-url $ARC_RPC
```

**Abort if:** the address isn't published anywhere official, or those two calls don't return `USDC` and `6`. Deploying against a guess is not a day-one story worth having. Say publicly that we're waiting on the address and deploy when it's confirmed — that reads as careful, not late.

### 2. Gas

Testnet swung between roughly 2,800 and 16,000 gwei in a single afternoon, which made a deploy cost anywhere from 21 to 150 USDC. Uniswap's integration note describes a designed floor of 20 gwei, at which a 250k-gas transaction is around half a cent — so the testnet figures were almost certainly launch-week congestion rather than the real model.

```bash
cast gas-price --rpc-url $ARC_RPC
cast base-fee  --rpc-url $ARC_RPC
```

Deploy costs about 3.98M gas. At 20 gwei that's pennies; at 5,000 gwei it's about 20 USDC; at 16,000 gwei it's about 64 USDC.

**Wait, don't abort, if** the price is absurd. It moves. Watch it:

```bash
while true; do
  P=$(cast gas-price --rpc-url $ARC_RPC)
  echo "$(date +%H:%M) gas=$P  deploy≈$(echo "scale=2; $P*3980000/1000000000000000000" | bc) USDC"
  sleep 60
done
```

### 3. The RPC domain

`rpc.testnet.arc.io` is blocked by common ad blockers — `arc.io` sat on filter lists from a previous owner, and every RPC Circle publishes is a subdomain of it. If mainnet uses the same domain, every browser-side read on peelbid.com fails for a meaningful slice of visitors, and the site's live-escrow section shows its "blocked by your browser" state instead of the campaign.

This doesn't stop the deploy. It does change what we ship on the site that day, and it's worth raising with Circle either way.

---

## Wallet and Safe

**Fresh deploy wallet.** Not the Base mainnet deployer, not the testnet one, not a personal wallet.

```bash
cast wallet new
```

Store it in the password manager. It needs enough USDC to cover gas plus a wide margin — if gas is at 5,000 gwei, hold 60 USDC; if it's near the 20 gwei floor, 5 USDC is plenty. Overfund rather than run dry mid-deploy.

**Safe.** `0xc2C9F41778Dda1dd38C6D0b08eC730D675c7bA2C` already exists and the Safe UI lists Arc as a supported network. Activate it on Arc mainnet before deploying — the constructor takes the Safe as arbiter and fee recipient, and an address with no contract behind it can't arbitrate anything.

```bash
cast code $SAFE_ADDRESS --rpc-url $ARC_RPC | head -c 20
```

`0x` means not activated. Anything longer means it's live.

---

## Deploy

Environment, then simulate, then broadcast. No shortcuts — the simulation is where a wrong address gets caught.

```bash
cd ~/dev/peelbid-contracts
source .env

export ARC_RPC=<mainnet rpc>
export ARC_USDC=<confirmed address>
export ARC_DEPLOYER_KEY=<fresh key>
export SAFE_ADDRESS=0xc2C9F41778Dda1dd38C6D0b08eC730D675c7bA2C
```

**Simulate:**

```bash
USDC_ADDRESS=$ARC_USDC \
ARBITER_ADDRESS=$SAFE_ADDRESS \
FEE_RECIPIENT_ADDRESS=$SAFE_ADDRESS \
DEPLOYER_PRIVATE_KEY=$ARC_DEPLOYER_KEY \
forge script script/Deploy.s.sol:Deploy --rpc-url $ARC_RPC -vvv
```

Read the output before going further:

| Line | Must be |
|---|---|
| `USDC:` | the confirmed mainnet USDC |
| `Arbiter:` | the Safe |
| `Fee recipient:` | the Safe |
| `Chain` | Arc mainnet's id |
| `MAX_CAMPAIGN` | `500000000` |
| `MAX_TOTAL` | `5000000000` |
| `Estimated amount required` | comfortably under the wallet balance |

**Broadcast:**

```bash
USDC_ADDRESS=$ARC_USDC \
ARBITER_ADDRESS=$SAFE_ADDRESS \
FEE_RECIPIENT_ADDRESS=$SAFE_ADDRESS \
DEPLOYER_PRIVATE_KEY=$ARC_DEPLOYER_KEY \
forge script script/Deploy.s.sol:Deploy --rpc-url $ARC_RPC --broadcast -vvv
```

Write down the contract address and the transaction hash.

---

## Immediately after

**Verify the state on-chain.** Four calls, all four must be right:

```bash
export ARC_ESCROW=<new address>
cast call $ARC_ESCROW "TOKEN()(address)"        --rpc-url $ARC_RPC
cast call $ARC_ESCROW "arbiter()(address)"      --rpc-url $ARC_RPC
cast call $ARC_ESCROW "feeRecipient()(address)" --rpc-url $ARC_RPC
cast call $ARC_ESCROW "MAX_CAMPAIGN()(uint256)" --rpc-url $ARC_RPC
```

**Verify the source.** Sourcify worked on Arc testnet; try it first, fall back to Blockscout against the mainnet explorer.

```bash
forge verify-contract $ARC_ESCROW \
  src/PeelbidEscrow.sol:PeelbidEscrow \
  --chain-id <arc mainnet id> \
  --verifier sourcify \
  --constructor-args $(cast abi-encode "constructor(address,address,address)" \
      $ARC_USDC $SAFE_ADDRESS $SAFE_ADDRESS)
```

**Hand ownership to the Safe.** Same session, before anything else. Until this runs, one key controls `pause`, `setArbiter` and `createCampaign`.

```bash
cast send $ARC_ESCROW "transferOwnership(address)" $SAFE_ADDRESS \
  --rpc-url $ARC_RPC --private-key $ARC_DEPLOYER_KEY

cast call $ARC_ESCROW "owner()(address)" --rpc-url $ARC_RPC   # must be the Safe
```

**Do not fund a campaign.** Same discipline as Base mainnet: nothing goes in until `release()` has been proven on a real chain, which happens on the 14th on Base Sepolia. Deploying and funding are separate decisions and separate days.

---

## Site

The live-escrow section reads two testnets. Adding Arc mainnet is one entry in `NETS` inside `components/LiveEscrow.js`:

```js
arcMain: {
  label: "Arc", id: <chain id>,
  rpcs: ["<mainnet rpc>"],
  escrow: "<new address>",
  campaign: null,              // deployed, unfunded — the component shows this honestly
  explorer: "<mainnet explorer>",
  note: "gas paid in USDC",
},
```

The component already handles a network with no campaign. Update the header status line to `Live on Arc · Base` and push.

---

## Redeploy Base as well

Base mainnet holds no funds and has no campaigns, so replacing it costs
nothing but gas and about ten minutes. Doing it now means all three chains run
the same bytecode; doing it after the first real campaign would mean migrating
live money.

```bash
source .env
USDC_ADDRESS=$BASE_USDC \
ARBITER_ADDRESS=$SAFE_ADDRESS \
FEE_RECIPIENT_ADDRESS=$SAFE_ADDRESS \
DEPLOYER_PRIVATE_KEY=$MAINNET_DEPLOYER_KEY \
forge script script/Deploy.s.sol:Deploy --rpc-url $BASE_MAINNET_RPC --broadcast -vvv
```

Then verify, then transfer ownership, exactly as for Arc.

Base Sepolia and Arc testnet get the same treatment, but there is no rush:
their campaigns are finished or finishing, and the site can point at either
version. Do them when convenient.

**Superseded addresses.** Record these so a future reader doesn't take one for
the live contract:

| Chain | v1 address | Status |
|---|---|---|
| Base mainnet | `0xf78257D41C8e78dD19e941146B58ebe9f9726635` | retired, never funded |
| Base Sepolia | `0x88064FC8D03f8745Fd131CFc2D902Bc1e2502A77` | retired, one campaign completed |
| Arc testnet | `0xFE9b1D63552FE9566178E4d6dcd86A2222b52227` | retired, one campaign running |

---

## Do not fund a campaign on the 16th

Deploy, verify, hand over ownership, announce. Nothing goes into the contract that day.

Both testnet releases have now happened — Base Sepolia on the 14th, Arc
testnet on the 15th, the second one triggered by the keeper on its schedule
with nobody watching. So the cycle *has* been proven.

What has not been proven is **this build**. Escrow v2 is new code compiled a
new way, and it will be hours old. Give it a campaign on testnet first and let
a tranche release from it before any real money goes near the mainnet copy.

A small real campaign on Arc can follow a few days later, and it will be a better announcement then — a funded campaign with a working release behind it says more than an empty contract on launch day.

---

## The two days before

**14 September — done.** Base Sepolia's first tranche released: 2.76 USDC to
the owner, 0.24 in fee, 9 USDC still held. Triggered by hand after the keeper's
repository variables turned out not to reach the job; that is fixed, and config
now lives in the workflow file where it can't go missing.

For reference, the manual path:

```bash
cd ~/dev/peelbid-keeper
# edit .env: DRY_RUN=false
node keeper.js
```

Expect: 2.76 USDC to the owner, 0.24 to the fee recipient, 9 USDC left in escrow. Check all three on the explorer, and check the site's escrow section shows tranche 01 as released.

This is the last unproven step in the entire lifecycle, and it doubles as the keeper's first real run. Two things proven in one transaction.

**15 September — done.** Arc testnet's first tranche released. The keeper did
it on its own schedule, which is the first time the whole thing ran end to end
without a person involved.

Also on the 15th: activate the Safe on Arc, fund the deploy wallet, and have the announcement drafts ready. Leave nothing for the morning except the three checks.

---

## Announcement

Only after the four state calls pass and ownership sits with the Safe. The post carries the transaction hash — that's the whole point of having spent a week on this.

Draft, to be finalised with the real hash:

```
peelbid's escrow is live on Arc mainnet.

<address>

Deployed in block <n>, verified, owned by a Safe from the first block — the
wallet that deployed it has no authority over it. Same bytecode that's been
running on Base mainnet and two testnets for a week.

We came to Arc for one reason. The person earning here often isn't a crypto
user — they're someone with a car, a laptop, a delivery van. Getting paid
on-chain normally means first holding a volatile token you never wanted, just
to cover fees on your own money. On Arc, gas is USDC. That step disappears.

Nothing funded yet. Caps are in the code: 500 USDC per campaign, 5,000 total,
because there's no audit and exposure should be bounded by what the code
allows rather than by hope.

tx: <hash>
peelbid.com
```

Then: the Circle Discord if the application has gone through, and a reply in the Arc builder threads with the address.

---

## If it goes wrong

**USDC address unconfirmed** — don't deploy. Post that we're waiting on it. Deploy the day it lands.

**Gas absurd** — wait. There is no deadline inside the day.

**Deploy reverts** — read the revert. `ZeroAddress` means an env var didn't load; `source .env` and check each one with `echo`.

**Wrong constructor arg discovered after deploy** — `arbiter` and `feeRecipient` are fixable with `setArbiter` and `setFeeRecipient` from the Safe. `TOKEN` is immutable: redeploy, and say plainly what happened. A redeployment explained is a smaller problem than a wrong contract left standing.

**Verification fails** — the contract still works. Retry with Blockscout, and don't let it hold up the announcement; add it when it lands.
