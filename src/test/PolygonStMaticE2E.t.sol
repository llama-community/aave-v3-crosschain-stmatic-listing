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

  // TO DO: Do we need DAI for borrowing
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
      ltv: 7500,
      liquidationThreshold: 8000,
      liquidationBonus: 10500,
      liquidationProtocolFee: 1000,
      reserveFactor: 1000,
      usageAsCollateralEnabled: true,
      borrowingEnabled: true,
      interestRateStrategy: AaveV3Helpers
        ._findReserveConfig(allConfigsAfter, 'USDT', false)
        .interestRateStrategy,
      stableBorrowRateEnabled: false,
      isActive: true,
      isFrozen: false,
      isSiloed: false,
      supplyCap: 100_000_000,
      borrowCap: 0,
      debtCeiling: 2_000_000_00,
      eModeCategory: 1
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

    // impl should be same as USDC
    AaveV3Helpers._validateReserveTokensImpls(
      vm,
      AaveV3Helpers._findReserveConfig(allConfigsAfter, 'USDC', false),
      ReserveTokens({
        aToken: stMaticPayload.ATOKEN_IMPL(),
        stableDebtToken: stMaticPayload.SDTOKEN_IMPL(),
        variableDebtToken: stMaticPayload.VDTOKEN_IMPL()
      })
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
    address aDAI = AaveV3Helpers
      ._findReserveConfig(allReservesConfigs, 'DAI', false)
      .aToken;

    AaveV3Helpers._deposit(
      vm,
      STMATIC_WHALE,
      STMATIC_WHALE,
      STMATIC,
      666 ether,
      true,
      aSTMATIC
    );

    // We check revert when trying to borrow at stable
    try
      AaveV3Helpers._borrow(
        vm,
        STMATIC_WHALE,
        STMATIC_WHALE,
        STMATIC,
        10 ether,
        1,
        sSTMATIC
      )
    {
      revert('_testProposal() : BORROW_NOT_REVERTING');
    } catch Error(string memory revertReason) {
      require(
        keccak256(bytes(revertReason)) == keccak256(bytes('31')),
        '_testProposal() : INVALID_STABLE_REVERT_MSG'
      );
      vm.stopPrank();
    }

    vm.startPrank(DAI_WHALE);
    IERC20(DAI).transfer(STMATIC_WHALE, 666 ether);
    vm.stopPrank();

    AaveV3Helpers._deposit(
      vm,
      STMATIC_WHALE,
      STMATIC_WHALE,
      DAI,
      666 ether,
      true,
      aDAI
    );

    AaveV3Helpers._borrow(
      vm,
      STMATIC_WHALE,
      STMATIC_WHALE,
      STMATIC,
      222 ether,
      2,
      vSTMATIC
    );

    // Not possible to borrow and repay when vdebt index doesn't changing, so moving 1s
    skip(1);

    AaveV3Helpers._repay(
      vm,
      STMATIC_WHALE,
      STMATIC_WHALE,
      STMATIC,
      IERC20(STMATIC).balanceOf(STMATIC_WHALE),
      2,
      vSTMATIC,
      true
    );

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