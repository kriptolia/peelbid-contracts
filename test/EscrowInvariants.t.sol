// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EscrowHandler} from "./EscrowHandler.sol";
import {PeelbidEscrow} from "../src/PeelbidEscrow.sol";

contract EscrowInvariants is Test {
    EscrowHandler h;
    PeelbidEscrow escrow;

    function setUp() public {
        h = new EscrowHandler();
        escrow = h.escrow();
        targetContract(address(h));
    }

    /// No campaign ever pays out or refunds more than was put in.
    function invariant_noCampaignOverpays() public view {
        uint256 n = h.idCount();
        for (uint256 i; i < n; ++i) {
            bytes32 id = h.ids(i);
            (,, uint256 total, uint256 paidOut, uint256 refunded,,,,) = escrow.campaigns(id);
            assertLe(paidOut + refunded, total, "campaign overpaid");
        }
    }

    /// The contract always physically holds at least what it says it holds.
    function invariant_balanceCoversEscrowed() public view {
        assertGe(h.usdc().balanceOf(address(escrow)), escrow.totalEscrowed(), "balance below escrowed");
    }

    /// The global counter equals the sum of every campaign's unpaid remainder.
    function invariant_escrowedEqualsSumOutstanding() public view {
        uint256 n = h.idCount();
        uint256 sum;
        for (uint256 i; i < n; ++i) sum += escrow.outstanding(h.ids(i));
        assertEq(sum, escrow.totalEscrowed(), "escrowed != sum outstanding");
    }

    /// Total money in the system is conserved: what left must equal what the escrow no longer holds.
    function invariant_moneyIsConserved() public view {
        uint256 n = h.idCount();
        uint256 funded;
        uint256 paid;
        uint256 refunded;
        for (uint256 i; i < n; ++i) {
            (,, uint256 t, uint256 p, uint256 r,,,,) = escrow.campaigns(h.ids(i));
            funded += t; paid += p; refunded += r;
        }
        assertEq(funded - paid - refunded, escrow.totalEscrowed(), "money not conserved");
    }
}