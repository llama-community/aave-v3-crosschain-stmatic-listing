// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '@forge-std/Test.sol';
import {GovHelpers} from '@aave-helpers/GovHelpers.sol';
import {AaveGovernanceV2, IExecutorWithTimelock} from '@aave-address-book/AaveGovernanceV2.sol';

import {CrosschainForwarderPolygon} from '../contracts/polygon/CrosschainForwarderPolygon.sol';
import {StMaticPayload} from '../contracts/polygon/StMaticPayload.sol';
import {IStateReceiver} from '../interfaces/IFx.sol';
import {IBridgeExecutor} from '../interfaces/IBridgeExecutor.sol';
import {AaveV3Helpers, ReserveConfig, ReserveTokens, IERC20} from './helpers/AaveV3Helpers.sol';

contract PolygonStMaticE2ETest is Test {
  // the identifiers of the forks
  uint256 mainnetFork;
  uint256 polygonFork;

  StMaticPayload public stMaticPayload;

  address public constant CROSSCHAIN_FORWARDER_POLYGON =
    0x158a6bC04F0828318821baE797f50B0A1299d45b;
  address public constant BRIDGE_ADMIN =
    0x0000000000000000000000000000000000001001;
  address public constant FX_CHILD_ADDRESS =
    0x8397259c983751DAf40400790063935a11afa28a;
  address public constant POLYGON_BRIDGE_EXECUTOR =
    0xdc9A35B16DB4e126cFeDC41322b3a36454B1F772;

  address public constant STMATIC = 0x3A58a54C066FdC0f2D55FC9C89F0415C92eBf3C4;
  address public constant STMATIC_WHALE =
    0x65752C54D9102BDFD69d351E1838A1Be83C924C6;

  address public constant DAI = 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063;
  address public constant DAI_WHALE =
    0xd7052EC0Fe1fe25b20B7D65F6f3d490fCE58804f;

  address public constant AAVE_WHALE =
    address(0x25F2226B597E8F9514B3F68F00f494cF4f286491);

  function setUp() public {
    polygonFork = vm.createFork(
      vm.rpcUrl('polygon'),
      vm.envUint('FORK_BLOCK_POLYGON')
    );
    mainnetFork = vm.createFork(
      vm.rpcUrl('mainnet'),
      vm.envUint('FORK_BLOCK_MAINNET')
    );
  }

  function _createProposal(address l2payload) internal returns (uint256) {
    address[] memory targets = new address[](1);
    targets[0] = CROSSCHAIN_FORWARDER_POLYGON;
    uint256[] memory values = new uint256[](1);
    values[0] = 0;
    string[] memory signatures = new string[](1);
    signatures[0] = 'execute(address)';
    bytes[] memory calldatas = new bytes[](1);
    calldatas[0] = abi.encode(l2payload);
    bool[] memory withDelegatecalls = new bool[](1);
    withDelegatecalls[0] = true;
    return
      AaveGovernanceV2.GOV.create(
        IExecutorWithTimelock(AaveGovernanceV2.SHORT_EXECUTOR),
        targets,
        values,
        signatures,
        calldatas,
        withDelegatecalls,
        bytes32(0)
      );
  }

  // utility to transform memory to calldata so array range access is available
  function _cutBytes(bytes calldata input)
    public
    pure
    returns (bytes calldata)
  {
    return input[64:];
  }

  function testProposalE2E() public {
    vm.selectFork(polygonFork);

    // we get all configs to later on check that payload only changes stMATIC
    ReserveConfig[] memory allConfigsBefore = AaveV3Helpers._getReservesConfigs(
      false
    );

    // 1. deploy l2 payload
    vm.selectFork(polygonFork);
    stMaticPayload = new StMaticPayload();

    // 2. create l1 proposal
    vm.selectFork(mainnetFork);
    vm.startPrank(AAVE_WHALE);
    uint256 proposalId = _createProposal(address(stMaticPayload));
    vm.stopPrank();

    // 3. execute proposal and record logs so we can extract the emitted StateSynced event
    vm.recordLogs();
    GovHelpers.passVoteAndExecute(vm, proposalId);

    Vm.Log[] memory entries = vm.getRecordedLogs();
    assertEq(
      keccak256('StateSynced(uint256,address,bytes)'),
      entries[2].topics[0]
    );
    assertEq(address(uint160(uint256(entries[2].topics[2]))), FX_CHILD_ADDRESS);

    // 4. mock the receive on l2 with the data emitted on StateSynced
    vm.selectFork(polygonFork);
    vm.startPrank(BRIDGE_ADMIN);
    IStateReceiver(FX_CHILD_ADDRESS).onStateReceive(
      uint256(entries[2].topics[1]),
      this._cutBytes(entries[2].data)
    );
    vm.stopPrank();

    // 5. execute proposal on l2
    vm.warp(
      block.timestamp + IBridgeExecutor(POLYGON_BRIDGE_EXECUTOR).getDelay() + 1
    );
    // execute the proposal
    IBridgeExecutor(POLYGON_BRIDGE_EXECUTOR).execute(
      IBridgeExecutor(POLYGON_BRIDGE_EXECUTOR).getActionsSetCount() - 1
    );

    // 6. verify results
    ReserveConfig[] memory allConfigsAfter = AaveV3Helpers._getReservesConfigs(
      false
    );

    ReserveConfig memory expectedAssetConfig = ReserveConfig({
      symbol: 'stMATIC',
      underlying: STMATIC,
      aToken: address(0), // Mock, as they don't get validated, because of the "dynamic" deployment on proposal execution
      variableDebtToken: address(0), // Mock, as they don't get validated, because of the "dynamic" deployment on proposal execution
      stableDebtToken: address(0), // Mock, as they don't get validated, because of the "dynamic" deployment on proposal execution
      decimals: 18,
      ltv: 5000,
      liquidationThreshold: 6500,
      liquidationBonus: 11000,
      liquidationProtocolFee: 2000,
      reserveFactor: 2000,
      usageAsCollateralEnabled: true,
      borrowingEnabled: false,
      interestRateStrategy: AaveV3Helpers
        ._findReserveConfig(allConfigsAfter, 'stMATIC', true)
        .interestRateStrategy,
      stableBorrowRateEnabled: false,
      isActive: true,
      isFrozen: false,
      isSiloed: false,
      supplyCap: 7_500_000,
      borrowCap: 0,
      debtCeiling: 0,
      eModeCategory: 2
    });

    AaveV3Helpers._validateReserveConfig(expectedAssetConfig, allConfigsAfter);

    AaveV3Helpers._noReservesConfigsChangesApartNewListings(
      allConfigsBefore,
      allConfigsAfter
    );

    AaveV3Helpers._validateReserveTokensImpls(
      vm,
      AaveV3Helpers._findReserveConfig(allConfigsAfter, 'stMATIC', false),
      ReserveTokens({
        aToken: stMaticPayload.ATOKEN_IMPL(),
        stableDebtToken: stMaticPayload.SDTOKEN_IMPL(),
        variableDebtToken: stMaticPayload.VDTOKEN_IMPL()
      })
    );

    AaveV3Helpers._validateAssetSourceOnOracle(
      STMATIC,
      stMaticPayload.PRICE_FEED()
    );

    // Reserve token implementation contracts should be same as USDC
    AaveV3Helpers._validateReserveTokensImpls(
      vm,
      AaveV3Helpers._findReserveConfig(allConfigsAfter, 'USDC', false),
      ReserveTokens({
        aToken: stMaticPayload.ATOKEN_IMPL(),
        stableDebtToken: stMaticPayload.SDTOKEN_IMPL(),
        variableDebtToken: stMaticPayload.VDTOKEN_IMPL()
      })
    );

    string[] memory expectedAssetsEmode = new string[](2);
    expectedAssetsEmode[0] = 'WMATIC';
    expectedAssetsEmode[1] = 'stMATIC';

    AaveV3Helpers._validateAssetsOnEmodeCategory(
      2,
      allConfigsAfter,
      expectedAssetsEmode
    );

    _validatePoolActionsPostListing(allConfigsAfter);
  }

  function _validatePoolActionsPostListing(
    ReserveConfig[] memory allReservesConfigs
  ) internal {
    address aSTMATIC = AaveV3Helpers
      ._findReserveConfig(allReservesConfigs, 'stMATIC', false)
      .aToken;
    address vSTMATIC = AaveV3Helpers
      ._findReserveConfig(allReservesConfigs, 'stMATIC', false)
      .variableDebtToken;
    address sSTMATIC = AaveV3Helpers
      ._findReserveConfig(allReservesConfigs, 'stMATIC', false)
      .stableDebtToken;
    address vDAI = AaveV3Helpers
      ._findReserveConfig(allReservesConfigs, 'DAI', false)
      .variableDebtToken;

    // Deposit stMATIC from stMATIC Whale and receive aSTMATIC
    AaveV3Helpers._deposit(
      vm,
      STMATIC_WHALE,
      STMATIC_WHALE,
      STMATIC,
      666 ether,
      true,
      aSTMATIC
    );

    // Testing borrowing of DAI against stMATIC as collateral
    AaveV3Helpers._borrow(
      vm,
      STMATIC_WHALE,
      STMATIC_WHALE,
      DAI,
      2 ether,
      2,
      vDAI
    );

    // Expecting to Revert with error code '30' ('BORROWING_NOT_ENABLED') for stable rate borrowing
    // https://github.com/aave/aave-v3-core/blob/master/contracts/protocol/libraries/helpers/Errors.sol#L39
    vm.expectRevert(bytes('30'));
    AaveV3Helpers._borrow(
      vm,
      STMATIC_WHALE,
      STMATIC_WHALE,
      STMATIC,
      10 ether,
      1,
      sSTMATIC
    );
    vm.stopPrank();

    // Expecting to Revert with error code '30' ('BORROWING_NOT_ENABLED') for variable rate borrowing
    // https://github.com/aave/aave-v3-core/blob/master/contracts/protocol/libraries/helpers/Errors.sol#L39
    vm.expectRevert(bytes('30'));
    AaveV3Helpers._borrow(
      vm,
      STMATIC_WHALE,
      STMATIC_WHALE,
      STMATIC,
      10 ether,
      2,
      vSTMATIC
    );
    vm.stopPrank();

    // Transferring some extra DAI to stMATIC whale for repaying back the loan.
    vm.startPrank(DAI_WHALE);
    IERC20(DAI).transfer(STMATIC_WHALE, 300 ether);
    vm.stopPrank();

    // Not possible to borrow and repay when vdebt index doesn't changing, so moving ahead 10000s
    skip(10000);

    // Repaying back DAI loan
    AaveV3Helpers._repay(
      vm,
      STMATIC_WHALE,
      STMATIC_WHALE,
      DAI,
      IERC20(DAI).balanceOf(STMATIC_WHALE),
      2,
      vDAI,
      true
    );

    // Withdrawing stMATIC
    AaveV3Helpers._withdraw(
      vm,
      STMATIC_WHALE,
      STMATIC_WHALE,
      STMATIC,
      type(uint256).max,
      aSTMATIC
    );
  }
}
