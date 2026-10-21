// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Imdex5} from "../src/Imdex5.sol";
import {IPoolManager} from "../src/Interfaces.sol";
import {Imdex5Base} from "./Imdex5Base.sol";
import {MockERC20} from "./mocks/Mocks.sol";

/// Exercises the payout boundary with an exact 1:1 pre-swap price, so the
/// independent oracle is simply `2 * output >= input`, in either token order.
contract Imdex5SwapBoundariesTest is Imdex5Base {
    struct Fill {
        uint256 input;
        uint256 output;
        bool skipped;
    }

    function setUp() public {
        _deployAll();
    }

    function _fill(Vm.Log[] memory logs, address token, bool buy) private view returns (Fill memory f) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(index) || logs[i].topics.length != 2) continue;
            if (address(uint160(uint256(logs[i].topics[1]))) != token) continue;
            if (logs[i].topics[0] == keccak256("SwapSkipped(address,bool,uint256)")) {
                (bool direction,) = abi.decode(logs[i].data, (bool, uint256));
                if (direction == buy) f.skipped = true;
            } else if (logs[i].topics[0] == keccak256("Swapped(address,bool,uint256,uint256)")) {
                (bool direction, uint256 amountIn, uint256 amountOut) =
                    abi.decode(logs[i].data, (bool, uint256, uint256));
                if (direction == buy) {
                    f.input += amountIn;
                    f.output += amountOut;
                }
            }
        }
    }

    function _rebalanceFill(address token, bool buy) private returns (Fill memory) {
        vm.recordLogs();
        vm.prank(carol);
        index.rebalance();
        return _fill(vm.getRecordedLogs(), token, buy);
    }

    function _prepare(uint256 which, bool buy, uint256 first) private returns (IPoolManager.PoolKey memory key) {
        uint64[] memory three = new uint64[](3);
        uint256 n;
        for (uint256 i; i < 5 && n < 3; ++i) {
            if (i != which) three[n++] = launches[i];
        }
        if (buy) {
            // Start with only three holdings. The chosen fourth is a new buy.
            _deliverList(three);
            index.rebalance();
            _mintFirst(alice, first);
            vm.warp(vm.getBlockTimestamp() + 7 days);
            uint64[] memory four = new uint64[](4);
            for (uint256 i; i < 3; ++i) {
                four[i] = three[i];
            }
            four[3] = launches[which];
            _deliverList(four);
            assertEq(index.held(tokens[which]), 0);
        } else {
            _mintFirst(alice, first);
            // With three list entries there is no trim pass: exactly one sale of this leaver.
            _deliverList(three);
        }
        _setPool(tokens[which], hooks[which], COIN_RESERVE, COIN_RESERVE);
        key = _key(tokens[which], hooks[which]);
        assertEq(pm.sqrtPriceOf(key), 1 << 96, "the boundary oracle needs a 1:1 pool");
    }

    function _assertAccounting() private view {
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(MockERC20(tokens[i]).balanceOf(address(index)), index.held(tokens[i]), "unbacked holding");
        }
        _assertImdAccounting();
    }

    function _checkFill(uint256 which, bool buy, IPoolManager.PoolKey memory key, Fill memory honest, uint256 output)
        private
    {
        pm.setShortBy(key, honest.output - output);
        uint256 heldBefore = index.held(tokens[which]);
        uint256 coinBalanceBefore = MockERC20(tokens[which]).balanceOf(address(index));
        (uint256 r0, uint256 r1,,,,) = pm.pools(pm.poolId(key));
        Fill memory actual = _rebalanceFill(tokens[which], buy);
        (uint256 after0, uint256 after1,,,,) = pm.pools(pm.poolId(key));
        if (output * 2 < honest.input) {
            assertTrue(actual.skipped, "a below-half fill was booked");
            assertEq(index.held(tokens[which]), heldBefore, "failed swap changed held");
            assertEq(MockERC20(tokens[which]).balanceOf(address(index)), coinBalanceBefore);
            assertEq(after0, r0, "failed swap changed reserve0");
            assertEq(after1, r1, "failed swap changed reserve1");
        } else {
            assertFalse(actual.skipped, "an at-least-half fill was rejected");
            assertEq(actual.input, honest.input);
            assertEq(actual.output, output);
            assertEq(index.held(tokens[which]), buy ? heldBefore + output : heldBefore - honest.input);
            assertTrue(after0 != r0 && after1 != r1, "successful swap did not settle");
        }
        assertEq(index.nextList().length, 0, "a skipped swap blocked adoption");
        _assertAccounting();
    }

    function _boundary(uint256 which, bool buy) private {
        IPoolManager.PoolKey memory key = _prepare(which, buy, 1000e18);
        uint256 snapshot = vm.snapshotState();
        Fill memory honest = _rebalanceFill(tokens[which], buy);
        assertFalse(honest.skipped);
        assertGt(honest.input, 4);
        assertGt(honest.output, (honest.input + 1) / 2);
        assertTrue(vm.revertToState(snapshot));
        uint256 half = (honest.input + 1) / 2;
        uint256[5] memory outputs = [uint256(0), 1, half - 1, half, half + 1];
        for (uint256 i; i < outputs.length; ++i) {
            snapshot = vm.snapshotState();
            _checkFill(which, buy, key, honest, outputs[i]);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_buyBoundary_coinBeforeImd() public {
        _boundary(0, true);
    }

    function test_buyBoundary_coinAfterImd() public {
        _boundary(1, true);
    }

    function test_sellBoundary_coinBeforeImd() public {
        _boundary(0, false);
    }

    function test_sellBoundary_coinAfterImd() public {
        _boundary(1, false);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_rebalanceFillThreshold(bool coinAfterImd, bool buy, uint256 first, uint256 outSeed) public {
        uint256 which = coinAfterImd ? 1 : 0;
        IPoolManager.PoolKey memory key = _prepare(which, buy, bound(first, 50e18, 2000e18));
        uint256 snapshot = vm.snapshotState();
        Fill memory honest = _rebalanceFill(tokens[which], buy);
        assertGt(honest.input, 0, "fuzz case never reached a swap");
        assertFalse(honest.skipped);
        assertTrue(vm.revertToState(snapshot));
        _checkFill(which, buy, key, honest, bound(outSeed, 0, honest.output));
    }

    /// A zero-output sale rolls back its pool and pays in kind. The IMD minimum
    /// must also roll back the earlier successful sales and all in-kind payments.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_zeroOutputSaleAndMinimumRollback(bool coinAfterImd, uint256 sharesSeed) public {
        _mintFirst(alice, 1000e18);
        uint256 which = coinAfterImd ? 1 : 0;
        uint256 shares = bound(sharesSeed, 1e18, index.balanceOf(alice));
        IPoolManager.PoolKey memory key = _key(tokens[which], hooks[which]);
        pm.setShortBy(key, type(uint128).max);
        uint256 supply = index.totalSupply();
        uint256 coinBefore = index.held(tokens[which]);
        uint256 imdBefore = imd.balanceOf(alice);
        (uint256 r0, uint256 r1,,,,) = pm.pools(pm.poolId(key));
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        vm.prank(alice);
        index.redeemToImd(shares, 0);
        assertTrue(_fill(vm.getRecordedLogs(), tokens[which], false).skipped);
        uint256 out = imd.balanceOf(alice) - imdBefore;
        uint256 paidInKind = MockERC20(tokens[which]).balanceOf(alice);
        assertGt(paidInKind, 0, "failed sale did not pay in kind");
        assertEq(index.held(tokens[which]) + paidInKind, coinBefore);
        (uint256 after0, uint256 after1,,,,) = pm.pools(pm.poolId(key));
        assertEq(after0, r0);
        assertEq(after1, r1);
        _assertAccounting();
        assertTrue(vm.revertToState(snapshot));

        bytes32 beforeState = _economicState();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Imdex5.TooLittleOut.selector, out));
        index.redeemToImd(shares, out + 1);
        assertEq(_economicState(), beforeState, "minimum failure did not roll back the whole redemption");
        assertEq(index.totalSupply(), supply);
        vm.prank(alice);
        index.redeemToImd(shares, out);
        assertEq(imd.balanceOf(alice) - imdBefore, out, "the exact minimum should pass");
    }

    function _economicState() private view returns (bytes32 digest) {
        digest = keccak256(
            abi.encode(
                index.totalSupply(),
                index.balanceOf(alice),
                index.idleImd(),
                index.feeImd(),
                imd.balanceOf(alice),
                imd.balanceOf(address(index)),
                imd.balanceOf(address(pm))
            )
        );
        for (uint256 i; i < tokens.length; ++i) {
            (uint256 r0, uint256 r1,,,,) = pm.pools(pm.poolId(_key(tokens[i], hooks[i])));
            digest = keccak256(
                abi.encode(
                    digest,
                    index.held(tokens[i]),
                    index.owed(alice, tokens[i]),
                    MockERC20(tokens[i]).balanceOf(alice),
                    MockERC20(tokens[i]).balanceOf(address(index)),
                    MockERC20(tokens[i]).balanceOf(address(pm)),
                    r0,
                    r1
                )
            );
        }
    }
}
