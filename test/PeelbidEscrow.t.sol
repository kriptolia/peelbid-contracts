// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PeelbidEscrow} from "../src/PeelbidEscrow.sol";
import {MockUSDC} from "./MockUSDC.sol";

contract PeelbidEscrowTest is Test {
    PeelbidEscrow escrow;
    MockUSDC usdc;

    address arbiter  = makeAddr("arbiter");
    address feeSink  = makeAddr("feeSink");
    address carOwner = makeAddr("carOwner");
    address sponsor  = makeAddr("sponsor");
    address stranger = makeAddr("stranger");

    bytes32 constant ID    = keccak256("campaign-1");
    uint256 constant TOTAL = 300e6;
    uint16  constant FEE   = 800;
    bytes32 constant PROOF = keccak256("photo-1");

    // 25% of 300 = 75 gross; 8% fee = 6; owner nets 69
    uint256 constant T0_GROSS = 75e6;
    uint256 constant T0_FEE   = 6e6;
    uint256 constant T0_OWNER = 69e6;

    function setUp() public {
        usdc = new MockUSDC();
        escrow = new PeelbidEscrow(IERC20(address(usdc)), arbiter, feeSink);
        usdc.mint(sponsor, 10_000e6);
        vm.prank(sponsor);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function _schedule() internal pure returns (uint16[] memory pct, uint32[] memory off) {
        pct = new uint16[](4);
        pct[0] = 2500; pct[1] = 2750; pct[2] = 2750; pct[3] = 2000;
        off = new uint32[](4);
        off[0] = 0; off[1] = 30; off[2] = 60; off[3] = 90;
    }

    function _create(bytes32 id, uint256 total) internal {
        (uint16[] memory pct, uint32[] memory off) = _schedule();
        escrow.createCampaign(id, carOwner, sponsor, total, FEE, pct, off);
    }

    function _fund(bytes32 id) internal {
        vm.prank(sponsor);
        escrow.fund(id);
    }

    function _apply(bytes32 id) internal {
        vm.prank(carOwner);
        escrow.submitProof(id, 0, PROOF);
    }

    function _status(bytes32 id) internal view returns (PeelbidEscrow.CampaignStatus s) {
        (,,,,,,,, s) = escrow.campaigns(id);
    }

    // ---------------- creation, funding, proof (from before) ----------------

    function test_CreateCampaign() public {
        _create(ID, TOTAL);
        assertEq(escrow.trancheCount(ID), 4);
        assertEq(escrow.tranche(ID, 3).offsetDays, 90);
    }

    function test_FundMovesMoney() public {
        _create(ID, TOTAL);
        _fund(ID);
        assertEq(usdc.balanceOf(address(escrow)), TOTAL);
        assertEq(escrow.totalEscrowed(), TOTAL);
    }

    function test_ApplicationProofStartsTheClock() public {
        _create(ID, TOTAL); _fund(ID);
        skip(10 days);
        _apply(ID);
        assertEq(escrow.dueAt(ID, 1), uint64(block.timestamp) + 30 days);
    }

    function test_ApplicationRevertsAfterWindow() public {
        _create(ID, TOTAL); _fund(ID);
        skip(15 days);
        vm.prank(carOwner);
        vm.expectRevert(PeelbidEscrow.ApplicationWindowMissed.selector);
        escrow.submitProof(ID, 0, PROOF);
    }

    function test_MonthlyProofRevertsBeforeDue() public {
        _create(ID, TOTAL); _fund(ID); _apply(ID);
        skip(29 days);
        vm.prank(carOwner);
        vm.expectRevert(PeelbidEscrow.TooEarly.selector);
        escrow.submitProof(ID, 1, PROOF);
    }

    // ---------------- release ----------------

    function test_ReleasePaysOwnerAndFee() public {
        _create(ID, TOTAL); _fund(ID); _apply(ID);
        skip(7 days);

        escrow.release(ID, 0);

        assertEq(usdc.balanceOf(carOwner), T0_OWNER);
        assertEq(usdc.balanceOf(feeSink), T0_FEE);
        assertEq(escrow.totalEscrowed(), TOTAL - T0_GROSS);
        assertEq(escrow.outstanding(ID), TOTAL - T0_GROSS);
        assertEq(uint8(escrow.tranche(ID, 0).status), uint8(PeelbidEscrow.TrancheStatus.Released));
    }

    function test_ReleaseRevertsDuringWindow() public {
        _create(ID, TOTAL); _fund(ID); _apply(ID);
        skip(7 days - 1);
        vm.expectRevert(PeelbidEscrow.ChallengeWindowOpen.selector);
        escrow.release(ID, 0);
    }

    function test_AnyoneCanRelease() public {
        _create(ID, TOTAL); _fund(ID); _apply(ID);
        skip(7 days);
        vm.prank(stranger);
        escrow.release(ID, 0);
        assertEq(usdc.balanceOf(carOwner), T0_OWNER);
    }

    function test_ReleaseRevertsTwice() public {
        _create(ID, TOTAL); _fund(ID); _apply(ID);
        skip(7 days);
        escrow.release(ID, 0);
        vm.expectRevert(PeelbidEscrow.BadState.selector);
        escrow.release(ID, 0);
    }

    // ---------------- challenge ----------------

    function test_ChallengeFreezesTranche() public {
        _create(ID, TOTAL); _fund(ID); _apply(ID);
        skip(3 days);

        vm.prank(sponsor);
        escrow.challenge(ID, 0);

        assertEq(uint8(escrow.tranche(ID, 0).status), uint8(PeelbidEscrow.TrancheStatus.Frozen));

        skip(10 days);
        vm.expectRevert(PeelbidEscrow.BadState.selector);
        escrow.release(ID, 0);   // frozen stays frozen until the arbiter acts
    }

    function test_ChallengeRevertsAfterWindow() public {
        _create(ID, TOTAL); _fund(ID); _apply(ID);
        skip(7 days);
        vm.prank(sponsor);
        vm.expectRevert(PeelbidEscrow.ChallengeWindowClosed.selector);
        escrow.challenge(ID, 0);
    }

    function test_ChallengeRevertsForNonSponsor() public {
        _create(ID, TOTAL); _fund(ID); _apply(ID);
        vm.prank(stranger);
        vm.expectRevert(PeelbidEscrow.NotSponsor.selector);
        escrow.challenge(ID, 0);
    }

    function test_ChallengeOnlyFreezesThatTranche() public {
        _create(ID, TOTAL); _fund(ID); _apply(ID);
        skip(7 days);
        escrow.release(ID, 0);

        skip(30 days);
        vm.prank(carOwner);
        escrow.submitProof(ID, 1, keccak256("photo-2"));
        vm.prank(sponsor);
        escrow.challenge(ID, 1);

        // tranche 2 is unaffected: owner can still submit when it's due
        skip(30 days);
        vm.prank(carOwner);
        escrow.submitProof(ID, 2, keccak256("photo-3"));
        skip(7 days);
        escrow.release(ID, 2);
        assertEq(uint8(escrow.tranche(ID, 2).status), uint8(PeelbidEscrow.TrancheStatus.Released));
    }

    // ---------------- resolve ----------------

    function test_ResolveSplitsFiftyFifty() public {
        _create(ID, TOTAL); _fund(ID); _apply(ID);
        vm.prank(sponsor);
        escrow.challenge(ID, 0);

        uint256 sponsorBefore = usdc.balanceOf(sponsor);
        vm.prank(arbiter);
        escrow.resolve(ID, 0, 5000);

        // 75 gross: owner side 37.5, fee 8% of that = 3, owner nets 34.5; sponsor gets 37.5
        assertEq(usdc.balanceOf(carOwner), 34_500_000);
        assertEq(usdc.balanceOf(feeSink), 3_000_000);
        assertEq(usdc.balanceOf(sponsor), sponsorBefore + 37_500_000);
        assertEq(escrow.outstanding(ID), TOTAL - T0_GROSS);
    }

    function test_ResolveFullRefundMarksRefunded() public {
        _create(ID, TOTAL); _fund(ID); _apply(ID);
        vm.prank(sponsor);
        escrow.challenge(ID, 0);
        vm.prank(arbiter);
        escrow.resolve(ID, 0, 0);
        assertEq(uint8(escrow.tranche(ID, 0).status), uint8(PeelbidEscrow.TrancheStatus.Refunded));
        assertEq(usdc.balanceOf(carOwner), 0);
        assertEq(usdc.balanceOf(feeSink), 0);
    }

    function test_ResolveRevertsForNonArbiter() public {
        _create(ID, TOTAL); _fund(ID); _apply(ID);
        vm.prank(sponsor);
        escrow.challenge(ID, 0);
        vm.prank(stranger);
        vm.expectRevert(PeelbidEscrow.NotArbiter.selector);
        escrow.resolve(ID, 0, 5000);
    }

    function test_ResolveRevertsIfNotFrozen() public {
        _create(ID, TOTAL); _fund(ID); _apply(ID);
        vm.prank(arbiter);
        vm.expectRevert(PeelbidEscrow.BadState.selector);
        escrow.resolve(ID, 0, 5000);
    }

    // ---------------- terminate and reclaim ----------------

    function test_TerminateRefundsRemainingOnly() public {
        _create(ID, TOTAL); _fund(ID); _apply(ID);
        skip(7 days);
        escrow.release(ID, 0);   // month 1 served and paid

        uint256 sponsorBefore = usdc.balanceOf(sponsor);
        vm.prank(arbiter);
        escrow.terminate(ID);

        assertEq(usdc.balanceOf(sponsor), sponsorBefore + (TOTAL - T0_GROSS));
        assertEq(usdc.balanceOf(carOwner), T0_OWNER);  // keeps what was earned
        assertEq(escrow.outstanding(ID), 0);
        assertEq(escrow.totalEscrowed(), 0);
        assertEq(uint8(_status(ID)), uint8(PeelbidEscrow.CampaignStatus.Terminated));
    }

    function test_ReclaimUnappliedAfterWindow() public {
        _create(ID, TOTAL); _fund(ID);
        skip(14 days + 1);

        uint256 sponsorBefore = usdc.balanceOf(sponsor);
        vm.prank(sponsor);
        escrow.reclaimUnapplied(ID);

        assertEq(usdc.balanceOf(sponsor), sponsorBefore + TOTAL);
        assertEq(escrow.totalEscrowed(), 0);
        assertEq(uint8(_status(ID)), uint8(PeelbidEscrow.CampaignStatus.Terminated));
    }

    function test_ReclaimRevertsWhileWindowOpen() public {
        _create(ID, TOTAL); _fund(ID);
        skip(13 days);
        vm.prank(sponsor);
        vm.expectRevert(PeelbidEscrow.ApplicationWindowStillOpen.selector);
        escrow.reclaimUnapplied(ID);
    }

    function test_ReclaimRevertsIfApplied() public {
        _create(ID, TOTAL); _fund(ID); _apply(ID);
        skip(15 days);
        vm.prank(sponsor);
        vm.expectRevert(PeelbidEscrow.AlreadyApplied.selector);
        escrow.reclaimUnapplied(ID);
    }

    // ---------------- full lifecycle ----------------

    function test_FullLifecycleCompletes() public {
        _create(ID, TOTAL); _fund(ID); _apply(ID);
        skip(7 days);  escrow.release(ID, 0);

        skip(23 days); vm.prank(carOwner); escrow.submitProof(ID, 1, keccak256("p2"));
        skip(7 days);  escrow.release(ID, 1);

        skip(23 days); vm.prank(carOwner); escrow.submitProof(ID, 2, keccak256("p3"));
        skip(7 days);  escrow.release(ID, 2);

        skip(23 days); vm.prank(carOwner); escrow.submitProof(ID, 3, keccak256("p4"));
        skip(7 days);  escrow.release(ID, 3);

        // 300 total: owner 276, fee 24, nothing left
        assertEq(usdc.balanceOf(carOwner), 276e6);
        assertEq(usdc.balanceOf(feeSink), 24e6);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(escrow.outstanding(ID), 0);
        assertEq(escrow.totalEscrowed(), 0);
        assertEq(uint8(_status(ID)), uint8(PeelbidEscrow.CampaignStatus.Completed));

        // nothing more can be done
        vm.expectRevert(PeelbidEscrow.BadState.selector);
        escrow.release(ID, 3);
    }

    // ---------------- missed checkpoint ----------------

    function test_ReclaimMissedTrancheAfterDeadline() public {
        _create(ID, TOTAL); _fund(ID); _apply(ID);
        skip(7 days); escrow.release(ID, 0);

        // tranche 1 due at day 30; owner goes silent
        skip(23 days + 14 days + 1);

        uint256 sponsorBefore = usdc.balanceOf(sponsor);
        vm.prank(sponsor);
        escrow.reclaimMissedTranche(ID, 1);

        assertEq(usdc.balanceOf(sponsor), sponsorBefore + 82_500_000);
        assertEq(uint8(escrow.tranche(ID, 1).status), uint8(PeelbidEscrow.TrancheStatus.Refunded));
        assertEq(escrow.outstanding(ID), TOTAL - T0_GROSS - 82_500_000);
    }

    function test_ReclaimMissedTrancheRevertsBeforeDeadline() public {
        _create(ID, TOTAL); _fund(ID); _apply(ID);
        skip(30 days + 13 days);
        vm.prank(sponsor);
        vm.expectRevert(PeelbidEscrow.TooEarly.selector);
        escrow.reclaimMissedTranche(ID, 1);
    }

    function test_ReclaimMissedTrancheRevertsIfProofSubmitted() public {
        _create(ID, TOTAL); _fund(ID); _apply(ID);
        skip(30 days);
        vm.prank(carOwner);
        escrow.submitProof(ID, 1, keccak256("p2"));
        skip(20 days);
        vm.prank(sponsor);
        vm.expectRevert(PeelbidEscrow.BadState.selector);
        escrow.reclaimMissedTranche(ID, 1);
    }

    function test_ReclaimMissedTrancheRevertsForIndexZero() public {
        _create(ID, TOTAL); _fund(ID);
        skip(60 days);
        vm.prank(sponsor);
        vm.expectRevert(PeelbidEscrow.BadTrancheIndex.selector);
        escrow.reclaimMissedTranche(ID, 0);
    }

    // ---------------- campaignCreator ----------------

    function test_CreateRevertsForStrangerWithNoCreatorSet() public {
        (uint16[] memory pct, uint32[] memory off) = _schedule();
        vm.prank(stranger);
        vm.expectRevert(PeelbidEscrow.NotCreator.selector);
        escrow.createCampaign(ID, carOwner, sponsor, TOTAL, FEE, pct, off);
    }

    function test_OwnerCanStillCreateWithNoCreatorSet() public {
        assertEq(escrow.campaignCreator(), address(0));
        _create(ID, TOTAL);
        assertEq(escrow.trancheCount(ID), 4);
    }

    function test_AppointedCreatorCanCreate() public {
        address auction = makeAddr("auction");
        escrow.setCampaignCreator(auction);

        (uint16[] memory pct, uint32[] memory off) = _schedule();
        vm.prank(auction);
        escrow.createCampaign(ID, carOwner, sponsor, TOTAL, FEE, pct, off);

        assertEq(escrow.trancheCount(ID), 4);
        (address o,,,,,,,,) = escrow.campaigns(ID);
        assertEq(o, carOwner);
    }

    function test_RevokedCreatorCannotCreate() public {
        address auction = makeAddr("auction");
        escrow.setCampaignCreator(auction);
        escrow.setCampaignCreator(address(0));

        (uint16[] memory pct, uint32[] memory off) = _schedule();
        vm.prank(auction);
        vm.expectRevert(PeelbidEscrow.NotCreator.selector);
        escrow.createCampaign(ID, carOwner, sponsor, TOTAL, FEE, pct, off);
    }

    function test_CreatorCannotDoAnythingElse() public {
        // The role writes campaign terms. It must not touch money or settings.
        address auction = makeAddr("auction");
        escrow.setCampaignCreator(auction);
        _create(ID, TOTAL);
        _fund(ID);
        _apply(ID);
        skip(7 days);

        vm.startPrank(auction);

        vm.expectRevert();
        escrow.pause();

        vm.expectRevert();
        escrow.setArbiter(auction);

        vm.expectRevert();
        escrow.setCampaignCreator(auction);

        vm.expectRevert(PeelbidEscrow.NotArbiter.selector);
        escrow.terminate(ID);

        vm.stopPrank();

        // release() is permissionless by design, so anyone may call it —
        // including the creator. The money still goes to the campaign's owner.
        escrow.release(ID, 0);
        assertEq(usdc.balanceOf(carOwner), T0_OWNER);
    }

    function test_StrangerCannotAppointThemselves() public {
        vm.prank(stranger);
        vm.expectRevert();
        escrow.setCampaignCreator(stranger);
    }
}
