// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Imdex5} from "../src/Imdex5.sol";
import {IPoolManager} from "../src/Interfaces.sol";
import {Imdex5Base} from "./Imdex5Base.sol";
import {MockERC20, MockPoolManager} from "./mocks/Mocks.sol";

/// Independent ledger for claims, including IMD, across empty and refilled epochs.
/// Failure modes here return false BEFORE moving funds, revert, or exhaust their
/// stipend. A transfer that mutates balances then returns false is a separately
/// reported defect; its failing proof must not be converted into a passing test.
contract Imdex5ClaimsHandler is Test {
    Imdex5 public index;
    MockPoolManager public pm;
    address[3] public actors;
    address[] public assets;
    address[] private hooks;
    mapping(address => uint256) public shareLedger;
    mapping(address => mapping(address => uint256)) public debtLedger;
    uint256 public minted;
    uint256 public burned;
    uint256 public successfulMints;
    uint256 public failedMints;
    uint256 public redemptions;
    uint256 public successfulClaims;
    uint256 public failedClaims;

    constructor(Imdex5 target, address[3] memory participants) {
        index = target;
        pm = MockPoolManager(target.POOL_MANAGER());
        actors = participants;
        Imdex5.Coin[] memory coins = target.coins();
        for (uint256 i; i < coins.length; ++i) {
            assets.push(coins[i].token);
            hooks.push(coins[i].hook);
        }
        assets.push(target.IMD());
        minted = target.totalSupply();
        for (uint256 i; i < actors.length; ++i) {
            shareLedger[actors[i]] = target.balanceOf(actors[i]);
        }
    }

    function _key(uint256 i) private view returns (IPoolManager.PoolKey memory) {
        address imd = index.IMD();
        (address a, address b) = assets[i] < imd ? (assets[i], imd) : (imd, assets[i]);
        return IPoolManager.PoolKey(a, b, 12_500, 60, hooks[i]);
    }

    function _backing(uint256 i) private view returns (uint256) {
        return i == assets.length - 1 ? index.idleImd() : index.held(assets[i]);
    }

    function _digest() private view returns (bytes32 digest) {
        digest = keccak256(abi.encode(index.totalSupply(), index.feeImd(), index.idleImd()));
        for (uint256 i; i < assets.length; ++i) {
            MockERC20 coin = MockERC20(assets[i]);
            digest =
                keccak256(abi.encode(digest, _backing(i), coin.balanceOf(address(index)), coin.balanceOf(address(pm))));
            if (i < hooks.length) {
                (uint256 r0, uint256 r1,,,,) = pm.pools(pm.poolId(_key(i)));
                digest = keccak256(abi.encode(digest, r0, r1));
            }
            for (uint256 j; j < actors.length; ++j) {
                address who = actors[j];
                digest = keccak256(
                    abi.encode(
                        digest,
                        index.balanceOf(who),
                        coin.balanceOf(who),
                        coin.allowance(who, address(index)),
                        index.owed(who, assets[i])
                    )
                );
            }
        }
    }

    function mint(uint256 whoSeed, uint256 sizeSeed, uint256 floorSeed, bool insufficientBudget) external {
        address who = actors[whoSeed % 3];
        uint256 supply = index.totalSupply();
        uint256 requested = bound(sizeSeed, 1, 50e18);
        uint256 minimum = bound(floorSeed, 0, requested + 1);
        uint256 budget = insufficientBudget ? 1 : 1000e18;
        MockERC20 imd = MockERC20(index.IMD());
        uint256 imdBefore = imd.balanceOf(who);
        if (budget > imdBefore) budget = imdBefore;
        uint256 sharesBefore = index.balanceOf(who);
        uint256[] memory backingBefore = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            backingBefore[i] = _backing(i);
        }
        bytes32 beforeState = _digest();

        bytes memory callData = supply == 0
            ? abi.encodeCall(Imdex5.mintFirst, (bound(sizeSeed, 10e18, 50e18), new uint256[](5)))
            : abi.encodeCall(Imdex5.mint, (requested, budget, minimum));
        vm.prank(who);
        (bool ok,) = address(index).call(callData);
        if (!ok) {
            ++failedMints;
            assertEq(_digest(), beforeState, "reverted mint changed balances, allowances, or reserves");
            return;
        }
        ++successfulMints;
        uint256 issued = index.balanceOf(who) - sharesBefore;
        assertGt(issued, 0, "free zero-size mint");
        assertLt(imd.balanceOf(who), imdBefore, "mint paid nothing");
        if (supply != 0) {
            assertGe(issued, minimum, "mint missed its floor");
            assertLe(issued, requested, "mint exceeded request");
            assertLe(imdBefore - imd.balanceOf(who), budget, "mint exceeded budget");
            for (uint256 i; i < assets.length; ++i) {
                assertGe(_backing(i) * supply, backingBefore[i] * (supply + issued), "mint diluted a holding");
            }
        }
        shareLedger[who] += issued;
        minted += issued;
    }

    function redeem(uint256 whoSeed, uint256 amountSeed, uint8 edge) external {
        address who = actors[whoSeed % 3];
        uint256 available = shareLedger[who];
        if (available == 0) return;
        uint256 amount = edge % 3 == 0 ? available : edge % 3 == 1 ? 1 : bound(amountSeed, 1, available);
        _redeem(who, amount);
    }

    function _redeem(address who, uint256 amount) private {
        uint256 supply = index.totalSupply();
        uint256[] memory beforeBacking = new uint256[](assets.length);
        uint256[] memory beforeUser = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            beforeBacking[i] = _backing(i);
            beforeUser[i] = MockERC20(assets[i]).balanceOf(who);
        }
        uint256 feeBefore = index.feeImd();
        vm.prank(who);
        index.redeem(amount); // Must succeed even if every payment fails.
        ++redemptions;
        shareLedger[who] -= amount;
        burned += amount;
        assertEq(index.feeImd(), feeBefore, "in-kind redeem spent oracle fees");
        uint256 keep = amount == supply ? 10_000 : 9950;
        for (uint256 i; i < assets.length; ++i) {
            uint256 entitlement = beforeBacking[i] - _backing(i);
            uint256 numerator = beforeBacking[i] * amount * keep;
            uint256 denominator = supply * 10_000;
            // Rational bounds independently establish the exact pro-rata payment,
            // including the last holder's exemption and rounding direction.
            assertLe(entitlement * denominator, numerator, "redeem overpaid entitlement");
            assertGt((entitlement + 1) * denominator, numerator, "redeem underpaid entitlement");
            uint256 received = MockERC20(assets[i]).balanceOf(who) - beforeUser[i];
            assertLe(received, entitlement, "redeem paid another holder's coins");
            debtLedger[who][assets[i]] += entitlement - received;
        }
    }

    function claim(uint256 whoSeed, uint256 assetSeed) external {
        _claim(actors[whoSeed % 3], assets[assetSeed % assets.length]);
    }

    function _claim(address who, address asset) private {
        uint256 expected = debtLedger[who][asset];
        uint256 beforeBalance = MockERC20(asset).balanceOf(who);
        bytes32 beforeState = _digest();
        vm.prank(who);
        (bool ok,) = address(index).call(abi.encodeCall(Imdex5.claim, (asset)));
        if (ok) {
            ++successfulClaims;
            assertGt(expected, 0, "claim paid without an independently recorded debt");
            assertEq(MockERC20(asset).balanceOf(who) - beforeBalance, expected, "claim paid wrong creditor/amount");
            debtLedger[who][asset] = 0;
        } else {
            ++failedClaims;
            assertEq(_digest(), beforeState, "failed claim lost the debt or moved funds");
        }
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % 3];
        address to = actors[toSeed % 3];
        uint256 amount = bound(amountSeed, 0, shareLedger[from]);
        vm.prank(from);
        index.transfer(to, amount);
        shareLedger[from] -= amount;
        shareLedger[to] += amount;
        // The debt ledger deliberately stays with the original redeemer.
    }

    function changeFailure(uint256 assetSeed, uint8 mode, bool dead, uint256 maxIn) external {
        uint256 i = assetSeed % assets.length;
        MockERC20(assets[i]).setFailMode(mode % 4);
        if (i < hooks.length) {
            pm.setDead(_key(i), dead);
            pm.setMaxIn(_key(i), bound(maxIn, 0, 5e18));
        }
    }

    /// Reach zero supply often, including when old debts remain outstanding.
    function exitAll() external {
        for (uint256 i; i < actors.length; ++i) {
            if (shareLedger[actors[i]] != 0) _redeem(actors[i], shareLedger[actors[i]]);
        }
    }

    /// Called after every random sequence. Recoverable token failures cannot
    /// strand any creditor, and a full exit must leave only the fee reserve.
    function settleAll() external {
        for (uint256 i; i < assets.length; ++i) {
            MockERC20(assets[i]).setFailMode(0);
        }
        for (uint256 i; i < actors.length; ++i) {
            if (shareLedger[actors[i]] != 0) _redeem(actors[i], shareLedger[actors[i]]);
            for (uint256 j; j < assets.length; ++j) {
                if (debtLedger[actors[i]][assets[j]] != 0) _claim(actors[i], assets[j]);
            }
        }
    }
}

contract Imdex5ClaimsInvariantTest is Imdex5Base {
    Imdex5ClaimsHandler private handler;
    address[3] private participants;

    function setUp() public {
        _deployAll();
        participants = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            _give(participants[i], 1_000_000e18);
        }
        pm.setMaxIn(_key(tokens[0], hooks[0]), 1e18);
        _mintFirst(alice, 1000e18);
        assertGt(index.idleImd(), 0, "include idle IMD in the debt model");
        vm.startPrank(alice);
        index.transfer(bob, 250e18);
        index.transfer(carol, 250e18);
        vm.stopPrank();
        handler = new Imdex5ClaimsHandler(index, participants);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.mint.selector;
        selectors[1] = handler.redeem.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.transferShares.selector;
        selectors[4] = handler.changeFailure.selector;
        selectors[5] = handler.exitAll.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyHolderAndCreditorIsBacked() public view {
        uint256 supply;
        for (uint256 i; i < 3; ++i) {
            assertEq(index.balanceOf(participants[i]), handler.shareLedger(participants[i]));
            supply += handler.shareLedger(participants[i]);
        }
        assertEq(index.totalSupply(), supply);
        assertEq(supply, handler.minted() - handler.burned());
        for (uint256 i; i <= tokens.length; ++i) {
            address asset = i == tokens.length ? address(imd) : tokens[i];
            uint256 liabilities = asset == address(imd) ? index.idleImd() + index.feeImd() : index.held(asset);
            for (uint256 j; j < 3; ++j) {
                uint256 debt = handler.debtLedger(participants[j], asset);
                assertEq(index.owed(participants[j], asset), debt, "owed differs from independent creditor ledger");
                liabilities += debt;
            }
            assertEq(MockERC20(asset).balanceOf(address(index)), liabilities, "liabilities are not fully backed");
        }
    }

    function afterInvariant() public {
        handler.settleAll();
        invariant_everyHolderAndCreditorIsBacked();
        assertEq(index.totalSupply(), 0);
        assertEq(index.idleImd(), 0);
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(MockERC20(tokens[i]).balanceOf(address(index)), 0);
        }
        assertEq(imd.balanceOf(address(index)), index.feeImd());
    }

    /// Deterministic witness that the random handler reaches failures, debts,
    /// claims, transfers of shares, zero supply, and a later successful first mint.
    function test_handlerExercisesDebtAcrossEpochs() public {
        handler.changeFailure(0, 2, false, 0);
        handler.changeFailure(5, 1, false, 0); // IMD in the handler's six-asset array
        handler.redeem(0, 1e18, 2);
        assertGt(handler.debtLedger(alice, tokens[0]), 0);
        assertGt(handler.debtLedger(alice, address(imd)), 0);
        handler.claim(0, 0);
        assertGt(handler.failedClaims(), 0);
        handler.mint(1, 1e18, 0, false);
        assertGt(handler.failedMints(), 0);
        handler.transferShares(0, 1, 10e18);
        handler.exitAll();
        invariant_everyHolderAndCreditorIsBacked();
        assertEq(index.totalSupply(), 0);
        handler.changeFailure(0, 0, false, 0);
        handler.changeFailure(5, 0, false, 0);
        handler.mint(2, 20e18, 0, false);
        assertGt(handler.successfulMints(), 0);
        handler.claim(0, 0);
        handler.claim(0, 5);
        assertEq(handler.successfulClaims(), 2);
        invariant_everyHolderAndCreditorIsBacked();
        afterInvariant();
    }
}
