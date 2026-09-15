// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PeelbidAuction} from "../src/PeelbidAuction.sol";
import {PeelbidEscrow} from "../src/PeelbidEscrow.sol";
import {MockUSDC} from "./MockUSDC.sol";

contract PeelbidAuctionTest is Test {
    PeelbidAuction auction;
    PeelbidEscrow escrow;
    MockUSDC usdc;

    address carOwner = makeAddr("carOwner");
    address brandA   = makeAddr("brandA");
    address brandB   = makeAddr("brandB");
    address brandC   = makeAddr("brandC");
    address arbiter  = makeAddr("arbiter");
    address feeSink  = makeAddr("feeSink");

    bytes32 constant AID  = keccak256("auction-1");
    bytes32 constant CID  = keccak256("campaign-1");
    bytes32 constant ART  = keccak256("artwork.png");
    bytes32 constant ART2 = keccak256("artwork-2.png");

    uint256 constant FLOOR = 100e6;   // 100 USDC a month
    uint16  constant FEE   = 800;     // 8%

    // bit 0:1mo  1:3mo  2:6mo  3:12mo
    //
    // Not every run length fits at every floor. MAX_BID is 500 USDC, so a
    // 100/month floor can offer 1mo (100) and 3mo (300) but not 6mo (600).
    // The contract rejects a mask that promises what nobody could bid.
    uint16 constant RUNS_AT_100 = 0x03;     // 1mo and 3mo
    uint16 constant RUNS_AT_50  = 0x07;     // 1, 3 and 6 at a 50 floor

    function setUp() public {
        usdc = new MockUSDC();
        escrow = new PeelbidEscrow(IERC20(address(usdc)), arbiter, feeSink);
        auction = new PeelbidAuction(address(usdc), address(escrow), feeSink);

        // The one link between them: the auction may create campaigns, and
        // nothing else.
        escrow.setCampaignCreator(address(auction));

        for (uint256 i; i < 3; ++i) {
            address b = i == 0 ? brandA : i == 1 ? brandB : brandC;
            usdc.mint(b, 10_000e6);
            vm.prank(b);
            usdc.approve(address(auction), type(uint256).max);
        }
    }

    // ---------------- helpers ----------------

    function _open() internal {
        vm.prank(carOwner);
        auction.openAuction(AID, FLOOR, RUNS_AT_100, 3 days, FEE);
    }

    function _bid(address who, uint256 amount, uint8 months) internal {
        vm.prank(who);
        auction.placeBid(AID, amount, months, ART);
    }

    function _status() internal view returns (PeelbidAuction.Status) {
        (,,,,,, PeelbidAuction.Status s,,,,,,,,,) = auction.auctions(AID);
        return s;
    }

    function _leader() internal view returns (address l) {
        (,,,,,,, l,,,,,,,,) = auction.auctions(AID);
    }

    // ================================================================
    // Opening
    // ================================================================

    function test_OpenAuction() public {
        _open();
        assertTrue(_status() == PeelbidAuction.Status.Open);
    }

    function test_OpenRevertsBelowMinimumFloor() public {
        vm.prank(carOwner);
        vm.expectRevert(PeelbidAuction.FloorTooLow.selector);
        auction.openAuction(AID, 49e6, RUNS_AT_100, 3 days, FEE);
    }

    function test_OpenRevertsOnShortAndLongDurations() public {
        vm.startPrank(carOwner);

        vm.expectRevert(PeelbidAuction.BadDuration.selector);
        auction.openAuction(AID, FLOOR, RUNS_AT_100, 23 hours, FEE);

        vm.expectRevert(PeelbidAuction.BadDuration.selector);
        auction.openAuction(AID, FLOOR, RUNS_AT_100, 11 days, FEE);

        vm.stopPrank();
    }

    function test_OpenRevertsOnEmptyRunMask() public {
        vm.prank(carOwner);
        vm.expectRevert(PeelbidAuction.BadRunLength.selector);
        auction.openAuction(AID, FLOOR, 0, 3 days, FEE);
    }

    function test_OpenRevertsTwiceOnSameId() public {
        _open();
        vm.prank(carOwner);
        vm.expectRevert(PeelbidAuction.AuctionExists.selector);
        auction.openAuction(AID, FLOOR, RUNS_AT_100, 3 days, FEE);
    }

    function test_CancelBeforeAnyBid() public {
        _open();
        vm.prank(carOwner);
        auction.cancelAuction(AID);
        assertTrue(_status() == PeelbidAuction.Status.Cancelled);
    }

    function test_CancelRevertsOnceBidOn() public {
        _open();
        _bid(brandA, 300e6, 3);
        vm.prank(carOwner);
        vm.expectRevert(PeelbidAuction.BadState.selector);
        auction.cancelAuction(AID);
    }

    // ================================================================
    // Bidding
    // ================================================================

    function test_FirstBidMustClearTheFloor() public {
        _open();
        vm.prank(brandA);
        vm.expectRevert(PeelbidAuction.BidTooLow.selector);
        auction.placeBid(AID, 297e6, 3, ART);   // 99/month
    }

    function test_BidAtTheFloorIsAccepted() public {
        _open();
        _bid(brandA, 300e6, 3);                  // exactly 100/month
        assertEq(_leader(), brandA);
    }

    function test_RankingIsByMonthlyRateNotTotal() public {
        _open();
        _bid(brandA, 300e6, 3);                  // 100/month, 300 total
        _bid(brandB, 110e6, 1);                  // 110/month, 110 total
        assertEq(_leader(), brandB);             // a third of the money, and it wins
    }

    function test_RaiseMustBeatLeaderByFivePercent() public {
        _open();
        _bid(brandA, 300e6, 3);                  // 100/month

        vm.prank(brandB);
        vm.expectRevert(PeelbidAuction.BidTooLow.selector);
        auction.placeBid(AID, 312e6, 3, ART);    // 104/month, not enough

        _bid(brandB, 315e6, 3);                  // 105/month
        assertEq(_leader(), brandB);
    }

    function test_OwnerCannotBidOnTheirOwnPanel() public {
        _open();
        usdc.mint(carOwner, 1_000e6);
        vm.startPrank(carOwner);
        usdc.approve(address(auction), type(uint256).max);
        vm.expectRevert(PeelbidAuction.OwnerCannotBid.selector);
        auction.placeBid(AID, 300e6, 3, ART);
        vm.stopPrank();
    }

    function test_RunLengthMustBeOneTheOwnerAccepts() public {
        vm.prank(carOwner);
        auction.openAuction(AID, FLOOR, 0x2, 3 days, FEE);   // 3mo only

        vm.prank(brandA);
        vm.expectRevert(PeelbidAuction.BadRunLength.selector);
        auction.placeBid(AID, 100e6, 1, ART);
    }

    function test_BidRevertsWithoutArtwork() public {
        _open();
        vm.prank(brandA);
        vm.expectRevert(PeelbidAuction.NoArtwork.selector);
        auction.placeBid(AID, 300e6, 3, bytes32(0));
    }

    function test_BidRevertsOverMaxBid() public {
        _open();
        vm.prank(brandA);
        vm.expectRevert(PeelbidAuction.BidTooLarge.selector);
        auction.placeBid(AID, 501e6, 3, ART);
    }

    function test_BidRevertsAfterTheClockRunsOut() public {
        _open();
        skip(3 days);
        vm.prank(brandA);
        vm.expectRevert(PeelbidAuction.AuctionClosed.selector);
        auction.placeBid(AID, 300e6, 3, ART);
    }

    function test_CannotOfferARunNobodyCouldBidOn() public {
        // 12mo at a 100 floor would need 1,200 USDC; the cap is 500.
        vm.prank(carOwner);
        vm.expectRevert(PeelbidAuction.RunExceedsCap.selector);
        auction.openAuction(AID, FLOOR, 0x08, 3 days, FEE);

        // 6mo at 100 is 600 — also over.
        vm.prank(carOwner);
        vm.expectRevert(PeelbidAuction.RunExceedsCap.selector);
        auction.openAuction(AID, FLOOR, 0x04, 3 days, FEE);
    }

    function test_LowerFloorsUnlockLongerRuns() public {
        vm.prank(carOwner);
        auction.openAuction(AID, 50e6, RUNS_AT_50, 3 days, FEE);   // 6mo = 300, fits

        _bid(brandA, 300e6, 6);
        assertEq(_leader(), brandA);
    }

    function test_LongestRunAtReportsTheCeiling() public view {
        assertEq(auction.longestRunAt(40e6), 12);   // 480 fits
        assertEq(auction.longestRunAt(50e6), 6);    // 600 doesn't, 300 does
        assertEq(auction.longestRunAt(100e6), 3);   // 600 doesn't, 300 does
        assertEq(auction.longestRunAt(200e6), 1);   // 600 doesn't, 200 does
    }

    // ================================================================
    // Deposits
    // ================================================================

    function test_DepositIsTenPercentWithATenDollarFloor() public view {
        assertEq(auction.depositFor(50e6), 10e6);    // 10% would be 5
        assertEq(auction.depositFor(100e6), 10e6);   // exactly at the floor
        assertEq(auction.depositFor(300e6), 30e6);
        assertEq(auction.depositFor(500e6), 50e6);
    }

    function test_BiddingLocksTheDeposit() public {
        _open();
        uint256 before = usdc.balanceOf(brandA);
        _bid(brandA, 300e6, 3);
        assertEq(usdc.balanceOf(brandA), before - 30e6);
        assertEq(auction.totalHeld(), 30e6);
    }

    function test_RaisingYourOwnBidTopsUpRatherThanDoubling() public {
        _open();
        _bid(brandA, 300e6, 3);                  // locks 30
        uint256 mid = usdc.balanceOf(brandA);

        _bid(brandA, 400e6, 3);                  // wants 40, should pull 10
        assertEq(usdc.balanceOf(brandA), mid - 10e6);
        assertEq(auction.totalHeld(), 40e6);
    }

    function test_ShorteningTheRunReturnsTheDifference() public {
        // Found by the invariant suite. Raising the monthly rate by shortening
        // the run lowers the deposit, and the difference has to come back.
        vm.prank(carOwner);
        auction.openAuction(AID, 50e6, RUNS_AT_50, 3 days, FEE);

        vm.prank(brandA);
        auction.placeBid(AID, 500e6, 6, ART);        // 83/month, locks 50
        assertEq(auction.totalHeld(), 50e6);

        vm.prank(brandA);
        auction.placeBid(AID, 300e6, 3, ART);        // 100/month, locks 30

        assertEq(auction.totalHeld(), 30e6);
        assertEq(auction.refunds(brandA), 20e6);     // not stranded

        uint256 before = usdc.balanceOf(brandA);
        vm.prank(brandA);
        auction.withdrawRefund();
        assertEq(usdc.balanceOf(brandA), before + 20e6);
    }

    function test_RaisingTheRateWhileLoweringTheTotalReturnsTheDifference() public {
        // Six months at 300 is 50/month. One month at 60 is 60/month — a
        // better bid on a fifth of the money, so the deposit shrinks from 30
        // to 10 and 20 has to come back. The invariant suite found this.
        vm.prank(carOwner);
        auction.openAuction(AID, 50e6, RUNS_AT_50, 3 days, FEE);

        _bid(brandA, 300e6, 6);
        assertEq(auction.totalHeld(), 30e6);

        _bid(brandA, 60e6, 1);
        assertEq(auction.totalHeld(), 10e6);
        assertEq(auction.refunds(brandA), 20e6);

        (,,, uint256 dep) = auction.bids(AID, brandA);
        assertEq(dep, 10e6);
        assertEq(usdc.balanceOf(address(auction)), 30e6);   // 10 held + 20 owed
    }

    function test_BeingOutbidCreditsARefundItDoesNotSend() public {
        _open();
        _bid(brandA, 300e6, 3);
        uint256 afterBid = usdc.balanceOf(brandA);

        _bid(brandB, 400e6, 3);

        // Credited, not pushed: the balance hasn't moved yet.
        assertEq(usdc.balanceOf(brandA), afterBid);
        assertEq(auction.refunds(brandA), 30e6);
        assertEq(auction.totalHeld(), 40e6);

        vm.prank(brandA);
        auction.withdrawRefund();
        assertEq(usdc.balanceOf(brandA), afterBid + 30e6);
        assertEq(auction.refunds(brandA), 0);
    }

    function test_WithdrawRevertsWithNothingOwed() public {
        vm.prank(brandA);
        vm.expectRevert(PeelbidAuction.NothingToWithdraw.selector);
        auction.withdrawRefund();
    }

    function test_OnlyOneDepositIsEverHeldPerAuction() public {
        _open();
        _bid(brandA, 300e6, 3);
        _bid(brandB, 400e6, 3);
        _bid(brandC, 500e6, 3);
        assertEq(auction.totalHeld(), 50e6);     // brandC's alone
    }

    // ================================================================
    // Anti-snipe
    // ================================================================

    function test_LateBidExtendsTheClock() public {
        _open();
        skip(3 days - 5 minutes);

        uint64 endBefore = _endsAt();
        _bid(brandA, 300e6, 3);
        uint64 endAfter = _endsAt();

        assertGt(endAfter, endBefore);
        assertEq(endAfter, uint64(block.timestamp) + 15 minutes);
    }

    function test_ExtensionsCanChain() public {
        _open();
        skip(3 days - 1 minutes);
        _bid(brandA, 300e6, 3);

        skip(14 minutes);
        _bid(brandB, 400e6, 3);                  // still inside the window

        assertEq(_endsAt(), uint64(block.timestamp) + 15 minutes);
    }

    function test_EarlyBidDoesNotExtend() public {
        _open();
        uint64 endBefore = _endsAt();
        _bid(brandA, 300e6, 3);
        assertEq(_endsAt(), endBefore);
    }

    function _endsAt() internal view returns (uint64 e) {
        (, e,,,,,,,,,,,,,,) = auction.auctions(AID);
    }

    // ================================================================
    // Ending
    // ================================================================

    function test_EndIsPermissionless() public {
        _open();
        _bid(brandA, 300e6, 3);
        skip(3 days);

        vm.prank(makeAddr("passer-by"));
        auction.endAuction(AID);
        assertTrue(_status() == PeelbidAuction.Status.Ended);
    }

    function test_EndRevertsWhileStillOpen() public {
        _open();
        _bid(brandA, 300e6, 3);
        vm.expectRevert(PeelbidAuction.AuctionStillOpen.selector);
        auction.endAuction(AID);
    }

    function test_EndWithNoBidsCancels() public {
        _open();
        skip(3 days);
        auction.endAuction(AID);
        assertTrue(_status() == PeelbidAuction.Status.Cancelled);
    }

    // ================================================================
    // The owner's decision
    // ================================================================

    function test_ApproveStartsThePaymentWindow() public {
        _open();
        _bid(brandA, 300e6, 3);
        skip(3 days);
        auction.endAuction(AID);

        vm.prank(carOwner);
        auction.approveLeader(AID);
        assertTrue(_status() == PeelbidAuction.Status.Approved);
    }

    function test_OnlyTheOwnerDecides() public {
        _open();
        _bid(brandA, 300e6, 3);
        skip(3 days);
        auction.endAuction(AID);

        vm.prank(brandB);
        vm.expectRevert(PeelbidAuction.NotAuctionOwner.selector);
        auction.approveLeader(AID);
    }

    function test_DecliningRefundsAndClosesTheAuction() public {
        _open();
        _bid(brandA, 300e6, 3);
        skip(3 days);
        auction.endAuction(AID);

        vm.prank(carOwner);
        auction.declineLeader(AID);

        assertTrue(_status() == PeelbidAuction.Status.Cancelled);
        assertEq(auction.refunds(brandA), 30e6);
        assertEq(auction.totalHeld(), 0);
    }

    function test_DecideWindowExpiresAndFreesTheDeposit() public {
        _open();
        _bid(brandA, 300e6, 3);
        skip(3 days);
        auction.endAuction(AID);

        skip(7 days + 1);
        auction.expire(AID);                     // anyone may call it

        assertTrue(_status() == PeelbidAuction.Status.Expired);
        assertEq(auction.refunds(brandA), 30e6);
    }

    function test_ExpireRevertsWhileTheOwnerStillHasTime() public {
        _open();
        _bid(brandA, 300e6, 3);
        skip(3 days);
        auction.endAuction(AID);

        vm.expectRevert(PeelbidAuction.TooEarly.selector);
        auction.expire(AID);
    }

    function test_ApproveRevertsAfterTheDecideWindow() public {
        _open();
        _bid(brandA, 300e6, 3);
        skip(3 days);
        auction.endAuction(AID);
        skip(7 days + 1);

        vm.prank(carOwner);
        vm.expectRevert(PeelbidAuction.BadState.selector);
        auction.approveLeader(AID);
    }

    // ================================================================
    // Settlement — the part that matters
    // ================================================================

    function _toApproved(uint256 amount, uint8 months) internal {
        _open();
        vm.prank(brandA);
        auction.placeBid(AID, amount, months, ART);
        skip(3 days);
        auction.endAuction(AID);
        vm.prank(carOwner);
        auction.approveLeader(AID);
    }

    function test_SettleCreatesAndFundsTheCampaign() public {
        _toApproved(300e6, 3);

        vm.prank(brandA);
        auction.settle(AID, CID);

        assertTrue(_status() == PeelbidAuction.Status.Settled);

        (address o, address s, uint256 total,,,,, uint16 fee, PeelbidEscrow.CampaignStatus st) =
            escrow.campaigns(CID);
        assertEq(o, carOwner);
        assertEq(s, brandA);                     // the brand, not the auction
        assertEq(total, 300e6);
        assertEq(fee, FEE);
        assertTrue(st == PeelbidEscrow.CampaignStatus.Funded);

        assertEq(usdc.balanceOf(address(escrow)), 300e6);
    }

    function test_SettlementLeavesTheAuctionHoldingNothing() public {
        _toApproved(300e6, 3);

        vm.prank(brandA);
        auction.settle(AID, CID);

        assertEq(usdc.balanceOf(address(auction)), 0);
        assertEq(auction.totalHeld(), 0);
    }

    function test_SettleOnlyPullsTheBalanceNotTheWholeBid() public {
        _toApproved(300e6, 3);
        uint256 before = usdc.balanceOf(brandA);   // 30 already locked

        vm.prank(brandA);
        auction.settle(AID, CID);

        assertEq(usdc.balanceOf(brandA), before - 270e6);
    }

    function test_SettleUsesTheFixedSchedule() public {
        _toApproved(300e6, 3);
        vm.prank(brandA);
        auction.settle(AID, CID);

        assertEq(escrow.trancheCount(CID), 4);
        assertEq(escrow.tranche(CID, 0).percentBps, 2500);
        assertEq(escrow.tranche(CID, 1).percentBps, 2750);
        assertEq(escrow.tranche(CID, 2).percentBps, 2750);
        assertEq(escrow.tranche(CID, 3).percentBps, 2000);
        assertEq(escrow.tranche(CID, 3).offsetDays, 90);
    }

    function test_OnlyTheApprovedBidderCanSettle() public {
        _toApproved(300e6, 3);
        vm.prank(brandB);
        vm.expectRevert(PeelbidAuction.NotLeader.selector);
        auction.settle(AID, CID);
    }

    function test_SettleRevertsAfterThePaymentWindow() public {
        _toApproved(300e6, 3);
        skip(48 hours + 1);
        vm.prank(brandA);
        vm.expectRevert(PeelbidAuction.BadState.selector);
        auction.settle(AID, CID);
    }

    function test_MissedPaymentGivesTheDepositToTheOwner() public {
        _toApproved(300e6, 3);
        skip(48 hours + 1);

        auction.paymentMissed(AID);              // permissionless

        assertTrue(_status() == PeelbidAuction.Status.Cancelled);
        assertEq(auction.refunds(carOwner), 30e6);
        assertEq(auction.refunds(brandA), 0);
        assertEq(auction.totalHeld(), 0);

        vm.prank(carOwner);
        auction.withdrawRefund();
        assertEq(usdc.balanceOf(carOwner), 30e6);
    }

    function test_PaymentMissedRevertsWhileTheWindowIsOpen() public {
        _toApproved(300e6, 3);
        vm.expectRevert(PeelbidAuction.TooEarly.selector);
        auction.paymentMissed(AID);
    }

    // ================================================================
    // Schedules
    // ================================================================

    function test_EverySchedulePaysExactlyOneHundredPercent() public view {
        uint8[4] memory runs = [1, 3, 6, 12];
        for (uint256 i; i < 4; ++i) {
            (uint16[] memory pct, uint32[] memory off) = auction.schedule(runs[i]);
            uint256 sum;
            for (uint256 j; j < pct.length; ++j) {
                sum += pct[j];
                if (j > 0) assertGt(off[j], off[j - 1]);
            }
            assertEq(sum, 10_000);
        }
    }

    function test_OneMonthSplitsFortySixty() public view {
        (uint16[] memory pct,) = auction.schedule(1);
        assertEq(pct.length, 2);
        assertEq(pct[0], 4_000);
        assertEq(pct[1], 6_000);
    }

    function test_TwelveMonthsHasThirteenTranches() public view {
        (uint16[] memory pct, uint32[] memory off) = auction.schedule(12);
        assertEq(pct.length, 13);
        assertEq(pct[0], 2_500);
        assertEq(pct[6], 500);
        assertEq(pct[12], 2_000);
        assertEq(off[12], 360);
    }

    // ================================================================
    // Caps and pausing
    // ================================================================

    function test_TotalHeldIsCapped() public {
        // Each auction holds one 50 USDC deposit; 100 of them would be 5,000.
        for (uint256 i; i < 100; ++i) {
            bytes32 id = keccak256(abi.encode("bulk", i));
            vm.prank(carOwner);
            auction.openAuction(id, FLOOR, RUNS_AT_100, 3 days, FEE);
            vm.prank(brandA);
            auction.placeBid(id, 500e6, 3, ART);
        }
        assertEq(auction.totalHeld(), 5_000e6);

        bytes32 last = keccak256("one-too-many");
        vm.prank(carOwner);
        auction.openAuction(last, FLOOR, RUNS_AT_100, 3 days, FEE);
        vm.prank(brandB);
        vm.expectRevert(PeelbidAuction.TotalCapExceeded.selector);
        auction.placeBid(last, 500e6, 3, ART);
    }

    function test_PausingStopsBiddingButNotWithdrawals() public {
        _open();
        _bid(brandA, 300e6, 3);
        _bid(brandB, 400e6, 3);                  // brandA now owed 30

        auction.pause();

        vm.prank(brandC);
        vm.expectRevert();
        auction.placeBid(AID, 500e6, 3, ART);

        // Money already owed must still be reachable.
        vm.prank(brandA);
        auction.withdrawRefund();
        assertEq(auction.refunds(brandA), 0);
    }

    function test_StrangerCannotPause() public {
        vm.prank(brandA);
        vm.expectRevert();
        auction.pause();
    }
}
