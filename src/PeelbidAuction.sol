// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IPeelbidEscrow {
    function createCampaign(
        bytes32 id,
        address owner,
        address sponsor,
        uint256 total,
        uint16 feeBps,
        uint16[] calldata percentBps,
        uint32[] calldata offsetDays
    ) external;

    function fundOnBehalf(bytes32 id) external;
}

/**
 * @title PeelbidAuction
 * @notice Auctions one advertising panel at a time and settles the winner
 *         straight into PeelbidEscrow.
 *
 * @dev Three things this contract refuses to do, and they shape everything
 *      else:
 *
 *      It never holds campaign money. Deposits only. The winner's balance
 *      passes through to the escrow inside the settling transaction, so a bug
 *      here cannot reach a campaign that is already running.
 *
 *      It never pushes a refund. Being outbid credits a balance the bidder
 *      withdraws themselves. Sending money to a stranger inside someone
 *      else's transaction lets a hostile bidder make themselves impossible to
 *      outbid.
 *
 *      It never chooses the tranche schedule. That is fixed in code, so a
 *      bidder knows the payment shape before bidding and nobody can hand a
 *      winner a 95%-up-front campaign after the fact.
 */
contract PeelbidAuction is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Limits. There is no audit; exposure is bounded by what the code
    // allows rather than by assuming the code is right.
    // ------------------------------------------------------------------

    uint256 public constant MIN_FLOOR_RATE = 50e6;      // per month
    uint256 public constant MAX_BID        = 500e6;     // one campaign's cap
    uint256 public constant MAX_TOTAL_HELD = 5_000e6;   // all deposits at once

    uint256 public constant MIN_DEPOSIT    = 10e6;
    uint16  public constant DEPOSIT_BPS    = 1_000;     // 10%
    uint16  public constant MAX_FEE_BPS    = 1_000;

    uint64 public constant MIN_DURATION    = 24 hours;
    uint64 public constant MAX_DURATION    = 10 days;
    uint64 public constant EXTEND_WINDOW   = 15 minutes;
    uint64 public constant DECIDE_WINDOW   = 7 days;
    uint64 public constant PAY_WINDOW      = 48 hours;

    uint256 public constant MIN_RAISE_BPS  = 500;       // 5% over the leader

    // ------------------------------------------------------------------

    enum Status {
        None,
        Open,        // taking bids
        Ended,       // closed, waiting on the owner
        Approved,    // a bidder has been chosen, waiting on payment
        Settled,     // campaign created and funded in the escrow
        Cancelled,   // owner pulled it before any bid
        Expired      // owner never decided; everyone withdraws
    }

    struct Auction {
        address owner;
        uint64  endsAt;
        uint64  decideBy;
        uint256 floorRate;     // USDC per month
        uint16  runMask;       // bit 0:1mo, 1:3mo, 2:6mo, 3:12mo
        uint16  feeBps;
        Status  status;

        address leader;
        uint256 leadAmount;
        uint8   leadMonths;
        bytes32 leadArtwork;

        address approved;
        uint256 approvedAmount;
        uint8   approvedMonths;
        bytes32 approvedArtwork;
        uint64  payBy;
    }

    struct Bid {
        uint256 amount;
        uint8   months;
        bytes32 artwork;
        uint256 deposit;
    }

    IERC20 public immutable TOKEN;
    IPeelbidEscrow public immutable ESCROW;

    address public feeRecipient;
    uint256 public totalHeld;

    mapping(bytes32 => Auction) public auctions;
    mapping(bytes32 => mapping(address => Bid)) public bids;
    mapping(address => uint256) public refunds;

    // ------------------------------------------------------------------

    event AuctionOpened(
        bytes32 indexed id, address indexed owner,
        uint256 floorRate, uint16 runMask, uint64 endsAt
    );
    event BidPlaced(
        bytes32 indexed id, address indexed bidder,
        uint256 amount, uint8 months, uint256 monthlyRate, bytes32 artwork
    );
    event Extended(bytes32 indexed id, uint64 endsAt);
    event AuctionEnded(bytes32 indexed id, address indexed leader, uint256 amount);
    event Approved(bytes32 indexed id, address indexed bidder, uint64 payBy);
    event Declined(bytes32 indexed id, address indexed bidder);
    event Settled(bytes32 indexed id, bytes32 indexed campaignId, address indexed sponsor, uint256 total);
    event PaymentMissed(bytes32 indexed id, address indexed bidder, uint256 depositToOwner);
    event Cancelled(bytes32 indexed id);
    event Expired(bytes32 indexed id);
    event RefundCredited(address indexed who, uint256 amount);
    event RefundWithdrawn(address indexed who, uint256 amount);
    event FeeRecipientChanged(address indexed previous, address indexed next);

    // ------------------------------------------------------------------

    error ZeroAddress();
    error NoSuchAuction();
    error AuctionExists();
    error BadState();
    error NotAuctionOwner();
    error NotLeader();
    error BadRunLength();
    error BadDuration();
    error FloorTooLow();
    error BidTooLow();
    error BidTooLarge();
    error TotalCapExceeded();
    error AuctionClosed();
    error AuctionStillOpen();
    error OwnerCannotBid();
    error NoArtwork();
    error NothingToWithdraw();
    error TooEarly();
    error FeeTooHigh();
    error RunExceedsCap();

    // ------------------------------------------------------------------

    constructor(address token, address escrow, address feeRecipient_)
        Ownable(msg.sender)
    {
        if (token == address(0) || escrow == address(0) || feeRecipient_ == address(0)) {
            revert ZeroAddress();
        }
        TOKEN = IERC20(token);
        ESCROW = IPeelbidEscrow(escrow);
        feeRecipient = feeRecipient_;
    }

    // ==================================================================
    // Opening
    // ==================================================================

    /**
     * @notice Put one panel up for auction.
     * @param id        Identifier for this auction, supplied by the site.
     * @param floorRate Minimum monthly rate, in USDC.
     * @param runMask   Which run lengths are acceptable. Bit 0 = 1mo,
     *                  1 = 3mo, 2 = 6mo, 3 = 12mo.
     * @param duration  How long bidding stays open.
     */
    function openAuction(
        bytes32 id,
        uint256 floorRate,
        uint16 runMask,
        uint64 duration,
        uint16 feeBps
    ) external whenNotPaused {
        if (auctions[id].status != Status.None) revert AuctionExists();
        if (floorRate < MIN_FLOOR_RATE) revert FloorTooLow();
        if (runMask == 0 || runMask > 0x0F) revert BadRunLength();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert BadDuration();
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        _checkRunsFitTheCap(floorRate, runMask);

        Auction storage a = auctions[id];
        a.owner     = msg.sender;
        a.floorRate = floorRate;
        a.runMask   = runMask;
        a.feeBps    = feeBps;
        a.endsAt    = uint64(block.timestamp) + duration;
        a.status    = Status.Open;

        emit AuctionOpened(id, msg.sender, floorRate, runMask, a.endsAt);
    }

    /**
     * @dev A run length is only offerable if a bid at the floor still fits
     *      under MAX_BID. At a 50 USDC floor that rules out twelve months,
     *      because the cheapest possible twelve-month bid is 600 USDC and the
     *      escrow will not hold a campaign that large.
     *
     *      Caught here rather than at bid time on purpose. Without it an owner
     *      can offer a run length nobody is able to bid on, and neither side
     *      ever finds out why — the bids simply never arrive.
     */
    function _checkRunsFitTheCap(uint256 floorRate, uint16 runMask) internal pure {
        if (runMask & 0x1 != 0 && floorRate * 1  > MAX_BID) revert RunExceedsCap();
        if (runMask & 0x2 != 0 && floorRate * 3  > MAX_BID) revert RunExceedsCap();
        if (runMask & 0x4 != 0 && floorRate * 6  > MAX_BID) revert RunExceedsCap();
        if (runMask & 0x8 != 0 && floorRate * 12 > MAX_BID) revert RunExceedsCap();
    }

    /// @notice The longest run this floor rate can offer under the cap.
    function longestRunAt(uint256 floorRate) external pure returns (uint8) {
        if (floorRate * 12 <= MAX_BID) return 12;
        if (floorRate * 6  <= MAX_BID) return 6;
        if (floorRate * 3  <= MAX_BID) return 3;
        if (floorRate      <= MAX_BID) return 1;
        return 0;
    }

    /// @notice Pull an auction that nobody has bid on.
    function cancelAuction(bytes32 id) external {
        Auction storage a = auctions[id];
        if (a.status == Status.None) revert NoSuchAuction();
        if (a.status != Status.Open) revert BadState();
        if (a.owner != msg.sender) revert NotAuctionOwner();
        if (a.leader != address(0)) revert BadState();

        a.status = Status.Cancelled;
        emit Cancelled(id);
    }

    // ==================================================================
    // Bidding
    // ==================================================================

    /**
     * @notice Place a bid. Ranked by monthly rate, not by total.
     * @param amount  Total USDC for the whole run.
     * @param months  1, 3, 6 or 12, and the owner must accept it.
     * @param artwork keccak256 of the artwork file. The image lives off-chain;
     *                the hash is what proves the artwork approved is the
     *                artwork supplied.
     */
    function placeBid(bytes32 id, uint256 amount, uint8 months, bytes32 artwork)
        external
        nonReentrant
        whenNotPaused
    {
        Auction storage a = auctions[id];
        if (a.status == Status.None) revert NoSuchAuction();
        if (a.status != Status.Open) revert BadState();
        if (block.timestamp >= a.endsAt) revert AuctionClosed();
        if (msg.sender == a.owner) revert OwnerCannotBid();
        if (artwork == bytes32(0)) revert NoArtwork();
        if (amount > MAX_BID) revert BidTooLarge();
        if (!_runAllowed(a.runMask, months)) revert BadRunLength();

        _checkRate(a, amount, months);

        // The previous leader's deposit becomes claimable. Credited, never
        // sent: an outbid transfer that can fail is an auction a hostile
        // bidder can freeze by refusing to receive.
        if (a.leader != address(0) && a.leader != msg.sender) {
            _credit(id, a.leader, a.leader);
        }

        uint256 toPull = _reprice(id, amount);

        a.leader      = msg.sender;
        a.leadAmount  = amount;
        a.leadMonths  = months;
        a.leadArtwork = artwork;

        bids[id][msg.sender].months  = months;
        bids[id][msg.sender].artwork = artwork;

        if (toPull > 0) TOKEN.safeTransferFrom(msg.sender, address(this), toPull);

        // Anti-snipe: a late bid buys everyone else time to answer it.
        if (a.endsAt - block.timestamp < EXTEND_WINDOW) {
            a.endsAt = uint64(block.timestamp) + EXTEND_WINDOW;
            emit Extended(id, a.endsAt);
        }

        emit BidPlaced(id, msg.sender, amount, months, amount / months, artwork);
    }

    /// @dev Split out of placeBid to keep its stack shallow enough to compile.
    function _checkRate(Auction storage a, uint256 amount, uint8 months) internal view {
        uint256 rate = amount / months;
        if (rate < a.floorRate) revert BidTooLow();
        if (a.leader == address(0)) return;

        uint256 leadRate = a.leadAmount / a.leadMonths;
        if (rate < leadRate + (leadRate * MIN_RAISE_BPS) / 10_000) revert BidTooLow();
    }

    /**
     * @dev Move the caller's deposit to what the new amount requires, and
     *      report what still has to be pulled in.
     *
     *      A deposit can go *down* as well as up. Raising your rate by
     *      shortening the run does exactly that: 500 USDC over six months is
     *      83/month and locks 50, while 300 over three is 100/month and locks
     *      30. The rate rose, the deposit fell.
     *
     *      An earlier version only handled the upward case, so the 20 USDC
     *      difference stayed in the contract belonging to nobody — counted in
     *      totalHeld, owed to no one, unreachable. An invariant found it after
     *      three calls; no amount of staring at the function would have.
     */
    /**
     * @dev Set the caller's deposit for a new amount and report what still has
     *      to be pulled.
     *
     *      Raising your bid usually means topping up. It can also mean locking
     *      *less*, because ranking is by monthly rate and the deposit follows
     *      the total: six months at 300 is 50 a month, and one month at 60
     *      beats it on rate while being a fifth of the money.
     *
     *      An earlier version wrote the smaller deposit and left `totalHeld`
     *      alone. The gap was money the contract held and owed to nobody. An
     *      invariant caught it on its first run — no scenario test would have,
     *      because nobody thinks to write "bidder raises their offer and locks
     *      less than before".
     */
    function _reprice(bytes32 id, uint256 amount) internal returns (uint256 toPull) {
        uint256 want = depositFor(amount);
        uint256 have = bids[id][msg.sender].deposit;

        if (want > have) {
            toPull = want - have;
            if (totalHeld + toPull > MAX_TOTAL_HELD) revert TotalCapExceeded();
            totalHeld += toPull;
        } else if (have > want) {
            uint256 back = have - want;
            totalHeld -= back;
            refunds[msg.sender] += back;
            emit RefundCredited(msg.sender, back);
        }

        bids[id][msg.sender].amount  = amount;
        bids[id][msg.sender].deposit = want;
    }

    /// @notice Close bidding. Permissionless once the clock has run out.
    function endAuction(bytes32 id) external whenNotPaused {
        Auction storage a = auctions[id];
        if (a.status == Status.None) revert NoSuchAuction();
        if (a.status != Status.Open) revert BadState();
        if (block.timestamp < a.endsAt) revert AuctionStillOpen();

        if (a.leader == address(0)) {
            a.status = Status.Cancelled;
            emit Cancelled(id);
            return;
        }

        a.status   = Status.Ended;
        a.decideBy = uint64(block.timestamp) + DECIDE_WINDOW;
        emit AuctionEnded(id, a.leader, a.leadAmount);
    }

    // ==================================================================
    // The owner's decision
    // ==================================================================

    /**
     * @notice Approve the current leader. Their deposit stays locked and they
     *         have PAY_WINDOW to pay the balance.
     */
    function approveLeader(bytes32 id) external whenNotPaused {
        Auction storage a = auctions[id];
        if (a.status == Status.None) revert NoSuchAuction();
        if (a.status != Status.Ended) revert BadState();
        if (a.owner != msg.sender) revert NotAuctionOwner();
        if (block.timestamp > a.decideBy) revert BadState();

        a.approved        = a.leader;
        a.approvedAmount  = a.leadAmount;
        a.approvedMonths  = a.leadMonths;
        a.approvedArtwork = a.leadArtwork;
        a.payBy           = uint64(block.timestamp) + PAY_WINDOW;
        a.status          = Status.Approved;

        emit Approved(id, a.leader, a.payBy);
    }

    /**
     * @notice Refuse the leader. Their deposit becomes claimable and the
     *         auction closes.
     * @dev An owner's right to refuse anyone, without reason, is the product.
     *
     *      It does not pass to the runner-up, and that is a consequence of
     *      refunding deposits the moment someone is outbid. A losing bidder
     *      gets their money back immediately rather than having it locked for
     *      the rest of the auction — which is the right trade — but it means
     *      nobody below the leader is still holding a deposit to be promoted
     *      into. The owner opens a fresh auction and the site tells the other
     *      bidders. Rare case, much less code, no money stuck anywhere.
     */
    function declineLeader(bytes32 id) external whenNotPaused {
        Auction storage a = auctions[id];
        if (a.status == Status.None) revert NoSuchAuction();
        if (a.status != Status.Ended) revert BadState();
        if (a.owner != msg.sender) revert NotAuctionOwner();
        if (block.timestamp > a.decideBy) revert BadState();

        address refused = a.leader;
        _credit(id, refused, refused);

        a.status = Status.Cancelled;
        emit Declined(id, refused);
        emit Cancelled(id);
    }

    /// @notice Nobody decided in time. Everyone's deposit becomes claimable.
    function expire(bytes32 id) external {
        Auction storage a = auctions[id];
        if (a.status == Status.None) revert NoSuchAuction();
        if (a.status != Status.Ended) revert BadState();
        if (block.timestamp <= a.decideBy) revert TooEarly();

        _credit(id, a.leader, a.leader);

        a.status = Status.Expired;
        emit Expired(id);
    }

    // ==================================================================
    // Settlement
    // ==================================================================

    /**
     * @notice Pay the balance. Creates and funds the campaign in one call.
     * @param campaignId The escrow's identifier for the campaign.
     * @dev The deposit is already held here, so only the remainder is pulled.
     *      Both amounts then leave for the escrow in the same transaction —
     *      this contract never sits on campaign money.
     */
    function settle(bytes32 id, bytes32 campaignId) external nonReentrant whenNotPaused {
        Auction storage a = auctions[id];
        if (a.status == Status.None) revert NoSuchAuction();
        if (a.status != Status.Approved) revert BadState();
        if (msg.sender != a.approved) revert NotLeader();
        if (block.timestamp > a.payBy) revert BadState();

        uint256 total = a.approvedAmount;

        // Effects first: stop holding the deposit, then pull the balance.
        uint256 held = bids[id][msg.sender].deposit;
        bids[id][msg.sender].deposit = 0;
        totalHeld -= held;
        a.status = Status.Settled;

        if (total > held) TOKEN.safeTransferFrom(msg.sender, address(this), total - held);

        _openCampaign(id, campaignId);

        emit Settled(id, campaignId, msg.sender, total);
    }

    /// @dev The escrow half of settling, split out so the seven-argument call
    ///      doesn't share a stack frame with the accounting above. Reads the
    ///      auction fresh; by now its status is already Settled, so this can't
    ///      be reached twice.
    function _openCampaign(bytes32 id, bytes32 campaignId) internal {
        Auction storage a = auctions[id];
        uint256 total = a.approvedAmount;

        (uint16[] memory pct, uint32[] memory off) = schedule(a.approvedMonths);

        ESCROW.createCampaign(
            campaignId, a.owner, a.approved, total, a.feeBps, pct, off
        );

        TOKEN.forceApprove(address(ESCROW), total);
        ESCROW.fundOnBehalf(campaignId);
        TOKEN.forceApprove(address(ESCROW), 0);
    }

    /**
     * @notice The winner didn't pay inside the window. Their deposit goes to
     *         the owner and the auction closes.
     * @dev Permissionless — the owner shouldn't have to be watching a clock to
     *      be compensated. Same reasoning as declineLeader for why the panel
     *      doesn't pass down the ranking.
     */
    function paymentMissed(bytes32 id) external nonReentrant whenNotPaused {
        Auction storage a = auctions[id];
        if (a.status == Status.None) revert NoSuchAuction();
        if (a.status != Status.Approved) revert BadState();
        if (block.timestamp <= a.payBy) revert TooEarly();

        address defaulter = a.approved;
        uint256 theirs = _credit(id, defaulter, a.owner);   // compensation

        a.status = Status.Cancelled;
        emit PaymentMissed(id, defaulter, theirs);
        emit Cancelled(id);
    }

    // ==================================================================
    // Refunds
    // ==================================================================

    /// @notice Take back deposits credited to you.
    function withdrawRefund() external nonReentrant {
        uint256 amount = refunds[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        refunds[msg.sender] = 0;
        TOKEN.safeTransfer(msg.sender, amount);
        emit RefundWithdrawn(msg.sender, amount);
    }

    // Note: there is deliberately no "release someone else's stale deposit"
    // function. Refunding on outbid means at most one deposit is held per
    // auction at any moment — the leader's — and every path that ends an
    // auction credits it. A sweeper for orphaned deposits would have nothing
    // to sweep.

    // ==================================================================
    // Views and pure helpers
    // ==================================================================

    /// @notice What a bid of this size locks: 10%, never less than 10 USDC.
    function depositFor(uint256 amount) public pure returns (uint256) {
        uint256 pct = (amount * DEPOSIT_BPS) / 10_000;
        return pct < MIN_DEPOSIT ? MIN_DEPOSIT : pct;
    }

    function monthlyRate(uint256 amount, uint8 months) public pure returns (uint256) {
        return amount / months;
    }

    /// @notice The smallest total that clears the current leader, for a run.
    function minimumBid(bytes32 id, uint8 months) external view returns (uint256) {
        Auction storage a = auctions[id];
        uint256 rate = a.floorRate;
        if (a.leader != address(0)) {
            uint256 leadRate = a.leadAmount / a.leadMonths;
            rate = leadRate + (leadRate * MIN_RAISE_BPS) / 10_000;
        }
        return rate * months;
    }

    /**
     * @notice The tranche schedule for a run length. Fixed in code so that a
     *         bidder knows the payment shape before bidding.
     * @dev First 25%, last 20%, the rest split evenly. One month has no
     *      middle, so it is 40/60.
     */
    function schedule(uint8 months)
        public
        pure
        returns (uint16[] memory percentBps, uint32[] memory offsetDays)
    {
        if (months == 1) {
            percentBps = new uint16[](2);
            offsetDays = new uint32[](2);
            percentBps[0] = 4_000; offsetDays[0] = 0;
            percentBps[1] = 6_000; offsetDays[1] = 30;
            return (percentBps, offsetDays);
        }

        if (months != 3 && months != 6 && months != 12) revert BadRunLength();

        uint256 n = uint256(months) + 1;        // tranches: one per month, plus completion
        percentBps = new uint16[](n);
        offsetDays = new uint32[](n);

        percentBps[0] = 2_500;
        offsetDays[0] = 0;

        uint256 middle = n - 2;                  // months between first and last
        uint256 each = 5_500 / middle;
        uint256 used = 2_500;

        for (uint256 i = 1; i <= middle; ++i) {
            percentBps[i] = uint16(each);
            offsetDays[i] = uint32(i * 30);
            used += each;
        }

        // Whatever rounding left over joins the completion tranche, so the
        // total is exactly 100% and the last payment is never short.
        percentBps[n - 1] = uint16(10_000 - used);
        offsetDays[n - 1] = uint32((n - 1) * 30);
    }

    /// @dev Credit a held deposit to someone's claimable balance. Every path
    ///      that releases a deposit goes through here, so the accounting only
    ///      has to be right in one place.
    function _credit(bytes32 id, address from, address to) internal returns (uint256) {
        uint256 held = bids[id][from].deposit;
        if (held == 0) return 0;
        bids[id][from].deposit = 0;
        totalHeld -= held;
        refunds[to] += held;
        emit RefundCredited(to, held);
        return held;
    }

    function _runAllowed(uint16 mask, uint8 months) internal pure returns (bool) {
        if (months == 1)  return mask & 0x1 != 0;
        if (months == 3)  return mask & 0x2 != 0;
        if (months == 6)  return mask & 0x4 != 0;
        if (months == 12) return mask & 0x8 != 0;
        return false;
    }

    // ==================================================================
    // Admin
    // ==================================================================

    function setFeeRecipient(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit FeeRecipientChanged(feeRecipient, next);
        feeRecipient = next;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
