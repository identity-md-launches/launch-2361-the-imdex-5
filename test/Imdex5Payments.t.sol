// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Imdex5} from "../src/Imdex5.sol";
import {Imdex5Base} from "./Imdex5Base.sol";
import {MockERC20, MockPoolManager} from "./mocks/Mocks.sol";

/// @dev A coin that refuses transfers to the PoolManager (so the index can never sell it) and,
/// when the index pays it while the manager is unlocked, takes 1 wei of IMD from the manager:
/// `take` is open to any caller while unlocked and leaves a delta the index cannot settle.
/// Records whether the manager was unlocked when the index last paid it (review e3e0815c).
contract ManagerTouchingCoin is MockERC20 {
    address public index;
    address public attacker;
    bool public paidWhileUnlocked;

    function set(address index_, address attacker_) external {
        index = index_;
        attacker = attacker_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        MockPoolManager pm = MockPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
        require(to != address(pm), "no sales");
        if (msg.sender == index && pm.unlocked()) {
            paidWhileUnlocked = true;
            pm.take(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7, attacker, 1);
        }
        return super.transfer(to, amount);
    }
}

/// @dev The independent review of commit a578235 (two medium findings, both fixed):
/// eade2f07, a coin transfer that moves the funds and then returns false was paid and also
/// recorded as owed; e3e0815c, `redeemToImd` paid a failed sale's coin in kind inside the
/// PoolManager's unlock, so a coin whose transfer touched the manager reverted the exit for all.
contract Imdex5PaymentsTest is Imdex5Base {
    address attacker = makeAddr("attacker");

    function setUp() public {
        _deployAll();
    }

    function _entitlement(address token, uint256 shares, uint256 supply) internal view returns (uint256) {
        return index.held(token) * shares * 9950 / (supply * 10_000);
    }

    // ---- eade2f07: a transfer that moves the funds and returns false is paid once ----

    function test_redeemOfACoinThatMovesFundsAndReturnsFalsePaysOnce() public {
        _mintFirst(alice, 1000e18);
        uint256 shares = index.balanceOf(alice) / 4;
        vm.prank(alice);
        index.transfer(bob, shares);
        uint256 supply = index.totalSupply();
        uint256 want = _entitlement(tokens[0], shares, supply);
        uint256 want1 = _entitlement(tokens[1], shares, supply);
        uint256 heldBefore = index.held(tokens[0]);

        MockERC20(tokens[0]).setFailMode(4);
        vm.prank(bob);
        index.redeem(shares);
        // the false return rolled the coin's own state change back; the amount is owed, not paid
        assertEq(MockERC20(tokens[0]).balanceOf(bob), 0, "paid despite the false return");
        assertEq(index.owed(bob, tokens[0]), want, "owed once");
        assertEq(index.held(tokens[0]), heldBefore - want);
        assertEq(MockERC20(tokens[0]).balanceOf(address(index)), index.held(tokens[0]) + want, "balance != held + owed");
        // the other coins were paid normally
        assertEq(MockERC20(tokens[1]).balanceOf(bob), want1);

        MockERC20(tokens[0]).setFailMode(0);
        vm.prank(bob);
        index.claim(tokens[0]);
        assertEq(MockERC20(tokens[0]).balanceOf(bob), want, "the entitlement is paid exactly once");
        assertEq(index.owed(bob, tokens[0]), 0);
        assertEq(MockERC20(tokens[0]).balanceOf(address(index)), index.held(tokens[0]), "holders' backing is intact");
    }

    function test_redeemToImdInKindOfACoinThatMovesFundsAndReturnsFalsePaysOnce() public {
        _mintFirst(alice, 1000e18);
        uint256 shares = index.balanceOf(alice) / 4;
        vm.prank(alice);
        index.transfer(bob, shares);
        uint256 supply = index.totalSupply();
        // redeemToImd floors the pro-rata amount first, then applies the 99.50%
        uint256 want = index.held(tokens[2]) * shares / supply * 9950 / 10_000;
        uint256 heldBefore = index.held(tokens[2]);

        // the sale reverts (dead pool), so the coin is paid in kind; its transfer lies
        pm.setDead(_key(tokens[2], hooks[2]), true);
        MockERC20(tokens[2]).setFailMode(4);
        uint256 imdBefore = imd.balanceOf(bob);
        vm.prank(bob);
        index.redeemToImd(shares, 0);
        assertGt(imd.balanceOf(bob), imdBefore, "the other coins were sold for IMD");
        assertEq(MockERC20(tokens[2]).balanceOf(bob), 0, "paid despite the false return");
        assertEq(index.owed(bob, tokens[2]), want, "owed once");
        assertEq(index.held(tokens[2]), heldBefore - want);

        MockERC20(tokens[2]).setFailMode(0);
        vm.prank(bob);
        index.claim(tokens[2]);
        assertEq(MockERC20(tokens[2]).balanceOf(bob), want, "the entitlement is paid exactly once");
        assertEq(MockERC20(tokens[2]).balanceOf(address(index)), index.held(tokens[2]), "holders' backing is intact");
        _assertImdAccounting();
    }

    /// @dev The other failure modes keep their outcome: a revert, a plain false return, a gas
    /// burner and an address without code are owed and nothing moves; a plain coin is paid.
    function test_everyFailureModeIsOwedOnceAndNothingMoves(uint8 mode) public {
        mode = uint8(bound(mode, 1, 4));
        _mintFirst(alice, 1000e18);
        uint256 shares = 200e18;
        uint256 supply = index.totalSupply();
        uint256[] memory wants = new uint256[](5);
        for (uint256 i = 0; i < 5; ++i) {
            wants[i] = _entitlement(tokens[i], shares, supply);
        }
        uint256 want = wants[1];
        MockERC20(tokens[1]).setFailMode(mode);
        vm.prank(alice);
        index.redeem{gas: 30_000_000}(shares);
        assertEq(MockERC20(tokens[1]).balanceOf(alice), 0);
        assertEq(index.owed(alice, tokens[1]), want);
        assertEq(MockERC20(tokens[1]).balanceOf(address(index)), index.held(tokens[1]) + want);
        for (uint256 i = 0; i < 5; ++i) {
            if (i == 1) continue;
            assertEq(MockERC20(tokens[i]).balanceOf(alice), wants[i]);
            assertEq(index.owed(alice, tokens[i]), 0);
        }
        MockERC20(tokens[1]).setFailMode(0);
        vm.prank(alice);
        index.claim(tokens[1]);
        assertEq(MockERC20(tokens[1]).balanceOf(alice), want);
        assertEq(MockERC20(tokens[1]).balanceOf(address(index)), index.held(tokens[1]));
    }

    /// @dev `paySelf` is the contract's own: nobody else can move a coin through it.
    function test_paySelfRefusesEveryoneButTheIndex() public {
        _mintFirst(alice, 1000e18);
        vm.prank(attacker);
        vm.expectRevert(Imdex5.OnlySelf.selector);
        index.paySelf(tokens[0], attacker, 1);
    }

    // ---- e3e0815c: the in-kind part of redeemToImd is paid after the unlock ----

    function _installTouchingCoin() internal returns (ManagerTouchingCoin coin) {
        coin = ManagerTouchingCoin(tokens[0]);
        vm.etch(tokens[0], address(new ManagerTouchingCoin()).code);
        coin.set(address(index), attacker);
        coin.mint(address(pm), COIN_RESERVE);
    }

    function test_redeemToImdPaysAnUnsellableCoinInKindAfterTheUnlock() public {
        ManagerTouchingCoin coin = _installTouchingCoin();
        _mintFirst(alice, 1000e18);
        assertGt(index.held(tokens[0]), 0, "the coin is bought and held");
        vm.prank(bob);
        index.mint(100e18, 200e18, 0);

        uint256 bobShares = index.balanceOf(bob);
        uint256 supply = index.totalSupply();
        uint256 want = _entitlement(tokens[0], bobShares, supply);
        uint256 imdBefore = imd.balanceOf(bob);
        vm.prank(bob);
        index.redeemToImd(bobShares, 0);
        assertGt(imd.balanceOf(bob), imdBefore, "bob was paid IMD for the sellable coins");
        assertEq(index.balanceOf(bob), 0);
        assertEq(coin.balanceOf(bob), want, "the unsellable coin is paid in kind at 99.50%");
        assertEq(index.owed(bob, tokens[0]), 0, "paid, not owed");
        assertFalse(coin.paidWhileUnlocked(), "the coin was called while the manager was unlocked");
        assertEq(imd.balanceOf(attacker), 0, "nothing was taken from the manager");
        assertEq(coin.balanceOf(address(index)), index.held(tokens[0]));
        _assertImdAccounting();

        // every other holder can still exit to IMD, and the last one is paid in full
        uint256 all = index.balanceOf(alice);
        uint256 last = index.held(tokens[0]);
        vm.prank(alice);
        index.redeemToImd(all, 0);
        assertEq(index.totalSupply(), 0);
        assertEq(coin.balanceOf(alice), last, "the last holder gets all of the unsellable coin");
        assertEq(index.held(tokens[0]), 0);
    }

    function test_redeemStillWorksWithTheTouchingCoinHeld() public {
        ManagerTouchingCoin coin = _installTouchingCoin();
        _mintFirst(alice, 1000e18);
        uint256 want = _entitlement(tokens[0], 100e18, index.totalSupply());
        vm.prank(alice);
        index.redeem(100e18);
        assertEq(coin.balanceOf(alice), want);
        assertFalse(coin.paidWhileUnlocked());
    }

    /// @dev A short fill (the pool took part of the sale) pays the unsold part in kind, after the
    /// unlock, and the sold part in IMD; `Paid` is emitted for the coin once.
    function test_aShortSaleIsPaidInKindAfterTheUnlockAndInImdForTheRest() public {
        _mintFirst(alice, 1000e18);
        uint256 h = index.held(tokens[3]);
        pm.setMaxIn(_key(tokens[3], hooks[3]), h / 10);
        uint256 shares = 500e18;
        uint256 supply = index.totalSupply();
        uint256 amount = h * shares / supply;
        uint256 unsold = amount - h / 10;
        uint256 paidInKind = unsold * 9950 / 10_000;
        vm.expectEmit(true, true, false, true);
        emit Imdex5.Paid(alice, tokens[3], paidInKind);
        vm.prank(alice);
        index.redeemToImd(shares, 0);
        assertEq(MockERC20(tokens[3]).balanceOf(alice), paidInKind);
        assertEq(index.held(tokens[3]), h - amount + (unsold - paidInKind));
        assertEq(MockERC20(tokens[3]).balanceOf(address(index)), index.held(tokens[3]));
        assertEq(index.owed(alice, tokens[3]), 0);
    }

    /// @dev Payment after the unlock is the same payment: the redeemer's in-kind receipts match
    /// the redeem rule for any share count, with and without the fee, and `held` matches the
    /// balance afterwards.
    function test_inKindPaymentsMatchTheRedeemRule(uint256 shares, uint256 deadMask) public {
        _mintFirst(alice, 1000e18);
        shares = bound(shares, 1, index.totalSupply());
        deadMask = bound(deadMask, 1, 31);
        uint256 supply = index.totalSupply();
        uint256 keepBps = shares == supply ? 10_000 : 9950;
        uint256[] memory want = new uint256[](5);
        for (uint256 i = 0; i < 5; ++i) {
            if (deadMask & (1 << i) == 0) continue;
            pm.setDead(_key(tokens[i], hooks[i]), true);
            want[i] = index.held(tokens[i]) * shares / supply * keepBps / 10_000;
        }
        vm.prank(alice);
        index.redeemToImd(shares, 0);
        for (uint256 i = 0; i < 5; ++i) {
            if (deadMask & (1 << i) == 0) continue;
            assertEq(MockERC20(tokens[i]).balanceOf(alice), want[i], "in-kind amount");
            assertEq(MockERC20(tokens[i]).balanceOf(address(index)), index.held(tokens[i]), "held != balance");
        }
        _assertImdAccounting();
    }
}
