// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console} from "forge-std/Script.sol";
import {PeelbidAuction} from "../src/PeelbidAuction.sol";

/**
 * @notice Deploys PeelbidAuction and points it at an existing escrow.
 *
 * Deploying is only half the job. The auction cannot create campaigns until
 * the escrow's owner appoints it as `campaignCreator`, and that call comes
 * from the Safe, not from here. The script prints what to run.
 */
contract DeployAuction is Script {
    function run() external {
        address token   = vm.envAddress("USDC_ADDRESS");
        address escrow  = vm.envAddress("ESCROW_ADDRESS");
        address feeTo   = vm.envAddress("FEE_RECIPIENT_ADDRESS");
        uint256 pk      = vm.envUint("DEPLOYER_PRIVATE_KEY");

        console.log("Deploying PeelbidAuction");
        console.log("  USDC:          ", token);
        console.log("  Escrow:        ", escrow);
        console.log("  Fee recipient: ", feeTo);

        vm.startBroadcast(pk);
        PeelbidAuction auction = new PeelbidAuction(token, escrow, feeTo);
        vm.stopBroadcast();

        console.log("PeelbidAuction:  ", address(auction));
        console.log("  MIN_FLOOR_RATE:", auction.MIN_FLOOR_RATE());
        console.log("  MAX_BID:       ", auction.MAX_BID());
        console.log("  MAX_TOTAL_HELD:", auction.MAX_TOTAL_HELD());
        console.log("");
        console.log("Not usable yet. From the escrow's owner:");
        console.log("  setCampaignCreator(%s)", address(auction));
    }
}
