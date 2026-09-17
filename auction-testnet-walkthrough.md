# Auction contract on Arc testnet

A full cycle, by hand, before the contract holds anyone's deposit. 52 tests
and 4 invariants pass locally; none of that proves it behaves on a chain with
a real USDC, a real clock and a real escrow beside it.

Everything below uses the **testnet** escrow. Nothing touches mainnet.

---

## Setup

```bash
cd ~/dev/peelbid-contracts
cp ~/Downloads/DeployAuction.s.sol script/

cat >> .env <<'ENV'

ARC_TESTNET_ESCROW_V2=
ARC_TESTNET_AUCTION=
ENV
```

### Escrow v2 first

The auction calls `fundOnBehalf`, which the v1 escrow at
`0xFE9b1D63552FE9566178E4d6dcd86A2222b52227` doesn't have. Deploy v2 to Arc
testnet before the auction:

```bash
source .env
USDC_ADDRESS=$ARC_USDC_ADDRESS \
ARBITER_ADDRESS=$DEPLOYER_ADDRESS \
FEE_RECIPIENT_ADDRESS=$DEPLOYER_ADDRESS \
forge script script/Deploy.s.sol:Deploy --rpc-url $ARC_TESTNET_RPC --broadcast -vvv
```

On testnet the deployer can be its own arbiter and fee recipient — it makes
the walkthrough one wallet instead of three. **Not on mainnet.**

Put the address in `ARC_TESTNET_ESCROW_V2`.

---

## Deploy the auction

```bash
source .env
USDC_ADDRESS=$ARC_USDC_ADDRESS \
ESCROW_ADDRESS=$ARC_TESTNET_ESCROW_V2 \
FEE_RECIPIENT_ADDRESS=$DEPLOYER_ADDRESS \
forge script script/DeployAuction.s.sol:DeployAuction \
  --rpc-url $ARC_TESTNET_RPC --broadcast -vvv
```

Put the address in `ARC_TESTNET_AUCTION`, then appoint it:

```bash
source .env
cast send $ARC_TESTNET_ESCROW_V2 "setCampaignCreator(address)" $ARC_TESTNET_AUCTION \
  --rpc-url $ARC_TESTNET_RPC --private-key $DEPLOYER_PRIVATE_KEY

cast call $ARC_TESTNET_ESCROW_V2 "campaignCreator()(address)" --rpc-url $ARC_TESTNET_RPC
```

Must return the auction's address. Until it does, settlement reverts.

---

## The walkthrough

Two wallets: `$DEPLOYER_ADDRESS` is the brand, `$OWNER_ADDRESS` is the person
who owns the object. Both need Arc testnet USDC — the owner only for gas.

```bash
source .env
export AUC=$ARC_TESTNET_AUCTION
export ESC=$ARC_TESTNET_ESCROW_V2
export AID=$(cast keccak "arc-auction-001")
export CID=$(cast keccak "arc-campaign-from-auction-001")
export ART=$(cast keccak "brand-artwork-v1")
echo "auction $AID"
echo "campaign $CID"
```

### 1. The owner opens it

Floor 50 USDC a month, runs 1/3/6 (12 won't fit under the 500 cap), 24 hours,
8% fee.

```bash
cast send $AUC "openAuction(bytes32,uint256,uint16,uint64,uint16)" \
  $AID 50000000 7 86400 800 \
  --rpc-url $ARC_TESTNET_RPC --private-key $OWNER_PRIVATE_KEY
```

Check what a bid has to clear:

```bash
cast call $AUC "minimumBid(bytes32,uint8)(uint256)" $AID 3 --rpc-url $ARC_TESTNET_RPC
```

`150000000` — three months at the floor.

### 2. The brand bids

Approve the deposit first. 300 USDC locks 30.

```bash
cast send $ARC_USDC_ADDRESS "approve(address,uint256)" $AUC 500000000 \
  --rpc-url $ARC_TESTNET_RPC --private-key $DEPLOYER_PRIVATE_KEY

cast send $AUC "placeBid(bytes32,uint256,uint8,bytes32)" \
  $AID 300000000 3 $ART \
  --rpc-url $ARC_TESTNET_RPC --private-key $DEPLOYER_PRIVATE_KEY
```

```bash
cast call $AUC "totalHeld()(uint256)" --rpc-url $ARC_TESTNET_RPC
```

`30000000`. The deposit is real money now held by the contract.

### 3. Wait out the clock

24 hours. Come back tomorrow, or open a shorter auction to iterate faster —
`MIN_DURATION` is the floor and it exists so an owner can't open, tip off a
friend, and close before anyone else notices.

```bash
cast send $AUC "endAuction(bytes32)" $AID \
  --rpc-url $ARC_TESTNET_RPC --private-key $DEPLOYER_PRIVATE_KEY
```

Anyone may call this, which is why the brand can. Status becomes `Ended`.

### 4. The owner approves

```bash
cast send $AUC "approveLeader(bytes32)" $AID \
  --rpc-url $ARC_TESTNET_RPC --private-key $OWNER_PRIVATE_KEY
```

48 hours to pay from here.

### 5. The brand settles — the transaction that matters

It pulls the 270 balance, creates the campaign in the escrow and funds it, all
at once.

```bash
cast send $AUC "settle(bytes32,bytes32)" $AID $CID \
  --rpc-url $ARC_TESTNET_RPC --private-key $DEPLOYER_PRIVATE_KEY
```

Then check all five:

```bash
cast call $AUC "totalHeld()(uint256)" --rpc-url $ARC_TESTNET_RPC
cast call $ARC_USDC_ADDRESS "balanceOf(address)(uint256)" $AUC --rpc-url $ARC_TESTNET_RPC
cast call $ARC_USDC_ADDRESS "balanceOf(address)(uint256)" $ESC --rpc-url $ARC_TESTNET_RPC
cast call $ESC "campaigns(bytes32)" $CID --rpc-url $ARC_TESTNET_RPC
cast call $ESC "trancheCount(bytes32)(uint256)" $CID --rpc-url $ARC_TESTNET_RPC
```

| Expected | |
|---|---|
| `totalHeld` | 0 |
| USDC in the auction | **0** |
| USDC in the escrow | 300000000 |
| Campaign sponsor | the brand, **not** the auction |
| Tranches | 4 |

The third and fourth rows are the whole point. The auction holds deposits and
nothing else, and every refund path in the escrow pays the brand because the
sponsor field says so.

### 6. Run the campaign out

From here it is an ordinary escrow campaign:

```bash
cast send $ESC "submitProof(bytes32,uint256,bytes32)" $CID 0 $(cast keccak "applied") \
  --rpc-url $ARC_TESTNET_RPC --private-key $OWNER_PRIVATE_KEY
```

Seven days later, `release(CID, 0)` — or let the keeper do it, once its
campaign list includes this id.

---

## Also worth doing, cheaply

Each needs its own auction id and about ten minutes.

**Outbid and withdraw.** Two bidders, then the loser calls `withdrawRefund()`.
Confirms the credit-don't-push rule holds with real USDC.

**Decline.** Owner calls `declineLeader` instead of approving. Deposit becomes
claimable, auction closes.

**Missed payment.** Approve, then let 48 hours pass without settling, then
anyone calls `paymentMissed`. The deposit lands in the owner's refund balance.

**Expiry.** End an auction and let the owner ignore it for seven days, then
call `expire`. Proves a vanished owner can't strand a bidder's money.

---

## Then, and only then

Mainnet. The auction goes to Arc and Base, and the Safe appoints it on each.
The site switches from database bids to contract bids.

Not before the walkthrough above has run start to finish on a chain.
