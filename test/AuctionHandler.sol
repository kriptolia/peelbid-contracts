// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {PeelbidAuction} from "../src/PeelbidAuction.sol";
import {MockUSDC} from "./MockUSDC.sol";

/**
 * @notice Drives the auction in whatever order the fuzzer likes.
 *
 * Every call is wrapped in try/catch: most random sequences are invalid and
 * should revert. What matters isn't that a call succeeds, it's that the
 * accounting still adds up after whichever ones do.
 */
contract AuctionHandler is Test {
    PeelbidAuction public auction;
    MockUSDC public usdc;

    address[4] public bidders;
    address public carOwner = makeAddr("handlerOwner");

    bytes32[] public ids;
    mapping(bytes32 => bool) seen;

    constructor(PeelbidAuction a, MockUSDC u) {
        auction = a;
        usdc = u;

        for (uint256 i; i < 4; ++i) {
            bidders[i] = makeAddr(string(abi.encodePacked("bidder", i)));
            usdc.mint(bidders[i], 1_000_000e6);
            vm.prank(bidders[i]);
            usdc.approve(address(auction), type(uint256).max);
        }
    }

    function idCount() external view returns (uint256) { return ids.length; }

    function _pick(uint256 seed) internal view returns (bytes32) {
        if (ids.length == 0) return bytes32(0);
        return ids[seed % ids.length];
    }

    function _bidder(uint256 seed) internal view returns (address) {
        return bidders[seed % 4];
    }

    // ---------------- actions ----------------

    function open(uint256 seed, uint256 floorSeed) external {
        bytes32 id = keccak256(abi.encode("auction", seed, ids.length));
        if (seen[id]) return;

        // A floor of 50 leaves room for 1, 3 and 6 month runs under the cap.
        uint256 floorRate = bound(floorSeed, 50e6, 80e6);

        vm.prank(carOwner);
        try auction.openAuction(id, floorRate, 0x07, 3 days, 800) {
            ids.push(id);
            seen[id] = true;
        } catch {}
    }

    function bid(uint256 seed, uint256 who, uint256 amountSeed, uint256 monthSeed) external {
        bytes32 id = _pick(seed);
        if (id == bytes32(0)) return;

        uint8[3] memory runs = [1, 3, 6];
        uint8 months = runs[monthSeed % 3];
        uint256 amount = bound(amountSeed, 50e6, 500e6);

        vm.prank(_bidder(who));
        try auction.placeBid(id, amount, months, keccak256("art")) {} catch {}
    }

    function end(uint256 seed) external {
        bytes32 id = _pick(seed);
        if (id == bytes32(0)) return;
        try auction.endAuction(id) {} catch {}
    }

    function approve(uint256 seed) external {
        bytes32 id = _pick(seed);
        if (id == bytes32(0)) return;
        vm.prank(carOwner);
        try auction.approveLeader(id) {} catch {}
    }

    function decline(uint256 seed) external {
        bytes32 id = _pick(seed);
        if (id == bytes32(0)) return;
        vm.prank(carOwner);
        try auction.declineLeader(id) {} catch {}
    }

    function expire(uint256 seed) external {
        bytes32 id = _pick(seed);
        if (id == bytes32(0)) return;
        try auction.expire(id) {} catch {}
    }

    function missPayment(uint256 seed) external {
        bytes32 id = _pick(seed);
        if (id == bytes32(0)) return;
        try auction.paymentMissed(id) {} catch {}
    }

    function cancel(uint256 seed) external {
        bytes32 id = _pick(seed);
        if (id == bytes32(0)) return;
        vm.prank(carOwner);
        try auction.cancelAuction(id) {} catch {}
    }

    function withdraw(uint256 who) external {
        address w = _bidder(who);
        vm.prank(w);
        try auction.withdrawRefund() {} catch {}
    }

    function withdrawOwner() external {
        vm.prank(carOwner);
        try auction.withdrawRefund() {} catch {}
    }

    function warp(uint256 seed) external {
        skip(bound(seed, 1 hours, 9 days));
    }

    // ---------------- sums the invariants need ----------------

    function sumDeposits() external view returns (uint256 sum) {
        for (uint256 i; i < ids.length; ++i) {
            for (uint256 j; j < 4; ++j) {
                (,,, uint256 dep) = auction.bids(ids[i], bidders[j]);
                sum += dep;
            }
        }
    }

    function sumRefunds() external view returns (uint256 sum) {
        for (uint256 j; j < 4; ++j) sum += auction.refunds(bidders[j]);
        sum += auction.refunds(carOwner);
    }
}
