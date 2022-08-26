// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '@forge-std/console.sol';
import {Script} from '@forge-std/Script.sol';
import {StMaticPayload} from '../src/contracts/polygon/StMaticPayload.sol';

contract DeployPolygonMiMatic is Script {
  function run() external {
    vm.startBroadcast();
    StMaticPayload stMaticPayload = new StMaticPayload();
    console.log('stMATIC Payload address', address(stMaticPayload));
    vm.stopBroadcast();
  }
}
