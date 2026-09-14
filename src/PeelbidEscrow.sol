// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PeelbidEscrow
/// @notice Holds a sponsor's USDC and releases it to an owner in tranches as
///         proof of an applied sticker is submitted and left unchallenged.
/// @dev Auctions, bidding and approval happen off-chain. This contract only
///      holds money and enforces time.
contract PeelbidEscrow is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_CAMPAIGN       = 500e6;
    uint256 public constant MAX_TOTAL          = 5_000e6;
    uint64  public constant CHALLENGE_WINDOW   = 7 days;
    uint64  public constant APPLICATION_WINDOW = 14 days;
    uint64  public constant PROOF_DEADLINE     = 14 days;
    uint16  public constant MAX_FEE_BPS        = 1_000;
    uint256 public constant MAX_TRANCHES       = 13;
    uint16  private constant BPS               = 10_000;

    enum CampaignStatus { None, Created, Funded, Completed, Terminated }
    enum TrancheStatus  { Pending, ProofSubmitted, Released, Frozen, Refunded }

    struct Tranche {
        uint16        percentBps;
        uint32        offsetDays;
        uint64        proofAt;
        TrancheStatus status;
        bytes32       proofHash;
    }

    struct Campaign {
        address        owner;
        address        sponsor;
        uint256        total;
        uint256        paidOut;
        uint256        refunded;
        uint64         fundedAt;
        uint64         appliedAt;
        uint16         feeBps;
        CampaignStatus status;
    }

    IERC20  public immutable TOKEN;
    address public arbiter;
    address public feeRecipient;
    /// @notice May call createCampaign. Appointed and revoked by the owner.
    /// @dev Zero until set, in which case only the owner can create campaigns.
    address public campaignCreator;
    uint256 public totalEscrowed;

    mapping(bytes32 => Campaign)  public campaigns;
    mapping(bytes32 => Tranche[]) internal _tranches;

    event CampaignCreated(bytes32 indexed id, address indexed owner, address indexed sponsor, uint256 total, uint16 feeBps);
    event CampaignFunded(bytes32 indexed id, uint256 total, uint64 fundedAt);
    event StickerApplied(bytes32 indexed id, uint64 appliedAt);
    event ProofSubmitted(bytes32 indexed id, uint256 index, bytes32 proofHash);
    event TrancheReleased(bytes32 indexed id, uint256 index, uint256 toOwner, uint256 fee);
    event TrancheChallenged(bytes32 indexed id, uint256 index, address by);
    event TrancheRefunded(bytes32 indexed id, uint256 index, uint256 toSponsor);
    event DisputeResolved(bytes32 indexed id, uint256 index, uint256 toOwner, uint256 toSponsor, uint256 fee);
    event CampaignTerminated(bytes32 indexed id, uint256 refundedToSponsor);
    event CampaignCompleted(bytes32 indexed id);
    event ArbiterChanged(address indexed previous, address indexed next);
     event FeeRecipientChanged(address indexed previous, address indexed next);
    event CampaignCreatorChanged(address indexed previous, address indexed next);

    error NotOwnerOfCampaign();
    error NotSponsor();
    error NotArbiter();
    error CampaignExists();
    error NoSuchCampaign();
    error BadState();
    error BadTrancheIndex();
    error BadSchedule();
    error BadShare();
    error CampaignCapExceeded();
    error TotalCapExceeded();
    error FeeTooHigh();
    error TooEarly();
    error ApplicationWindowMissed();
    error ApplicationWindowStillOpen();
    error NotAppliedYet();
    error AlreadyApplied();
    error ChallengeWindowOpen();
    error ChallengeWindowClosed();
    error ZeroAddress();

     error NotCreator();
 
    modifier onlyArbiter() {
        if (msg.sender != arbiter) revert NotArbiter();
        _;
    }
 
    /// @dev The owner keeps the ability, so nothing that worked before stops.
    modifier onlyCreator() {
        if (msg.sender != owner() && msg.sender != campaignCreator) revert NotCreator();
        _;
    }

    constructor(IERC20 token_, address arbiter_, address feeRecipient_) Ownable(msg.sender) {
        if (address(token_) == address(0) || arbiter_ == address(0) || feeRecipient_ == address(0)) {
            revert ZeroAddress();
        }
        TOKEN = token_;
        arbiter = arbiter_;
        feeRecipient = feeRecipient_;
    }

    // ---------------- views ----------------

    function trancheCount(bytes32 id) external view returns (uint256) {
        return _tranches[id].length;
    }

    function tranche(bytes32 id, uint256 index) external view returns (Tranche memory) {
        if (index >= _tranches[id].length) revert BadTrancheIndex();
        return _tranches[id][index];
    }

    function dueAt(bytes32 id, uint256 index) public view returns (uint64) {
        if (index >= _tranches[id].length) revert BadTrancheIndex();
        Campaign storage c = campaigns[id];
        if (index == 0) return c.fundedAt + APPLICATION_WINDOW;
        if (c.appliedAt == 0) return 0;
        return c.appliedAt + uint64(_tranches[id][index].offsetDays) * 1 days;
    }

    function outstanding(bytes32 id) public view returns (uint256) {
        Campaign storage c = campaigns[id];
        return c.total - c.paidOut - c.refunded;
    }

    function trancheAmount(bytes32 id, uint256 index) public view returns (uint256) {
        if (index >= _tranches[id].length) revert BadTrancheIndex();
        return campaigns[id].total * _tranches[id][index].percentBps / BPS;
    }

    // ---------------- creation and funding ----------------

    function createCampaign(
        bytes32 id,
        address campaignOwner,
        address sponsor,
        uint256 total,
        uint16 feeBps,
        uint16[] calldata percentsBps,
         uint32[] calldata offsetDays
    ) external onlyCreator whenNotPaused {
        if (campaigns[id].status != CampaignStatus.None) revert CampaignExists();
        if (campaignOwner == address(0) || sponsor == address(0)) revert ZeroAddress();
        if (campaignOwner == sponsor) revert BadState();
        if (total == 0 || total > MAX_CAMPAIGN) revert CampaignCapExceeded();
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();

        uint256 n = percentsBps.length;
        if (n < 2 || n > MAX_TRANCHES || n != offsetDays.length) revert BadSchedule();
        if (offsetDays[0] != 0) revert BadSchedule();

        uint256 sum;
        for (uint256 i; i < n; ++i) {
            if (i > 0 && offsetDays[i] <= offsetDays[i - 1]) revert BadSchedule();
            if (percentsBps[i] == 0) revert BadSchedule();
            sum += percentsBps[i];
            _tranches[id].push(Tranche({
                percentBps: percentsBps[i],
                offsetDays: offsetDays[i],
                proofAt: 0,
                status: TrancheStatus.Pending,
                proofHash: bytes32(0)
            }));
        }
        if (sum != BPS) revert BadSchedule();

        Campaign storage c = campaigns[id];
        c.owner   = campaignOwner;
        c.sponsor = sponsor;
        c.total   = total;
        c.feeBps  = feeBps;
        c.status  = CampaignStatus.Created;

        emit CampaignCreated(id, campaignOwner, sponsor, total, feeBps);
    }

    function fund(bytes32 id) external nonReentrant whenNotPaused {
        Campaign storage c = campaigns[id];
        if (c.status == CampaignStatus.None) revert NoSuchCampaign();
        if (c.status != CampaignStatus.Created) revert BadState();
        if (msg.sender != c.sponsor) revert NotSponsor();
        if (totalEscrowed + c.total > MAX_TOTAL) revert TotalCapExceeded();

        c.status   = CampaignStatus.Funded;
        c.fundedAt = uint64(block.timestamp);
        totalEscrowed += c.total;

        TOKEN.safeTransferFrom(msg.sender, address(this), c.total);
        emit CampaignFunded(id, c.total, c.fundedAt);
    }

    // ---------------- proof ----------------

    function submitProof(bytes32 id, uint256 index, bytes32 proofHash) external whenNotPaused {
        Campaign storage c = campaigns[id];
        if (c.status == CampaignStatus.None) revert NoSuchCampaign();
        if (c.status != CampaignStatus.Funded) revert BadState();
        if (msg.sender != c.owner) revert NotOwnerOfCampaign();
        if (index >= _tranches[id].length) revert BadTrancheIndex();
        if (proofHash == bytes32(0)) revert BadState();

        Tranche storage t = _tranches[id][index];
        if (t.status != TrancheStatus.Pending) revert BadState();

        if (index == 0) {
            if (block.timestamp > c.fundedAt + APPLICATION_WINDOW) revert ApplicationWindowMissed();
            c.appliedAt = uint64(block.timestamp);
            emit StickerApplied(id, c.appliedAt);
        } else {
            if (c.appliedAt == 0) revert NotAppliedYet();
            if (block.timestamp < dueAt(id, index)) revert TooEarly();
        }

        t.proofAt   = uint64(block.timestamp);
        t.proofHash = proofHash;
        t.status    = TrancheStatus.ProofSubmitted;
        emit ProofSubmitted(id, index, proofHash);
    }

    // ---------------- release and challenge ----------------

    /// @notice Pay out a tranche whose challenge window has closed. Anyone may call.
    function release(bytes32 id, uint256 index) external nonReentrant whenNotPaused {
        Campaign storage c = campaigns[id];
        if (c.status != CampaignStatus.Funded) revert BadState();
        if (index >= _tranches[id].length) revert BadTrancheIndex();

        Tranche storage t = _tranches[id][index];
        if (t.status != TrancheStatus.ProofSubmitted) revert BadState();
        if (block.timestamp < t.proofAt + CHALLENGE_WINDOW) revert ChallengeWindowOpen();

        uint256 amount  = trancheAmount(id, index);
        uint256 fee     = amount * c.feeBps / BPS;
        uint256 toOwner = amount - fee;

        t.status   = TrancheStatus.Released;
        c.paidOut += amount;
        totalEscrowed -= amount;
        _maybeComplete(id);

        TOKEN.safeTransfer(c.owner, toOwner);
        if (fee > 0) TOKEN.safeTransfer(feeRecipient, fee);
        emit TrancheReleased(id, index, toOwner, fee);
    }

    /// @notice Sponsor disputes a proof. Freezes this tranche only.
    function challenge(bytes32 id, uint256 index) external whenNotPaused {
        Campaign storage c = campaigns[id];
        if (c.status != CampaignStatus.Funded) revert BadState();
        if (msg.sender != c.sponsor) revert NotSponsor();
        if (index >= _tranches[id].length) revert BadTrancheIndex();

        Tranche storage t = _tranches[id][index];
        if (t.status != TrancheStatus.ProofSubmitted) revert BadState();
        if (block.timestamp >= t.proofAt + CHALLENGE_WINDOW) revert ChallengeWindowClosed();

        t.status = TrancheStatus.Frozen;
        emit TrancheChallenged(id, index, msg.sender);
    }

    /// @notice Owner missed a checkpoint by more than PROOF_DEADLINE. Sponsor takes that tranche back.
    /// @dev No arbiter needed. Index 0 is handled by reclaimUnapplied.
    function reclaimMissedTranche(bytes32 id, uint256 index) external nonReentrant {
        Campaign storage c = campaigns[id];
        if (c.status != CampaignStatus.Funded) revert BadState();
        if (msg.sender != c.sponsor) revert NotSponsor();
        if (index == 0 || index >= _tranches[id].length) revert BadTrancheIndex();
        if (c.appliedAt == 0) revert NotAppliedYet();

        Tranche storage t = _tranches[id][index];
        if (t.status != TrancheStatus.Pending) revert BadState();
        if (block.timestamp <= dueAt(id, index) + PROOF_DEADLINE) revert TooEarly();

        uint256 amount = trancheAmount(id, index);

        t.status    = TrancheStatus.Refunded;
        c.refunded += amount;
        totalEscrowed -= amount;
        _maybeComplete(id);

        TOKEN.safeTransfer(c.sponsor, amount);
        emit TrancheRefunded(id, index, amount);
    }

    // ---------------- arbitration ----------------

    function resolve(bytes32 id, uint256 index, uint16 ownerShareBps)
        external
        nonReentrant
        onlyArbiter
    {
        Campaign storage c = campaigns[id];
        if (c.status != CampaignStatus.Funded) revert BadState();
        if (index >= _tranches[id].length) revert BadTrancheIndex();
        if (ownerShareBps > BPS) revert BadShare();

        Tranche storage t = _tranches[id][index];
        if (t.status != TrancheStatus.Frozen) revert BadState();

        uint256 amount     = trancheAmount(id, index);
        uint256 ownerGross = amount * ownerShareBps / BPS;
        uint256 toSponsor  = amount - ownerGross;
        uint256 fee        = ownerGross * c.feeBps / BPS;
        uint256 toOwner    = ownerGross - fee;

        t.status    = ownerShareBps == 0 ? TrancheStatus.Refunded : TrancheStatus.Released;
        c.paidOut  += ownerGross;
        c.refunded += toSponsor;
        totalEscrowed -= amount;
        _maybeComplete(id);

        if (toOwner > 0)   TOKEN.safeTransfer(c.owner, toOwner);
        if (fee > 0)       TOKEN.safeTransfer(feeRecipient, fee);
        if (toSponsor > 0) TOKEN.safeTransfer(c.sponsor, toSponsor);
        emit DisputeResolved(id, index, toOwner, toSponsor, fee);
    }

    function terminate(bytes32 id) external nonReentrant onlyArbiter {
        Campaign storage c = campaigns[id];
        if (c.status != CampaignStatus.Funded) revert BadState();

        uint256 refund = outstanding(id);
        Tranche[] storage ts = _tranches[id];
        for (uint256 i; i < ts.length; ++i) {
            if (ts[i].status != TrancheStatus.Released) ts[i].status = TrancheStatus.Refunded;
        }

        c.refunded += refund;
        c.status    = CampaignStatus.Terminated;
        totalEscrowed -= refund;

        if (refund > 0) TOKEN.safeTransfer(c.sponsor, refund);
        emit CampaignTerminated(id, refund);
    }

    function reclaimUnapplied(bytes32 id) external nonReentrant {
        Campaign storage c = campaigns[id];
        if (c.status != CampaignStatus.Funded) revert BadState();
        if (msg.sender != c.sponsor) revert NotSponsor();
        if (c.appliedAt != 0) revert AlreadyApplied();
        if (block.timestamp <= c.fundedAt + APPLICATION_WINDOW) revert ApplicationWindowStillOpen();

        uint256 refund = outstanding(id);
        Tranche[] storage ts = _tranches[id];
        for (uint256 i; i < ts.length; ++i) ts[i].status = TrancheStatus.Refunded;

        c.refunded += refund;
        c.status    = CampaignStatus.Terminated;
        totalEscrowed -= refund;

        TOKEN.safeTransfer(c.sponsor, refund);
        emit CampaignTerminated(id, refund);
    }

    // ---------------- internal ----------------

    function _maybeComplete(bytes32 id) internal {
        Tranche[] storage ts = _tranches[id];
        for (uint256 i; i < ts.length; ++i) {
            TrancheStatus s = ts[i].status;
            if (s != TrancheStatus.Released && s != TrancheStatus.Refunded) return;
        }
        campaigns[id].status = CampaignStatus.Completed;
        emit CampaignCompleted(id);
    }

    // ---------------- admin ----------------

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setArbiter(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit ArbiterChanged(arbiter, next);
        arbiter = next;
    }

    function setFeeRecipient(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit FeeRecipientChanged(feeRecipient, next);
        feeRecipient = next;
    }
 
    /// @notice Appoint the contract allowed to create campaigns, or revoke by
    ///         passing the zero address. Nothing else about this role exists.
    function setCampaignCreator(address next) external onlyOwner {
        emit CampaignCreatorChanged(campaignCreator, next);
        campaignCreator = next;
    }
 
}