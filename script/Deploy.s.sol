// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PeelbidEscrow} from "../src/PeelbidEscrow.sol";

/// @notice Deploys PeelbidEscrow. Every input comes from .env — nothing hardcoded.
contract Deploy is Script {
    function run() external {
        address usdc         = vm.envAddress("USDC_ADDRESS");
        address arbiter      = vm.envAddress("ARBITER_ADDRESS");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT_ADDRESS");
        uint256 deployerKey  = vm.envUint("DEPLOYER_PRIVATE_KEY");

        console.log("Deploying PeelbidEscrow");
        console.log("  USDC:          ", usdc);
        console.log("  Arbiter:       ", arbiter);
        console.log("  Fee recipient: ", feeRecipient);

        vm.startBroadcast(deployerKey);
        PeelbidEscrow escrow = new PeelbidEscrow(IERC20(usdc), arbiter, feeRecipient);
        vm.stopBroadcast();

        console.log("PeelbidEscrow:   ", address(escrow));
        console.log("MAX_CAMPAIGN:    ", escrow.MAX_CAMPAIGN());
        console.log("MAX_TOTAL:       ", escrow.MAX_TOTAL());
    }
}