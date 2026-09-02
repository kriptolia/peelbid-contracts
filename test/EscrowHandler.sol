// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PeelbidEscrow} from "../src/PeelbidEscrow.sol";
import {MockUSDC} from "./MockUSDC.sol";

/// @notice Drives the escrow with random but bounded actions. The invariant
///         test only looks at the state afterwards.
contract EscrowHandler is Test {
    PeelbidEscrow public escrow;
    MockUSDC public usdc;

    address public arbiter  = makeAddr("arbiter");
    address public feeSink  = makeAddr("feeSink");
    address public sponsor  = makeAddr("sponsor");
    address public carOwner = makeAddr("carOwner");

    bytes32[] public ids;
    uint256 internal nonce;

    constructor() {
        usdc = new MockUSDC();
        escrow = new PeelbidEscrow(IERC20(address(usdc)), arbiter, feeSink);
        usdc.mint(sponsor, 100_000_000e6);
        vm.prank(sponsor);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function idCount() external view returns (uint256) { return ids.length; }

    function _pick(uint256 seed) internal view returns (bytes32) {
        return ids[seed % ids.length];
    }

    // ---------------- actions ----------------

    function createAndFund(uint256 totalSeed) external {
        uint256 total = bound(totalSeed, 1e6, 500e6);
        bytes32 id = keccak256(abi.encode("c", nonce++));

        uint16[] memory pct = new uint16[](4);
        pct[0] = 2500; pct[1] = 2750; pct[2] = 2750; pct[3] = 2000;
        uint32[] memory off = new uint32[](4);
        off[0] = 0; off[1] = 30; off[2] = 60; off[3] = 90;

        try escrow.createCampaign(id, carOwner, sponsor, total, 800, pct, off) {} catch { return; }

        vm.prank(sponsor);
        try escrow.fund(id) { ids.push(id); } catch {}
    }

    function submitProof(uint256 seed, uint256 idx) external {
        if (ids.length == 0) return;
        bytes32 id = _pick(seed);
        idx = idx % 4;
        vm.prank(carOwner);
        try escrow.submitProof(id, idx, keccak256(abi.encode(id, idx, nonce++))) {} catch {}
    }

    function release(uint256 seed, uint256 idx) external {
        if (ids.length == 0) return;
        try escrow.release(_pick(seed), idx % 4) {} catch {}
    }

    function challenge(uint256 seed, uint256 idx) external {
        if (ids.length == 0) return;
        vm.prank(sponsor);
        try escrow.challenge(_pick(seed), idx % 4) {} catch {}
    }

    function resolve(uint256 seed, uint256 idx, uint256 shareSeed) external {
        if (ids.length == 0) return;
        uint16 share = uint16(bound(shareSeed, 0, 10_000));
        vm.prank(arbiter);
        try escrow.resolve(_pick(seed), idx % 4, share) {} catch {}
    }

    function terminate(uint256 seed) external {
        if (ids.length == 0) return;
        vm.prank(arbiter);
        try escrow.terminate(_pick(seed)) {} catch {}
    }

    function reclaim(uint256 seed) external {
        if (ids.length == 0) return;
        vm.prank(sponsor);
        try escrow.reclaimUnapplied(_pick(seed)) {} catch {}
    }

    function warp(uint256 secs) external {
        skip(bound(secs, 1 hours, 40 days));
    }
}