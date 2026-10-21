// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Imdex5} from "../src/Imdex5.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {Imdex5Base} from "./Imdex5Base.sol";

contract Imdex5OracleAuthenticationTest is Imdex5Base {
    function setUp() public {
        _deployAll();
    }

    function _open() private {
        vm.prank(alice);
        index.fund(2e18);
        vm.prank(bob);
        index.ask();
    }

    function _state() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                index.coins(),
                index.nextList(),
                index.listCount(),
                index.answerHash(),
                index.openRequest(),
                index.openSince(),
                index.lastAsk(),
                index.feeImd(),
                imd.balanceOf(address(index)),
                imd.balanceOf(carol)
            )
        );
    }

    /// Every signed field, including fields the list decoder itself does not
    /// inspect, is authenticated. Mutation always changes the original value.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_mutatingAnySignedFieldCannotAdoptAList(uint8 fieldSeed, uint256 entropy) public {
        _open();
        OracleAttestation.Attestation memory a = _attestation(_launches(3));
        _deliver(a);
        bytes memory signature = _sign(a);
        bytes32 beforeState = _state();
        uint256 field = fieldSeed % 16;
        bytes32 delta = bytes32(bound(entropy, 1, type(uint128).max));
        if (field == 0) {
            a.requestId ^= delta;
        } else if (field == 1) {
            a.chainId ^= uint256(delta);
        } else if (field == 2) {
            a.questionHash ^= delta;
        } else if (field == 3) {
            a.answerType = OracleAttestation.ANSWER_ADDRESS_LIST;
        } else if (field == 4) {
            a.answer = bytes.concat(a.answer, hex"01");
        } else if (field == 5) {
            a.figure ^= uint256(delta);
        } else if (field == 6) {
            a.fromBlock += uint64(bound(entropy, 1, 1000));
        } else if (field == 7) {
            a.toBlock += uint64(bound(entropy, 1, 1000));
        } else if (field == 8) {
            a.blockHash ^= delta;
        } else if (field == 9) {
            a.panelJobId ^= delta;
        } else if (field == 10) {
            a.panelSize = 6;
        } else if (field == 11) {
            a.quorum = 5;
        } else if (field == 12) {
            a.agreed = 4; // still quorate, but no longer what was signed
        } else if (field == 13) {
            a.issuedAt += uint64(bound(entropy, 1, 300));
        } else if (field == 14) {
            a.expiresAt += uint64(bound(entropy, 1, 1 days));
        } else {
            // Changing the domain is equivalent to presenting another consumer's signature.
            Imdex5 other = new Imdex5();
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY_PK, other.attestationDigest(a));
            signature = abi.encodePacked(r, s, v);
        }
        vm.prank(carol);
        vm.expectRevert(field == 4 ? Imdex5.WrongAnswer.selector : OracleAttestationConsumer.BadSignature.selector);
        index.submit(a, signature);
        assertEq(_state(), beforeState, "invalid submission changed the list/request/rewards");
        vm.expectRevert(Imdex5.NoNextList.selector);
        index.rebalance();
    }

    /// A callback's claimed quorum cannot substitute for the signed quorum.
    /// After rejecting the thin signed answer, the original valid one still works.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_quorumForgeryDoesNotConsumeTheValidAnswer(uint16 agreedSeed) public {
        _open();
        OracleAttestation.Attestation memory a = _attestation(_launches(4));
        _deliver(a);
        bytes32 beforeState = _state();
        a.agreed = uint16(bound(agreedSeed, 0, 3));
        bytes memory signature = _sign(a);
        vm.prank(carol);
        vm.expectRevert(Imdex5.BadList.selector);
        index.submit(a, signature);
        assertEq(_state(), beforeState);
        a.agreed = 4;
        signature = _sign(a);
        vm.prank(carol);
        index.submit(a, signature);
        assertEq(index.nextList().length, 4);
        index.rebalance();
        assertEq(index.listCount(), 4);
        bytes32 adopted = _state();
        vm.expectRevert(Imdex5.WrongAnswer.selector);
        index.submit(a, signature);
        assertEq(_state(), adopted, "replay changed the adopted list or paid again");
    }

    /// Receipt of an answer after its signed expiry does not make it current.
    /// Check this after every positive delay, rather than dropping expired
    /// candidates from the generator before calling submit.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_lateDeliveryCannotRefreshExpiredSignature(uint256 delay) public {
        _open();
        OracleAttestation.Attestation memory a = _attestation(_launches(3));
        bytes memory signature = _sign(a);
        vm.warp(uint256(a.expiresAt) + bound(delay, 1, 30 days));
        _deliver(a);
        bytes32 beforeState = _state();
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt));
        index.submit(a, signature);
        assertEq(_state(), beforeState);
        assertEq(index.listCount(), 5);
        assertEq(index.nextList().length, 0);
        vm.expectRevert(Imdex5.NoNextList.selector);
        index.rebalance();
    }
}
