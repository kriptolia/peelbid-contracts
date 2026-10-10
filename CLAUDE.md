# peelbid-contracts

Foundry. Two contracts: the escrow (PeelbidEscrow: campaigns, tranches,
proof hashes, permissionless release, disputes resolved by the arbiter) and
the auction (bids with a 10% deposit, owner approval within 7 days, winner
pays within 48 hours, settles into the escrow). Arc testnet (chain 5042002)
is live and verified; Arc mainnet next, from runbooks in ../peelbid-ops.

The full history and every decision: `@../peelbid-ops/CLAUDE.md`, section
"Decisions already made: do not relitigate" first.

## Rules, no exceptions

- Function → test → `forge test`. Test refusals and reverts, not only the
  happy path. A change to anything that moves tokens needs a test that
  tries to move them wrongly.
- Checks-effects-interactions always; nonReentrant on anything moving
  tokens; USDC has 6 decimals.
- The constants stay: FEE_BPS 800 (max 1000), MIN_FLOOR_RATE 50, MAX_BID
  500, MIN_RAISE_BPS 500, deposit 10% (min 10 USDC), runs 1/3/6/12 months,
  caps 500 USDC per campaign and 5,000 total. They exist because there is
  no audit. Do not remove or soften them.
- release() stays permissionless. Only the disputed tranche freezes. The
  fee is taken only on what the owner receives. resolve(bytes32,uint256,
  uint16) records only the split; the reason lives off-chain with the site.
- Never write a private key into any file in this repo. .env is the only
  place keys live and it is git-ignored. Before any cast command:
  `set -a; source .env; set +a`. Keys by name only: DEPLOYER_PRIVATE_KEY
  (testnet deployer and arbiter), ARC_DEPLOYER_KEY (Arc mainnet). Check the
  address with `cast wallet address` before using a key for anything.
- Mainnet decisions go through the 2-of-3 Safe, never a single key.
- No em dashes in comments, messages, docs or commit messages. Explain
  what the code does and why; the author is new to Solidity.

## Run and check

    forge build
    forge test -vv
    set -a; source .env; set +a
    cast call <address> "<sig>" <args> --rpc-url $ARC_TESTNET_RPC

Selectors with `cast sig "name(types)"`; a wrong selector reads as
"execution reverted" from the site and is not a contract bug. After a
deploy: verify on the explorer, then point the site (NEXT_PUBLIC_AUCTION_*)
and the keeper at it, in that order, following runbooks/auction-swap.md.
