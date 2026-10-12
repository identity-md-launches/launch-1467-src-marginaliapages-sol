// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PagesFixture, ClaimIntake} from "./Pages.t.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {MarginaliaPages, IMarginaliaHookPages, IMarginaliaRecords} from "src/MarginaliaPages.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/OracleAttestation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// forge-config: default.fuzz.runs = 1000
contract PagesOracleBoundariesTest is PagesFixture {
    function _request() internal returns (bytes32 subject, bytes32 requestId) {
        subject = pages.registerHandle("boundary");
        _twentyOf(subject);
        vm.prank(bob);
        requestId = pages.requestClaim("boundary", 123);
    }

    function _unchanged(bytes32 subject, bytes32 requestId, bytes32 uuid) internal view {
        (bytes32 pending, address asker, uint256 paid,) = pages.claims(subject);
        assertEq(pending, requestId, "rejection must leave the pending request");
        assertEq(asker, bob);
        assertEq(paid, 0.5 ether);
        assertEq(pages.payeeOf(subject), address(0));
        (,, uint256 escrow,) = pages.subjects(subject);
        assertEq(escrow, 0.84 ether);
        assertEq(pages.reserveOf(subject), 10.5 ether);
        assertEq(imd.balanceOf(address(pages)), 11.34 ether);
        assertFalse(pages.consumed(uuid));
    }

    function _reject(
        bytes32 id,
        OracleAttestation.Attestation memory a,
        bytes memory sig,
        bytes memory errorData
    ) internal {
        vm.prank(address(intake));
        vm.expectRevert(errorData);
        pages.onOracleResult(id, a, sig);
    }

    function testFuzzEverySignedFieldRejectsPostSignatureTampering(uint8 fieldSeed) public {
        (bytes32 subject, bytes32 id) = _request();
        bytes32 uuid = keccak256("oracle UUID separate from intake id");
        OracleAttestation.Attestation memory a = _att(uuid, carol);
        bytes memory sig = _sign(a);
        uint256 field = bound(fieldSeed, 0, 14);
        if (field == 0) a.requestId = keccak256("different UUID");
        else if (field == 1) a.chainId++;
        else if (field == 2) a.questionHash = keccak256("different question");
        else if (field == 3) a.answerType++;
        else if (field == 4) a.answer = abi.encode(alice);
        else if (field == 5) a.figure++;
        else if (field == 6) a.fromBlock++;
        else if (field == 7) a.toBlock++;
        else if (field == 8) a.blockHash = keccak256("different block");
        else if (field == 9) a.panelJobId = keccak256("different panel job");
        else if (field == 10) a.panelSize++;
        else if (field == 11) a.quorum++;
        else if (field == 12) a.agreed--;
        else if (field == 13) a.issuedAt++;
        else a.expiresAt++;
        _reject(id, a, sig, abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector));
        _unchanged(subject, id, uuid);
        assertFalse(pages.consumed(a.requestId));
    }

    function testWrongSignerAndMalformedSignaturesLeaveClaimOpen() public {
        (bytes32 subject, bytes32 id) = _request();
        OracleAttestation.Attestation memory a = _att(keccak256("signature UUID"), carol);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, pages.attestationDigest(a));
        _reject(
            id,
            a,
            abi.encodePacked(r, s, v),
            abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector)
        );
        _reject(id, a, hex"", abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector));
        _reject(id, a, new bytes(65), abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector));
        _unchanged(subject, id, a.requestId);
        assertTrue(intake.deliver(address(pages), id, a, _sign(a)));
    }

    function testAnotherConsumerDomainCannotAuthorizeThisClaim() public {
        (bytes32 subject, bytes32 id) = _request();
        MarginaliaPages other = new MarginaliaPages(
            IMarginaliaHookPages(address(hook)),
            IMarginaliaRecords(address(annexRecords)),
            intake,
            ACTION,
            signerAddr
        );
        OracleAttestation.Attestation memory a = _att(keccak256("domain UUID"), carol);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, other.attestationDigest(a));
        _reject(
            id,
            a,
            abi.encodePacked(r, s, v),
            abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector)
        );
        _unchanged(subject, id, a.requestId);
        assertTrue(intake.deliver(address(pages), id, a, _sign(a)));
    }

    function testChainDomainChangeInvalidatesEvenCorrectlyTargetedAnswer() public {
        (bytes32 subject, bytes32 id) = _request();
        // Read through an external call: the optimizer may rematerialize a local `block.chainid`
        // after vm.chainId, since real transactions cannot change their chain midway through a call.
        (,,, uint256 original,,,) = pages.eip712Domain();
        OracleAttestation.Attestation memory a = _att(keccak256("chain UUID"), carol);
        a.chainId = original;
        // Keep the answer's question chain correct for the eventual delivery, but sign in another domain.
        vm.chainId(original + 1);
        bytes memory sig = _sign(a);
        vm.chainId(original);
        _reject(id, a, sig, abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector));
        _unchanged(subject, id, a.requestId);
        assertTrue(intake.deliver(address(pages), id, a, _sign(a)));
    }

    function testEachPanelMinimumIsEnforcedIndependently() public {
        (bytes32 subject, bytes32 id) = _request();
        OracleAttestation.Attestation memory a = _att(keccak256("panel UUID"), carol);
        a.panelSize = 4;
        a.quorum = 4;
        a.agreed = 4;
        _reject(id, a, _sign(a), abi.encodeWithSelector(MarginaliaPages.BadAnswer.selector));
        a.panelSize = 5;
        a.quorum = 3;
        a.agreed = 5;
        _reject(id, a, _sign(a), abi.encodeWithSelector(MarginaliaPages.BadAnswer.selector));
        a.quorum = 4;
        a.agreed = 3;
        _reject(id, a, _sign(a), abi.encodeWithSelector(MarginaliaPages.BadAnswer.selector));
        _unchanged(subject, id, a.requestId);
        a.agreed = 4;
        assertTrue(intake.deliver(address(pages), id, a, _sign(a)), "minimum 4 of 5 is sufficient");
        assertEq(pages.payeeOf(subject), carol);
    }

    function testExpiryIsInclusiveAndFutureToleranceIsBounded() public {
        (bytes32 subject, bytes32 id) = _request();
        uint64 now_ = uint64(vm.getBlockTimestamp());
        OracleAttestation.Attestation memory a = _att(keccak256("time UUID"), carol);
        a.expiresAt = now_ - 1;
        _reject(
            id,
            a,
            _sign(a),
            abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, now_ - 1)
        );
        a.expiresAt = now_ + 1 days;
        a.issuedAt = now_ + 5 minutes + 1;
        _reject(
            id,
            a,
            _sign(a),
            abi.encodeWithSelector(OracleAttestationConsumer.AttestationNotYetValid.selector, a.issuedAt)
        );
        _unchanged(subject, id, a.requestId);
        a.issuedAt = now_;
        a.expiresAt = now_;
        assertTrue(intake.deliver(address(pages), id, a, _sign(a)), "exact expiry is valid");
        vm.prank(bob);
        bytes32 next = pages.requestClaim("clockdrift", 456);
        a = _att(keccak256("clock drift UUID"), carol);
        a.issuedAt = now_ + 5 minutes;
        assertTrue(intake.deliver(address(pages), next, a, _sign(a)), "exact drift tolerance is valid");
    }

    function testMalformedAddressAnswersDoNotConsumeTheOracleUuid() public {
        (bytes32 subject, bytes32 id) = _request();
        OracleAttestation.Attestation memory a = _att(keccak256("decode UUID"), carol);
        a.answer = hex"";
        assertFalse(intake.deliver(address(pages), id, a, _sign(a)));
        a.answer = new bytes(31);
        assertFalse(intake.deliver(address(pages), id, a, _sign(a)));
        a.answer = abi.encode(uint256(1) << 160); // noncanonical address: nonzero upper 96 bits
        assertFalse(intake.deliver(address(pages), id, a, _sign(a)));
        _unchanged(subject, id, a.requestId);
        a.answer = abi.encode(carol);
        assertTrue(intake.deliver(address(pages), id, a, _sign(a)));
    }

    function testRevertingEscrowTransferRollsBackClaimAndConsumption() public {
        (bytes32 subject, bytes32 id) = _request();
        OracleAttestation.Attestation memory a = _att(keccak256("transfer UUID"), carol);
        uint256 askerBefore = imd.balanceOf(bob);
        uint256 payeeBefore = imd.balanceOf(carol);
        vm.mockCallRevert(address(imd), abi.encodeCall(IERC20.transfer, (carol, 0.34 ether)), hex"f00d");
        assertFalse(intake.deliver(address(pages), id, a, _sign(a)));
        _unchanged(subject, id, a.requestId);
        assertEq(imd.balanceOf(bob), askerBefore, "reimbursement must roll back too");
        assertEq(imd.balanceOf(carol), payeeBefore);
        vm.clearMockedCalls();
        assertTrue(intake.deliver(address(pages), id, a, _sign(a)));
        assertEq(imd.balanceOf(bob), askerBefore + 0.5 ether);
        assertEq(imd.balanceOf(carol), payeeBefore + 0.34 ether);
    }

    function testReimbursementUsesThePaidPriceAndEqualityIsEnough() public {
        bytes32 subject = pages.registerHandle("exactescrow");
        vm.prank(alice);
        pages.buy(subject, 1, 0.055 ether); // issuer escrow = 0.004 IMD
        intake.setPrice(0.004 ether);
        uint256 askerBefore = imd.balanceOf(bob);
        uint256 payeeBefore = imd.balanceOf(carol);
        vm.prank(bob);
        bytes32 id = pages.requestClaim("exactescrow", 1);
        intake.setPrice(1 ether); // changing the next quote must not change the reimbursement
        OracleAttestation.Attestation memory a = _att(keccak256("exact escrow UUID"), carol);
        assertTrue(intake.deliver(address(pages), id, a, _sign(a)));
        assertEq(imd.balanceOf(bob), askerBefore);
        assertEq(imd.balanceOf(carol), payeeBefore);
        assertEq(pages.payeeOf(subject), carol);
        assertEq(imd.balanceOf(address(pages)), 0.05 ether);
    }

    function testClaimBeforeFirstBuyPaysFutureFeesWithoutChangingRegistration() public {
        bytes32 subject = pages.subjectOfHandle("earlyclaim");
        vm.prank(bob);
        bytes32 id = pages.requestClaim("earlyclaim", 1);
        OracleAttestation.Attestation memory a = _att(keccak256("early claim UUID"), carol);
        assertTrue(intake.deliver(address(pages), id, a, _sign(a)));
        assertEq(pages.payeeOf(subject), carol);
        pages.registerHandle("earlyclaim");
        uint256 before = imd.balanceOf(carol);
        vm.prank(alice);
        pages.buy(subject, 1, 0.055 ether);
        assertEq(imd.balanceOf(carol) - before, 0.004 ether);
        (,, uint256 escrow, uint64 since) = pages.subjects(subject);
        assertEq(escrow, 0);
        assertEq(since, 0);
        vm.expectRevert(MarginaliaPages.NothingToRecycle.selector);
        pages.recycle(subject);
    }

    function testRecyclingBoundaryResetsTheNextEscrowWindow() public {
        bytes32 subject = pages.registerHandle("twowindows");
        vm.prank(alice);
        pages.buy(subject, 1, 0.055 ether);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 90 days - 1);
        vm.expectRevert(MarginaliaPages.TooEarly.selector);
        pages.recycle(subject);
        vm.warp(start + 90 days);
        pages.recycle(subject);
        (,, uint256 escrow, uint64 since) = pages.subjects(subject);
        assertEq(escrow, 0);
        assertEq(since, 0);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(alice);
        pages.sell(subject, 1, 0.045 ether); // a sell also accrues issuer fees
        (,, escrow, since) = pages.subjects(subject);
        assertEq(escrow, 0.004 ether);
        assertEq(since, start + 91 days);
        vm.expectRevert(MarginaliaPages.TooEarly.selector);
        pages.recycle(subject);
        vm.warp(uint256(since) + 90 days);
        pages.recycle(subject);
        assertEq(pages.reserveOf(subject), 0);
        assertEq(imd.balanceOf(address(pages)), 0);
    }
}

/// @dev The request, signatures and buys live in setUp. The test itself delivers before reading balances
/// or claim slots, exercising fresh zero-balance recipients under a new transaction's 200k callback budget.
contract PagesColdCallbackTest is Fixture {
    MarginaliaPages private pages;
    ClaimIntake private intake;
    address private asker;
    address private payee;
    bytes32 private requestId;
    bytes32 private subject;
    OracleAttestation.Attestation private attestation;
    bytes private signature;

    function setUp() public {
        _setup();
        intake = new ClaimIntake();
        pages = new MarginaliaPages(
            IMarginaliaHookPages(address(hook)),
            IMarginaliaRecords(address(0)),
            intake,
            bytes32("oracle.request@oracle-1"),
            vm.addr(0x5E7)
        );
        subject = pages.registerHandle("coldcallback");
        vm.startPrank(alice);
        imd.approve(address(pages), 100 ether);
        pages.buy(subject, 10, 100 ether);
        vm.stopPrank();
        vm.startPrank(bob);
        imd.approve(address(pages), 100 ether);
        pages.buy(subject, 10, 100 ether);
        vm.stopPrank();
        asker = makeAddr("cold empty asker");
        payee = makeAddr("cold empty payee");
        imd.transfer(asker, 0.5 ether);
        vm.startPrank(asker);
        imd.approve(address(pages), 0.5 ether);
        requestId = pages.requestClaim("coldcallback", 777);
        vm.stopPrank();
        OracleAttestation.Attestation memory a;
        a.requestId = keccak256("cold callback oracle UUID");
        a.chainId = block.chainid;
        a.questionHash = keccak256("resolved cold question");
        a.answerType = OracleAttestation.ANSWER_ADDRESS;
        a.answer = abi.encode(payee);
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 4;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 days);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x5E7, pages.attestationDigest(a));
        attestation = a;
        signature = abi.encodePacked(r, s, v);
    }

    function testColdCallbackPaysTwoFreshRecipientsWithin200k() public {
        assertTrue(intake.deliver(address(pages), requestId, attestation, signature));
        assertEq(imd.balanceOf(asker), 0.5 ether);
        assertEq(imd.balanceOf(payee), 0.34 ether);
        assertEq(pages.payeeOf(subject), payee);
        assertEq(imd.balanceOf(address(pages)), 10.5 ether);
        assertTrue(pages.consumed(attestation.requestId));
        assertFalse(intake.deliver(address(pages), requestId, attestation, signature));
    }
}
