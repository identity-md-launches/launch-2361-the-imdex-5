// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Imdex5} from "../src/Imdex5.sol";
import {Imdex5Base} from "./Imdex5Base.sol";
import {MockERC20} from "./mocks/Mocks.sol";

/// @dev The audit of this launch's code (one low, three informational) reproduced and pinned as
/// documented limits. None is redesigned: the brief fixes medium and above and documents the rest.
/// Each test states what the limit is and what bounds it, so a change of behaviour shows up here.
contract Imdex5DocumentedLimitsTest is Imdex5Base {
    function setUp() public {
        _deployAll();
    }

    function _replaceFifthWithNew() internal returns (uint64[] memory list) {
        list = _launches(5);
        list[4] = 2000; // NEW_TOKEN on HOOK_G
        _deliverList(list);
    }

    function _skipped(Vm.Log[] memory logs, address coin, bool buy) internal pure returns (bool) {
        bytes32 sig = keccak256("SwapSkipped(address,bool,uint256)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig || address(uint160(uint256(logs[i].topics[1]))) != coin) continue;
            (bool b,) = abi.decode(logs[i].data, (bool, uint256));
            if (b == buy) return true;
        }
        return false;
    }

    /// @dev Audit 9f216ca3 (low): `PoorFill` and the 2% limit are measured against the pool's
    /// price when `rebalance()` runs, so a pool the caller moved first is bought at the moved price
    /// and booked. Pinned: the buy is booked, not skipped; the index gets fewer coins for the same
    /// IMD; the loss is bounded by the price move (a 44% pump costs about 30% of the coins) and
    /// the IMD spent is the same, so no IMD leaves the accounting. Accepted as a griefing bound
    /// (on mainnet the 1.25% pool fee each way makes the sandwich net-negative), not redesigned.
    function test_aPoolMovedBeforeARebalanceIsBoughtAtTheMovedPriceAndBooked() public {
        _mintFirst(alice, 1000e18);
        _replaceFifthWithNew();
        uint256 snap = vm.snapshotState();

        vm.prank(bob);
        index.rebalance();
        uint256 fairGot = index.held(NEW_TOKEN);
        uint256 fairIdle = index.idleImd();
        assertGt(fairGot, 0, "the fair buy did not run");
        vm.revertToState(snap);

        // what a 2,000 IMD buy does to a 1,000,000 / 10,000 pool: price +44%
        _setPool(NEW_TOKEN, HOOK_G, 833_333e18, 12_000e18);
        vm.recordLogs();
        vm.prank(bob);
        index.rebalance();
        assertFalse(_skipped(vm.getRecordedLogs(), NEW_TOKEN, true), "the pumped buy was skipped");
        uint256 pumpedGot = index.held(NEW_TOKEN);
        assertLt(pumpedGot, fairGot, "the pumped buy was not worse");
        // bounded by the move: 1 / 1.44 of the fair fill, never below the 50% floor at the moved price
        assertGe(pumpedGot, fairGot * 65 / 100, "the pump cost more than the price move");
        assertLe(pumpedGot, fairGot * 75 / 100, "the pump cost less than the price move");
        assertEq(index.idleImd(), fairIdle, "a different amount of IMD was spent");
        assertEq(MockERC20(NEW_TOKEN).balanceOf(address(index)), pumpedGot, "held != balance");
        _assertImdAccounting();
    }

    /// @dev The same limit for a sale: a leaver whose pool was dumped first is sold at the dumped
    /// price (bounded by the 1% sqrt-price move from there) and the proceeds booked.
    function test_aLeaverDumpedBeforeARebalanceIsSoldAtTheDumpedPriceAndBooked() public {
        _mintFirst(alice, 1000e18);
        address leaver = tokens[4];
        address leaverHook = hooks[4];
        _replaceFifthWithNew();
        uint256 snap = vm.snapshotState();

        vm.prank(bob);
        index.rebalance();
        uint256 fairIdleGain = _idleAfterLeaverSale();
        vm.revertToState(snap);

        // price -31%: what a 2,000 IMD sale does to the leaver's pool
        _setPool(leaver, leaverHook, 1_200_000e18, 8_333e18);
        vm.recordLogs();
        vm.prank(bob);
        index.rebalance();
        assertFalse(_skipped(vm.getRecordedLogs(), leaver, false), "the dumped sale was skipped");
        uint256 dumpedIdleGain = _idleAfterLeaverSale();
        assertLt(dumpedIdleGain, fairIdleGain, "the dumped sale was not worse");
        assertGe(dumpedIdleGain, fairIdleGain * 60 / 100, "the dump cost more than the price move");
        assertEq(MockERC20(leaver).balanceOf(address(index)), index.held(leaver), "held != balance");
        _assertImdAccounting();
    }

    /// @dev IMD the leaver's sale produced: what step (4) spent on the five list coins (read as
    /// the IMD their pools gained since the first mint) plus what is left idle.
    function _idleAfterLeaverSale() private view returns (uint256 produced) {
        produced = index.idleImd();
        Imdex5.Coin[] memory coins = index.coins();
        for (uint256 i = 0; i < index.listCount(); ++i) {
            (uint256 r0, uint256 r1,,,,) = pm.pools(pm.poolId(_key(coins[i].token, coins[i].hook)));
            uint256 imdR = _key(coins[i].token, coins[i].hook).currency0 == coins[i].token ? r1 : r0;
            // every list pool started at IMD_RESERVE and the first mint added about 199 IMD to each
            produced += imdR > IMD_RESERVE + 198e18 ? imdR - (IMD_RESERVE + 198e18) : 0;
        }
    }

    /// @dev Audit 0a7c3762 (info): a limited sale stops after a 1% sqrt-price move, which on a
    /// constant-product pool is about 1.01% of the pool's coin reserve, so a leaver larger than
    /// that persists as a residual and every mint, redeem and rebalance loops over it until weekly
    /// rebalances have sold it. Pinned: one rebalance sells about 1% of the reserve (about half of
    /// a holding this size: 19,512 of a 980,488 reserve), the rest stays at index 5 of `coins()`,
    /// redeem pays it, and the next week's rebalance (the rest is now under 1% of the reserve)
    /// sells it whole and drops it from the holdings.
    function test_aLimitedSaleSellsAboutOnePercentOfTheReservePerRebalance() public {
        _mintFirst(alice, 1000e18);
        address leaver = tokens[4];
        address leaverHook = hooks[4];
        uint256 before = index.held(leaver);
        (uint256 r0, uint256 r1,,,,) = pm.pools(pm.poolId(_key(leaver, leaverHook)));
        uint256 reserve = _key(leaver, leaverHook).currency0 == leaver ? r0 : r1;
        uint64[] memory list = _replaceFifthWithNew();

        vm.prank(bob);
        index.rebalance();
        uint256 afterOne = index.held(leaver);
        uint256 sold = before - afterOne;
        assertGt(sold, reserve * 95 / 10_000, "less than 0.95% of the reserve sold");
        assertLt(sold, reserve * 105 / 10_000, "more than 1.05% of the reserve sold");
        assertGt(afterOne, before * 40 / 100, "more than 60% of the leaver sold in one limited sale");
        Imdex5.Coin[] memory coins = index.coins();
        assertEq(coins.length, 6, "the residual was not kept");
        assertEq(coins[5].token, leaver, "the residual is not after the list");
        assertEq(index.listCount(), 5);

        // the residual is redeemed proportionally meanwhile
        uint256 supply = index.totalSupply();
        vm.prank(alice);
        index.redeem(supply / 10);
        assertApproxEqRel(MockERC20(leaver).balanceOf(alice), afterOne * 995 / 10_000, 1e15);
        uint256 afterRedeem = index.held(leaver);
        assertLt(afterRedeem, reserve / 100, "the rest is not under one limited sale");

        // a week later the same list sells the residual again, limited again: now it all goes
        vm.warp(START + 7 days);
        _deliverList(list);
        vm.prank(bob);
        index.rebalance();
        assertEq(index.held(leaver), 0, "the second sale did not clear a residual under 1%");
        assertEq(index.coins().length, 5, "a sold residual stayed in the holdings");
        assertEq(MockERC20(leaver).balanceOf(address(index)), 0, "held != balance");
        _assertImdAccounting();
    }

    /// @dev Audit 18ca8bf9 (info): `ask()` sets `lastAsk` when it opens a request, so a request
    /// that fails, is closed or goes under quorum costs the whole seven days and the 0.75 IMD.
    /// Pinned: after `onOracleFailure` an `ask` before the interval reverts `AskTooSoon`, and one
    /// at the interval opens a new request.
    function test_aFailedRequestCostsTheWholeWeek() public {
        vm.prank(alice);
        index.fund(2e18);
        vm.prank(bob);
        index.ask();
        bytes32 id = intake.lastRequestId();
        assertEq(index.feeImd(), 2e18 - 0.75e18);
        assertEq(index.lastAsk(), START);

        vm.warp(START + 1 hours);
        vm.prank(address(intake));
        index.onOracleFailure(id, 1, bytes32("x"), 0, 0, "");
        assertEq(index.openSince(), 0, "the request was not closed");
        assertEq(index.lastAsk(), START, "the failure reset the interval");

        vm.warp(START + 1 hours + 1);
        vm.expectRevert(Imdex5.AskTooSoon.selector);
        vm.prank(bob);
        index.ask();

        vm.warp(START + 7 days);
        vm.prank(bob);
        index.ask();
        assertEq(intake.count(), 2, "no new request at the interval");
        assertEq(index.feeImd(), 2e18 - 1.5e18, "the failed week's price was not spent");
        assertEq(index.lastAsk(), START + 7 days);
    }

    /// @dev The same for a request `closeRequest` closes after two days without an answer.
    function test_aClosedRequestCostsTheWholeWeek() public {
        vm.prank(alice);
        index.fund(2e18);
        vm.prank(bob);
        index.ask();
        vm.warp(START + 2 days);
        vm.prank(carol);
        index.closeRequest();
        vm.expectRevert(Imdex5.AskTooSoon.selector);
        vm.prank(bob);
        index.ask();
        vm.warp(START + 7 days);
        vm.prank(bob);
        index.ask();
        assertEq(intake.count(), 2);
    }

    /// @dev Audit e2325942 (info): the auditor could not read the live Intake and asked whether it
    /// refunds the 0.5 IMD on a failed request, which would strand it. The version 2 Intake at
    /// `INTAKE` (source verified on Sourcify, full match) forwards every payment to its `payTo` in
    /// the request call and holds nothing; `complete` on a failure only calls the failure selector.
    /// So nothing comes back, the mock matches, and invariant 1 holds across a failed request:
    /// the IMD balance equals `feeImd + idleImd` before, during and after it, and the rounds go on.
    function test_aFailedRequestLeavesEveryImdAccounted() public {
        _mintFirst(alice, 1000e18);
        vm.prank(alice);
        index.fund(2e18);
        _assertImdAccounting();
        vm.prank(bob);
        index.ask();
        bytes32 id = intake.lastRequestId();
        _assertImdAccounting();
        assertEq(imd.balanceOf(address(intake)), index.ORACLE_PRICE(), "the Intake pulled another amount");

        vm.prank(address(intake));
        index.onOracleFailure(id, 2, bytes32("disagreed"), 2, 5, "");
        assertEq(index.openSince(), 0);
        _assertImdAccounting();

        vm.prank(bob);
        index.mint(100e18, 200e18, 0);
        uint256 bobShares = index.balanceOf(bob);
        vm.prank(bob);
        index.redeemToImd(bobShares, 0);
        _assertImdAccounting();

        vm.warp(START + 7 days);
        vm.prank(carol);
        index.ask();
        assertEq(intake.count(), 2);
        _assertImdAccounting();
    }
}
