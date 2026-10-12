// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {MarginaliaPages, IMarginaliaHookPages, IMarginaliaRecords} from "../src/MarginaliaPages.sol";
import {MarginaliaTypes as T} from "../src/MarginaliaTypes.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Stands in for the Intake: takes the price, records the body, and delivers an attestation back to the
/// consumer under the protocol's 200k callback stipend, reporting whether the callback succeeded.
contract ClaimIntake is IIntake {
    uint256 public price = 0.5 ether;
    uint256 public requests;
    bytes public lastBody;
    bytes32 public lastRequestId;

    function setPrice(uint256 p) external {
        price = p;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function request(bytes32, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId)
    {
        require(amount >= price, "PriceNotMet");
        require(callback.target == msg.sender, "callback target");
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        requests += 1;
        lastBody = body;
        requestId = keccak256(abi.encode(requests, body));
        lastRequestId = requestId;
    }

    function deliver(
        address target,
        bytes32 requestId,
        OracleAttestation.Attestation calldata a,
        bytes calldata sig
    ) external returns (bool ok) {
        (ok,) = target.call{gas: 200_000}(abi.encodeCall(MarginaliaPages.onOracleResult, (requestId, a, sig)));
    }
}

/// @dev Stands in for identity.md's settled WhitelistCurator at its mainnet address (etched by the test).
contract MockWhitelist {
    mapping(address => uint256) public contributedBy;

    function set(address who, uint256 v) external {
        contributedBy[who] = v;
    }
}

/// @dev Stands in for the Annex's record (score, posted, ...): the third buy gate.
contract MockAnnexRecords {
    mapping(address => uint32) public postedOf;

    function set(address who, uint32 n) external {
        postedOf[who] = n;
    }

    function records(address wallet) external view returns (int256, uint32, uint32, uint32, uint32, uint32) {
        return (0, postedOf[wallet], 0, 0, 0, 0);
    }
}

/// @dev The page market against the local hook: the capped curve, fee split (issuer / MARG burn / pools), the
/// per-wallet limit, the buy gate (whitelist / MARG / notes), handle escrow, oracle-attested claims, abandonment,
/// recycling, and that pages never move.
abstract contract PagesFixture is Fixture {
    MarginaliaPages pages;
    ClaimIntake intake;
    MockWhitelist whitelist;
    MockAnnexRecords annexRecords;
    uint256 constant SIGNER_KEY = 0x5E7;
    bytes32 constant ACTION = bytes32("oracle.request@oracle-1");
    address signerAddr;
    address dave = makeAddr("dave"); // funded with IMD only: no MARG, no notes, not listed

    function setUp() public {
        _setup();
        signerAddr = vm.addr(SIGNER_KEY);
        intake = new ClaimIntake();
        annexRecords = new MockAnnexRecords();
        pages = new MarginaliaPages(
            IMarginaliaHookPages(address(hook)),
            IMarginaliaRecords(address(annexRecords)),
            intake,
            ACTION,
            signerAddr
        );
        whitelist = new MockWhitelist();
        vm.etch(pages.WHITELIST(), address(whitelist).code);
        whitelist = MockWhitelist(pages.WHITELIST());
        _fundCarol();
        imd.transfer(dave, 1_000_000 ether);
        address[4] memory who = [alice, bob, carol, dave];
        for (uint256 i = 0; i < 4; ++i) {
            vm.prank(who[i]);
            imd.approve(address(pages), type(uint256).max);
        }
        // alice and bob hold 100,000 MARG from the fixture: above the 10,000 gate. carol and dave hold none.
    }

    function _pools() internal view returns (uint256) {
        return hook.refundPool(hook.today()) + hook.thesisPool(hook.week());
    }

    /// @dev A fresh wallet that passes the MARG gate, funded for `n` pages at any price.
    function _reader(uint256 i) internal returns (address r) {
        r = makeAddr(string(abi.encodePacked("reader", vm.toString(i))));
        imd.transfer(r, 1_000 ether);
        token.transfer(r, pages.MARG_GATE());
        vm.prank(r);
        imd.approve(address(pages), type(uint256).max);
    }

    function _att(bytes32 requestId, address wallet)
        internal
        view
        returns (OracleAttestation.Attestation memory a)
    {
        a.requestId = requestId;
        a.chainId = block.chainid;
        a.questionHash = keccak256("question");
        a.answerType = OracleAttestation.ANSWER_ADDRESS;
        a.answer = abi.encode(wallet);
        a.fromBlock = 1;
        a.toBlock = 2;
        a.blockHash = keccak256("block");
        a.panelJobId = keccak256("job");
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 5;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 days);
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, pages.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _twentyOf(bytes32 subject) internal {
        vm.prank(alice);
        pages.buy(subject, 10, type(uint256).max);
        vm.prank(bob);
        pages.buy(subject, 10, type(uint256).max);
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i + n.length <= h.length; ++i) {
            bool hit = true;
            for (uint256 j = 0; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }
}

contract PagesTest is PagesFixture {
    // ------------------------------------------------------------------ curve and fees

    function testCurveIsLinearThenCapped() public view {
        assertEq(pages.priceOf(0, 1), 0.05 ether);
        assertEq(pages.priceOf(1, 1), 0.1 ether);
        assertEq(pages.priceOf(0, 3), 0.3 ether); // 0.05 + 0.1 + 0.15
        assertEq(pages.priceOf(99, 1), 5 ether); // the 100th page
        assertEq(pages.priceOf(199, 1), 10 ether); // the 200th page reaches the cap
        assertEq(pages.priceOf(200, 1), 10 ether); // and every page after costs the cap
        assertEq(pages.priceOf(1000, 1), 10 ether);
        assertEq(pages.priceOf(0, 200), 1005 ether); // the whole line: 0.05 * 200 * 201 / 2
        assertEq(pages.priceOf(0, 201), 1015 ether);
        assertEq(pages.priceOf(195, 10), 99.5 ether); // pages 196..200 on the line (49.5) + five at the cap (50)
        assertEq(pages.priceOf(300, 5), 50 ether);
        assertEq(pages.priceOf(10, 0), 0);
        assertEq(pages.CAP_PAGE() * pages.BASE(), pages.CAP(), "the cap page is where the line meets the cap");
    }

    function testBuyPaysTheIssuerBurnsMargAndFundsThePools() public {
        bytes32 subject = pages.subjectOf(carol);
        (uint256 value, uint256 fee) = pages.buyPrice(subject, 3);
        assertEq(value, 0.3 ether);
        assertEq(fee, 0.03 ether);
        uint256 carolBefore = imd.balanceOf(carol);
        uint256 poolsBefore = _pools();
        uint256 deadBefore = token.balanceOf(pages.DEAD());
        uint256 aliceBefore = imd.balanceOf(alice);
        vm.prank(alice);
        pages.buy(subject, 3, value + fee);
        assertEq(aliceBefore - imd.balanceOf(alice), value + fee);
        assertEq(pages.pagesOf(subject, alice), 3);
        assertEq(pages.reserveOf(subject), value, "the curve reserve holds the value, never the fee");
        assertEq(imd.balanceOf(carol) - carolBefore, fee * 8000 / 10_000, "80% of the fee to the issuer");
        assertEq(_pools() - poolsBefore, fee * 1000 / 10_000, "10% of the fee to the pools");
        assertGt(token.balanceOf(pages.DEAD()) - deadBefore, 0, "10% of the fee bought MARG and burned it");
        assertEq(imd.balanceOf(address(pages)), value, "the contract holds exactly the reserve");
    }

    function testSellReturnsTheCurveLessFeeAndPagesAreNotTransferable() public {
        bytes32 subject = pages.subjectOf(carol);
        vm.prank(alice);
        pages.buy(subject, 5, type(uint256).max);
        vm.prank(bob);
        pages.buy(subject, 2, type(uint256).max);
        (uint256 value, uint256 fee) = pages.sellPrice(subject, 2);
        assertEq(value, 0.65 ether); // the top two prices, 0.35 + 0.3
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        pages.sell(subject, 2, value - fee);
        assertEq(imd.balanceOf(alice) - before, value - fee);
        assertEq(pages.pagesOf(subject, alice), 3);
        (uint64 supply,,,) = pages.subjects(subject);
        assertEq(supply, 5);
        vm.prank(bob);
        vm.expectRevert(MarginaliaPages.InsufficientPages.selector);
        pages.sell(subject, 3, 0);
        (uint256 all,) = pages.sellPrice(subject, 5);
        assertEq(pages.reserveOf(subject), all, "the reserve always covers every holder selling out");
    }

    /// @dev Ten pages per wallet per writer; the cap is reached by many wallets, never cornered by one; the
    /// reserve covers a full sell-out at any depth, including pages bought at the cap.
    function testPerWalletLimitAndTheCap() public {
        bytes32 subject = pages.subjectOf(carol);
        (uint256 value, uint256 fee) = pages.buyPrice(subject, 1);
        vm.prank(alice);
        vm.expectRevert(MarginaliaPages.Slippage.selector);
        pages.buy(subject, 1, value + fee - 1);
        vm.prank(alice);
        pages.buy(subject, 10, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(MarginaliaPages.TooManyPages.selector);
        pages.buy(subject, 1, type(uint256).max);
        // twenty more readers take the room to 210 pages: the last ten are at the cap
        address last;
        for (uint256 i = 0; i < 20; ++i) {
            last = _reader(i);
            vm.prank(last);
            pages.buy(subject, 10, type(uint256).max);
        }
        (uint64 supply,,,) = pages.subjects(subject);
        assertEq(supply, 210);
        (value, fee) = pages.buyPrice(subject, 1);
        assertEq(value, 10 ether, "the 211th page costs the cap");
        assertEq(fee, 1 ether);
        (uint256 all,) = pages.sellPrice(subject, 210);
        assertEq(pages.reserveOf(subject), all, "the reserve covers every holder selling out at any depth");
        assertEq(all, pages.priceOf(0, 210));
        // a cap-priced page sells back for the cap less the fee
        uint256 before = imd.balanceOf(last);
        vm.prank(last);
        pages.sell(subject, 1, 0);
        assertEq(imd.balanceOf(last) - before, 9 ether);
    }

    // ------------------------------------------------------------------ the buy gate

    function testBuyGateWhitelistMargOrNotes() public {
        bytes32 subject = pages.subjectOf(carol);
        assertFalse(pages.eligible(dave));
        vm.prank(dave);
        vm.expectRevert(MarginaliaPages.NotEligible.selector);
        pages.buy(subject, 1, type(uint256).max);
        // the whitelist
        whitelist.set(dave, 1);
        assertTrue(pages.eligible(dave));
        vm.prank(dave);
        pages.buy(subject, 1, type(uint256).max);
        whitelist.set(dave, 0);
        assertFalse(pages.eligible(dave));
        // MARG held: 9,999 is not enough, 10,000 is
        uint256 gate = pages.MARG_GATE();
        token.transfer(dave, gate - 1);
        assertFalse(pages.eligible(dave));
        token.transfer(dave, 1);
        assertTrue(pages.eligible(dave));
        vm.prank(dave);
        token.transfer(address(1), gate);
        assertEq(token.balanceOf(dave), 0);
        assertFalse(pages.eligible(dave));
        // a note on the annex
        annexRecords.set(dave, 1);
        assertTrue(pages.eligible(dave));
        annexRecords.set(dave, 0);
        assertFalse(pages.eligible(dave));
        // a note on the hook: carol posts through the router (she holds no MARG beyond the note's own buy)
        assertFalse(pages.eligible(carol));
        _note(carol, _margNote(T.Side.Buy, 12_000, 3, "carol writes"), 1 ether);
        assertTrue(pages.eligible(carol));
        // selling is never gated: dave lost every gate but still holds a page
        assertFalse(pages.eligible(dave));
        vm.prank(dave);
        pages.sell(subject, 1, 0);
        assertEq(pages.pagesOf(subject, dave), 0);
    }

    function testAnnexLegIsOffWhenUnset() public {
        MarginaliaPages p2 = new MarginaliaPages(
            IMarginaliaHookPages(address(hook)), IMarginaliaRecords(address(0)), intake, ACTION, signerAddr
        );
        annexRecords.set(dave, 1);
        assertFalse(p2.eligible(dave), "no annex: the leg is off");
        assertTrue(p2.eligible(alice), "MARG still gates");
    }

    // ------------------------------------------------------------------ handles

    function testHandleIsLowerCasedAndValidated() public {
        assertEq(pages.subjectOfHandle("BlkNoiz06"), pages.subjectOfHandle("blknoiz06"));
        assertEq(pages.subjectOfHandle("a_B9"), keccak256(abi.encodePacked("x:", "a_b9")));
        vm.expectRevert(MarginaliaPages.BadHandle.selector);
        pages.subjectOfHandle("@blknoiz06");
        vm.expectRevert(MarginaliaPages.BadHandle.selector);
        pages.subjectOfHandle("");
        vm.expectRevert(MarginaliaPages.BadHandle.selector);
        pages.subjectOfHandle("sixteen_chars_xx");
        vm.expectRevert(MarginaliaPages.BadHandle.selector);
        pages.subjectOfHandle("no spaces");
    }

    /// @dev Twenty pages of a handle from two wallets (the per-wallet limit): enough escrow to cover the price.

    /// @dev Pages of an unclaimed handle escrow the issuer's share; the panel's answer names the wallet, which
    /// collects the escrow less the oracle price reimbursed to whoever asked, and is paid from then on.
    function testEscrowThenOracleAttestedClaim() public {
        bytes32 subject = pages.registerHandle("blknoiz06");
        assertEq(pages.payeeOf(subject), address(0));
        uint64 firstBuy = uint64(vm.getBlockTimestamp());
        _twentyOf(subject); // 10.5 IMD of pages → 1.05 fee → 0.84 escrow, above the oracle price
        (uint64 supply, address payee, uint256 escrow, uint64 since) = pages.subjects(subject);
        assertEq(supply, 20);
        assertEq(payee, address(0));
        assertEq(escrow, pages.priceOf(0, 20) * 1000 / 10_000 * 8000 / 10_000);
        assertGt(escrow, 0.5 ether);
        assertEq(since, firstBuy);
        // carol (the handle's owner) asks, paying the price up front
        uint256 carolBefore = imd.balanceOf(carol);
        vm.prank(carol);
        bytes32 requestId = pages.requestClaim("BlkNoiz06", 2109295512424009991);
        assertEq(carolBefore - imd.balanceOf(carol), 0.5 ether, "the claimant fronts the oracle price");
        assertEq(intake.requests(), 1);
        string memory body = string(intake.lastBody());
        assertTrue(_contains(body, "tweet-result?id=2109295512424009991&token=a"), "the body names the tweet");
        assertTrue(_contains(body, "is exactly blknoiz06 then"), "the body names the normalized handle");
        assertTrue(_contains(body, '"answerType":"address"'));
        assertTrue(_contains(body, '"guards":{"sources":["https://cdn.syndication.twimg.com/"]}'));
        (bytes32 rid, address claimant, uint256 price, uint64 at) = pages.claims(subject);
        assertEq(rid, requestId);
        assertEq(claimant, carol);
        assertEq(price, 0.5 ether);
        assertEq(at, vm.getBlockTimestamp());
        // a second request for the same subject waits for the first
        vm.prank(bob);
        vm.expectRevert(MarginaliaPages.ClaimPending.selector);
        pages.requestClaim("blknoiz06", 1);
        // the panel answers carol's wallet
        OracleAttestation.Attestation memory a = _att(requestId, carol);
        bool ok = intake.deliver(address(pages), requestId, a, _sign(a));
        assertTrue(ok, "the callback fits the Intake's 200k stipend");
        assertEq(pages.payeeOf(subject), carol);
        assertEq(
            imd.balanceOf(carol) - carolBefore,
            escrow - 0.5 ether,
            "the owner nets the escrow less the oracle price, which the escrow paid"
        );
        (rid,,,) = pages.claims(subject);
        assertEq(rid, bytes32(0), "the claim is closed");
        assertTrue(pages.consumed(a.requestId));
        // replaying the same signed answer is refused
        ok = intake.deliver(address(pages), requestId, a, _sign(a));
        assertFalse(ok, "callback replay");
        // the next trade pays carol directly
        (, uint256 fee2) = pages.buyPrice(subject, 1);
        uint256 before = imd.balanceOf(carol);
        address r = _reader(99);
        vm.prank(r);
        pages.buy(subject, 1, type(uint256).max);
        assertEq(imd.balanceOf(carol) - before, fee2 * 8000 / 10_000);
        // and a claimed handle cannot be asked about again
        vm.prank(bob);
        vm.expectRevert(MarginaliaPages.AlreadyClaimed.selector);
        pages.requestClaim("blknoiz06", 1);
    }

    /// @dev A stranger's bogus claim costs the stranger: the panel answers zero, the escrow is untouched, the
    /// handle can be asked about again at once, and a third party who asks correctly is reimbursed from escrow.
    function testBogusClaimCostsOnlyTheClaimantAndIsRetriable() public {
        bytes32 subject = pages.registerHandle("ghost");
        _twentyOf(subject); // escrow 0.84 IMD, above the oracle price
        (,, uint256 escrow,) = pages.subjects(subject);
        uint256 bobBefore = imd.balanceOf(bob);
        vm.prank(bob);
        bytes32 requestId = pages.requestClaim("ghost", 42);
        OracleAttestation.Attestation memory a = _att(requestId, address(0));
        assertTrue(intake.deliver(address(pages), requestId, a, _sign(a)));
        assertEq(pages.payeeOf(subject), address(0));
        (,, uint256 escrowAfter,) = pages.subjects(subject);
        assertEq(escrowAfter, escrow, "a failed claim never touches the escrow");
        assertEq(bobBefore - imd.balanceOf(bob), 0.5 ether, "the bogus claimant paid the oracle");
        // retry at once, by a third party on the owner's behalf: the third party is reimbursed, carol is paid
        bobBefore = imd.balanceOf(bob);
        uint256 carolBefore = imd.balanceOf(carol);
        vm.prank(bob);
        requestId = pages.requestClaim("ghost", 43);
        a = _att(requestId, carol);
        assertTrue(intake.deliver(address(pages), requestId, a, _sign(a)));
        assertEq(pages.payeeOf(subject), carol);
        assertEq(imd.balanceOf(bob), bobBefore, "the asker got the price back from the escrow");
        assertEq(
            imd.balanceOf(carol) - carolBefore, escrow - 0.5 ether, "the owner nets the escrow less the price"
        );
    }

    /// @dev Tiny escrow: the price is not reimbursed and the owner gets what is there.
    function testSmallEscrowIsPaidWithoutReimbursement() public {
        bytes32 subject = pages.registerHandle("tiny");
        vm.prank(alice);
        pages.buy(subject, 1, type(uint256).max); // 0.05 IMD value → 0.005 fee → 0.004 escrow
        (,, uint256 escrow,) = pages.subjects(subject);
        assertLt(escrow, 0.5 ether);
        uint256 carolBefore = imd.balanceOf(carol);
        vm.prank(carol);
        bytes32 requestId = pages.requestClaim("tiny", 7);
        OracleAttestation.Attestation memory a = _att(requestId, carol);
        assertTrue(intake.deliver(address(pages), requestId, a, _sign(a)));
        assertEq(imd.balanceOf(carol), carolBefore - 0.5 ether + escrow);
    }

    /// @dev Bad answers are refused without closing the claim: wrong signer, wrong chain, thin panel, wrong type,
    /// an unknown request, a caller that is not the Intake, and an expired attestation.
    function testRejectedAnswersDoNotCloseTheClaim() public {
        bytes32 subject = pages.registerHandle("strict");
        vm.prank(alice);
        pages.buy(subject, 2, type(uint256).max);
        vm.prank(carol);
        bytes32 requestId = pages.requestClaim("strict", 9);
        OracleAttestation.Attestation memory a = _att(requestId, carol);
        bytes memory sig = _sign(a);
        // not the intake
        vm.expectRevert(MarginaliaPages.OnlyIntake.selector);
        pages.onOracleResult(requestId, a, sig);
        // tampered after signing
        a.figure = 1;
        assertFalse(intake.deliver(address(pages), requestId, a, sig));
        a.figure = 0;
        // wrong chain
        a.chainId = 999;
        assertFalse(intake.deliver(address(pages), requestId, a, _sign(a)));
        a.chainId = block.chainid;
        // thin panel / no agreement
        a.panelSize = 2;
        a.quorum = 2;
        a.agreed = 2;
        assertFalse(intake.deliver(address(pages), requestId, a, _sign(a)));
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 3;
        assertFalse(intake.deliver(address(pages), requestId, a, _sign(a)));
        a.agreed = 5;
        // wrong answer type
        a.answerType = OracleAttestation.ANSWER_BYTES32;
        a.answer = abi.encode(bytes32(uint256(uint160(carol))));
        assertFalse(intake.deliver(address(pages), requestId, a, _sign(a)));
        a.answerType = OracleAttestation.ANSWER_ADDRESS;
        a.answer = abi.encode(carol);
        // unknown request id
        assertFalse(intake.deliver(address(pages), keccak256("other"), a, _sign(a)));
        // expired
        a.expiresAt = uint64(vm.getBlockTimestamp() - 1);
        assertFalse(intake.deliver(address(pages), requestId, a, _sign(a)));
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 days);
        // the claim is still open and a good answer still lands
        (bytes32 rid,,,) = pages.claims(subject);
        assertEq(rid, requestId);
        assertTrue(intake.deliver(address(pages), requestId, a, _sign(a)));
        assertEq(pages.payeeOf(subject), carol);
    }

    /// @dev An unanswered claim is abandoned after the deadline, a late delivery is then refused, and the
    /// subject can be asked about again. Recycling waits for a pending claim.
    function testAbandonAfterDeadlineAndRecycleWaitsForPendingClaims() public {
        bytes32 subject = pages.registerHandle("quiet");
        vm.prank(alice);
        pages.buy(subject, 4, type(uint256).max);
        (,, uint256 escrow,) = pages.subjects(subject);
        vm.prank(carol);
        bytes32 requestId = pages.requestClaim("quiet", 5);
        vm.expectRevert(MarginaliaPages.TooEarly.selector);
        pages.abandonClaim(subject);
        // 90 days pass with the claim still open: no recycling over a live claim
        vm.warp(vm.getBlockTimestamp() + pages.CLAIM_WINDOW());
        vm.expectRevert(MarginaliaPages.ClaimPending.selector);
        pages.recycle(subject);
        pages.abandonClaim(subject);
        OracleAttestation.Attestation memory a = _att(requestId, carol);
        assertFalse(intake.deliver(address(pages), requestId, a, _sign(a)), "a late delivery is refused");
        assertEq(pages.payeeOf(subject), address(0));
        // now recycling works, and a later claim still works, it just has no escrow left
        uint256 poolsBefore = _pools();
        pages.recycle(subject);
        assertEq(_pools() - poolsBefore, escrow);
        vm.expectRevert(MarginaliaPages.NothingToRecycle.selector);
        pages.recycle(subject);
        vm.prank(carol);
        requestId = pages.requestClaim("quiet", 6);
        a = _att(requestId, carol);
        assertTrue(intake.deliver(address(pages), requestId, a, _sign(a)));
        assertEq(pages.payeeOf(subject), carol);
    }

    function testPriceGuardAndAddressSubjectsNeedNoClaim() public {
        intake.setPrice(2 ether);
        vm.prank(carol);
        vm.expectRevert(MarginaliaPages.PriceMismatch.selector);
        pages.requestClaim("pricey", 1);
        intake.setPrice(0);
        vm.prank(carol);
        vm.expectRevert(MarginaliaPages.PriceMismatch.selector);
        pages.requestClaim("pricey", 1);
        assertEq(pages.payeeOf(pages.subjectOf(carol)), carol);
    }

    function testOnlyThePoolManagerMayCallBack() public {
        vm.expectRevert(MarginaliaPages.UnauthorizedCallback.selector);
        pages.unlockCallback(abi.encode(uint256(1)));
    }
}
