// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PeelbidAuction} from "../src/PeelbidAuction.sol";
import {PeelbidEscrow} from "../src/PeelbidEscrow.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {AuctionHandler} from "./AuctionHandler.sol";

/**
 * @notice Four things that must hold after any sequence of auction calls.
 *
 * The scenario tests check that each path does what it should. These check
 * that no combination of paths, in any order, loses money or invents it.
 */
contract AuctionInvariants is Test {
    PeelbidAuction auction;
    PeelbidEscrow escrow;
    MockUSDC usdc;
    AuctionHandler h;

    function setUp() public {
        usdc = new MockUSDC();
        escrow = new PeelbidEscrow(
            IERC20(address(usdc)), makeAddr("arbiter"), makeAddr("feeSink")
        );
        auction = new PeelbidAuction(
            address(usdc), address(escrow), makeAddr("feeSink")
        );
        escrow.setCampaignCreator(address(auction));

        h = new AuctionHandler(auction, usdc);
        targetContract(address(h));
    }

    /// Every USDC in the contract is either a live deposit or owed to somebody.
    function invariant_balanceIsAccountedFor() public view {
        assertEq(
            usdc.balanceOf(address(auction)),
            h.sumDeposits() + h.sumRefunds()
        );
    }

    /// The running total matches what the bids actually hold.
    function invariant_totalHeldMatchesDeposits() public view {
        assertEq(auction.totalHeld(), h.sumDeposits());
    }

    /// The cap is a cap.
    function invariant_totalHeldUnderCap() public view {
        assertLe(auction.totalHeld(), auction.MAX_TOTAL_HELD());
    }

    /// Nothing can be owed to somebody the contract can't pay.
    function invariant_canAlwaysPayWhatItOwes() public view {
        assertGe(usdc.balanceOf(address(auction)), h.sumRefunds());
    }
}
