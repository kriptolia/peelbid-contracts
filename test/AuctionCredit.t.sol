// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PeelbidAuction} from "../src/PeelbidAuction.sol";

contract CreditTestUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @notice A re-bid spends the bidder's refund credit before their wallet.
/// @dev Self-contained on purpose: bidding never touches the escrow, so the
///      auction is pointed at a placeholder address and nothing else is set up.
contract AuctionCreditTest is Test {
    CreditTestUSDC usdc;
    PeelbidAuction auction;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address fees  = makeAddr("fees");

    bytes32 constant A   = keccak256("credit-a");
    bytes32 constant B   = keccak256("credit-b");
    bytes32 constant ART = keccak256("artwork");

    function setUp() public {
        usdc = new CreditTestUSDC();
        auction = new PeelbidAuction(address(usdc), address(0xE5C0), fees);

        usdc.mint(alice, 1_000e6);
        usdc.mint(bob, 1_000e6);
        vm.prank(alice); usdc.approve(address(auction), type(uint256).max);
        vm.prank(bob);   usdc.approve(address(auction), type(uint256).max);
    }

    function _open(bytes32 id, uint16 mask) internal {
        vm.prank(owner);
        auction.openAuction(id, 50e6, mask, 1 days, 800);
    }

    function _bid(address who, bytes32 id, uint256 amount, uint8 months) internal {
        vm.prank(who);
        auction.placeBid(id, amount, months, ART);
    }

    /// Every USDC in the contract is either a live deposit or somebody's claim.
    function _accounted() internal view {
        assertEq(
            usdc.balanceOf(address(auction)),
            auction.totalHeld() + auction.refunds(alice) + auction.refunds(bob),
            "balance != held + owed"
        );
    }

    function _deposit(bytes32 id, address who) internal view returns (uint256 d) {
        (,,, d) = auction.bids(id, who);
    }

    // ------------------------------------------------------------------

    function test_RebidSpendsCreditBeforeWallet() public {
        _open(A, 0x1);
        _bid(alice, A, 60e6, 1);                 // locks 10
        _bid(bob, A, 70e6, 1);                   // alice credited 10
        assertEq(auction.refunds(alice), 10e6);

        uint256 before = usdc.balanceOf(alice);
        _bid(alice, A, 80e6, 1);                 // needs 10 again — all from credit

        assertEq(usdc.balanceOf(alice), before, "wallet should be untouched");
        assertEq(auction.refunds(alice), 0);
        assertEq(_deposit(A, alice), 10e6);
        assertEq(auction.totalHeld(), 10e6);
        _accounted();
    }

    function test_CreditCoversPartAndWalletTheRest() public {
        _open(A, 0x3);                           // 1mo and 3mo
        _bid(alice, A, 60e6, 1);
        _bid(bob, A, 70e6, 1);                   // alice credited 10

        uint256 before = usdc.balanceOf(alice);
        _bid(alice, A, 300e6, 3);                // 100/mo, locks 30: 10 credit + 20 wallet

        assertEq(before - usdc.balanceOf(alice), 20e6, "only the shortfall from the wallet");
        assertEq(auction.refunds(alice), 0);
        assertEq(_deposit(A, alice), 30e6);
        _accounted();
    }

    function test_CreditEarnedElsewhereIsSpentHere() public {
        _open(A, 0x1);
        _open(B, 0x1);
        _bid(alice, A, 60e6, 1);
        _bid(bob, A, 70e6, 1);                   // alice's credit comes from auction A

        uint256 before = usdc.balanceOf(alice);
        _bid(alice, B, 60e6, 1);                 // and is spent on auction B

        assertEq(usdc.balanceOf(alice), before);
        assertEq(auction.refunds(alice), 0);
        assertEq(_deposit(B, alice), 10e6);
        _accounted();
    }

    function test_UnspentCreditStaysWithdrawable() public {
        _open(A, 0x3);
        _open(B, 0x1);
        _bid(alice, A, 300e6, 3);                // locks 30
        _bid(bob, A, 330e6, 3);                  // 110/mo beats 105 — alice credited 30
        _bid(alice, B, 60e6, 1);                 // spends 10, leaves 20

        assertEq(auction.refunds(alice), 20e6);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        auction.withdrawRefund();
        assertEq(usdc.balanceOf(alice) - before, 20e6);
        _accounted();
    }

    function test_SpendingCreditIsAnnounced() public {
        _open(A, 0x1);
        _bid(alice, A, 60e6, 1);
        _bid(bob, A, 70e6, 1);

        vm.recordLogs();
        _bid(alice, A, 80e6, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = keccak256("CreditApplied(bytes32,address,uint256)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 3 && logs[i].topics[0] == sig) {
                found = true;
                assertEq(logs[i].topics[1], A);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), alice);
                assertEq(abi.decode(logs[i].data, (uint256)), 10e6);
            }
        }
        assertTrue(found, "CreditApplied not emitted");
    }

    function test_NoCreditMeansWalletAsBefore() public {
        _open(A, 0x1);
        uint256 before = usdc.balanceOf(alice);
        _bid(alice, A, 60e6, 1);
        assertEq(before - usdc.balanceOf(alice), 10e6);
        _accounted();
    }
}
