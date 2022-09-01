// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AaveV3Polygon} from '@aave-address-book/AaveV3Polygon.sol';
import {IPoolConfigurator, ConfiguratorInputTypes} from '@aave-address-book/AaveV3.sol';
import {IERC20Metadata} from '@solidity-utils/contracts/oz-common/interfaces/IERC20Metadata.sol';
import {IProposalGenericExecutor} from '../../interfaces/IProposalGenericExecutor.sol';

/**
 * @author Llama
 * @dev This payload lists stMATIC (stMATIC) as borrowing asset on Aave V3 Polygon
 * - Parameter snapshot: https://snapshot.org/#/aave.eth/proposal/0xc8646abba01becf81ad32bf4adf48f723a31483dc4dedc773bbb6e3954c3990f
 */
contract StMaticPayload is IProposalGenericExecutor {
  // **************************
  // Protocol's contracts
  // **************************
  address public constant INCENTIVES_CONTROLLER =
    0x929EC64c34a17401F460460D4B9390518E5B473e;

  // **************************
  // New asset being listed (stMATIC)
  // **************************

  address public constant UNDERLYING =
    0x3A58a54C066FdC0f2D55FC9C89F0415C92eBf3C4;
  string public constant ATOKEN_NAME = 'Aave Polygon STMATIC';
  string public constant ATOKEN_SYMBOL = 'aPolSTMATIC';
  string public constant VDTOKEN_NAME = 'Aave Polygon Variable Debt STMATIC';
  string public constant VDTOKEN_SYMBOL = 'variableDebtPolSTMATIC';
  string public constant SDTOKEN_NAME = 'Aave Polygon Stable Debt STMATIC';
  string public constant SDTOKEN_SYMBOL = 'stableDebtPolSTMATIC';

  address public constant PRICE_FEED =
    0x97371dF4492605486e23Da797fA68e55Fc38a13f;

  // AAVE v3 Reserve Token implementation contracts
  address public constant ATOKEN_IMPL =
    0xa5ba6E5EC19a1Bf23C857991c857dB62b2Aa187B;
  address public constant VDTOKEN_IMPL =
    0x81387c40EB75acB02757C1Ae55D5936E78c9dEd3;
  address public constant SDTOKEN_IMPL =
    0x52A1CeB68Ee6b7B5D13E0376A1E0E4423A8cE26e;

  // Rate Strategy contract
  address public constant RATE_STRATEGY =
    0x03733F4E008d36f2e37F0080fF1c8DF756622E6F;

  // Params to set reserve as collateral
  uint256 public constant COL_LTV = 5000; // 50%
  uint256 public constant COL_LIQ_THRESHOLD = 6500; // 65%
  uint256 public constant COL_LIQ_BONUS = 11000; // 10%

  // Reserve Factor
  uint256 public constant RESERVE_FACTOR = 2000; // 20%
  // Supply Cap
  uint256 public constant SUPPLY_CAP = 7_500_000; // 7.5m stMATIC
  // Liquidation Protocol Fee
  uint256 public constant LIQ_PROTOCOL_FEE = 2000; // 20%

  // Params to set eMode category
  uint8 public constant EMODE_CATEGORY = 2;
  uint16 public constant EMODE_LTV = 9250; // 92.5%
  uint16 public constant EMODE_LIQ_THRESHOLD = 9500; // 95%
  uint16 public constant EMODE_LIQ_BONUS = 10100; // 1%
  string public constant EMODE_LABEL = 'stMATIC';

  function execute() external override {
    // -------------
    // Claim pool admin
    // Only needed for the first proposal on any market. If ACL_ADMIN was previously set it will ignore
    // https://github.com/aave/aave-v3-core/blob/master/contracts/dependencies/openzeppelin/contracts/AccessControl.sol#L207
    // -------------
    AaveV3Polygon.ACL_MANAGER.addPoolAdmin(AaveV3Polygon.ACL_ADMIN);

    // ----------------------------
    // 1. New price feed on oracle
    // ----------------------------
    address[] memory assets = new address[](1);
    assets[0] = UNDERLYING;
    address[] memory sources = new address[](1);
    sources[0] = PRICE_FEED;

    AaveV3Polygon.ORACLE.setAssetSources(assets, sources);

    // ------------------------------------------------
    // 2. Listing of stMATIC, with all its configurations
    // ------------------------------------------------

    ConfiguratorInputTypes.InitReserveInput[]
      memory initReserveInputs = new ConfiguratorInputTypes.InitReserveInput[](
        1
      );
    initReserveInputs[0] = ConfiguratorInputTypes.InitReserveInput({
      aTokenImpl: ATOKEN_IMPL,
      stableDebtTokenImpl: SDTOKEN_IMPL,
      variableDebtTokenImpl: VDTOKEN_IMPL,
      underlyingAssetDecimals: IERC20Metadata(UNDERLYING).decimals(),
      interestRateStrategyAddress: RATE_STRATEGY,
      underlyingAsset: UNDERLYING,
      treasury: AaveV3Polygon.COLLECTOR,
      incentivesController: INCENTIVES_CONTROLLER,
      aTokenName: ATOKEN_NAME,
      aTokenSymbol: ATOKEN_SYMBOL,
      variableDebtTokenName: VDTOKEN_NAME,
      variableDebtTokenSymbol: VDTOKEN_SYMBOL,
      stableDebtTokenName: SDTOKEN_NAME,
      stableDebtTokenSymbol: SDTOKEN_SYMBOL,
      params: bytes('')
    });

    IPoolConfigurator configurator = AaveV3Polygon.POOL_CONFIGURATOR;

    configurator.initReserves(initReserveInputs);

    // Enable Reserve as Collateral with parameters
    configurator.configureReserveAsCollateral(
      UNDERLYING,
      COL_LTV,
      COL_LIQ_THRESHOLD,
      COL_LIQ_BONUS
    );

    // Set Reserve Factor
    configurator.setReserveFactor(UNDERLYING, RESERVE_FACTOR);

    // Set Supply Cap for Isolation Mode
    configurator.setSupplyCap(UNDERLYING, SUPPLY_CAP);

    // Set Liquidation Protocol Fee
    configurator.setLiquidationProtocolFee(UNDERLYING, LIQ_PROTOCOL_FEE);

    // Create new EMode Category
    configurator.setEModeCategory(
      EMODE_CATEGORY,
      EMODE_LTV,
      EMODE_LIQ_THRESHOLD,
      EMODE_LIQ_BONUS,
      PRICE_FEED,
      EMODE_LABEL
    );

    // Set the Asset EMode Category
    configurator.setAssetEModeCategory(UNDERLYING, EMODE_CATEGORY);
  }
}
