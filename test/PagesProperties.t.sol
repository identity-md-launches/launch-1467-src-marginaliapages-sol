// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PagesFixture} from "./Pages.t.sol";
import {MarginaliaPages, IMarginaliaHookPages, IMarginaliaRecords} from "src/MarginaliaPages.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/OracleAttestation.sol";
import {IIntake} from "src/interfaces/IIntake.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev Checks the actual request envelope and exact allowance before pulling payment. The failure modes
/// deliberately happen AFTER the pull, so the tests exercise transaction-wide rollback as well as guards.
contract PagesIntakeProbe is IIntake {
    uint256 public price = 0.5 ether;
    bytes32 public nextId = keccak256("probe request");
    bool public failRequest;
    uint256 public requests;
    bytes public body;
    address public assetSeen;
    bytes32 public actionSeen;
    Callback public callbackSeen;

    error Refused();

    function configure(uint256 p, bytes32 id, bool fail) external {
        price = p;
        nextId = id;
        failRequest = fail;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function request(
        bytes32 action,
        bytes calldata question,
        Callback calldata callback,
        address asset,
        uint256 amount
    ) external payable returns (bytes32) {
        require(msg.value == 0, "native value");
        require(amount == price, "not the current price");
        require(IERC20(asset).allowance(msg.sender, address(this)) == amount, "excess allowance");
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount), "payment");
        if (failRequest) revert Refused();
        requests++;
        body = question;
        assetSeen = asset;
        actionSeen = action;
        callbackSeen = callback;
        return nextId;
    }
}

/// @notice Supplemental properties and rejection tests; the original 14-test integration suite stays intact.
/// forge-config: default.fuzz.runs = 1000
contract PagesPropertiesTest is PagesFixture {
    /// @dev Independent, deliberately slow oracle: add each marginal price, rather than using the
    /// production implementation's triangular sum and flat-tail decomposition.
    function _sum(uint256 supply, uint256 amount) internal pure returns (uint256 total) {
        for (uint256 i = 1; i <= amount; ++i) {
            uint256 marginal = (supply + i) * 0.05 ether;
            total += marginal > 10 ether ? 10 ether : marginal;
        }
    }

    function testFuzzPriceMatchesMarginalSum(uint64 start, uint16 quantity) public view {
        uint256 amount = bound(quantity, 0, 420);
        assertEq(pages.priceOf(start, amount), _sum(start, amount));
    }

    function testFuzzPricePartitionAcrossCap(uint16 start, uint16 left, uint16 right) public view {
        uint256 supply = bound(start, 0, 220);
        uint256 a = bound(left, 0, 220);
        uint256 b = bound(right, 0, 220);
        assertEq(pages.priceOf(supply, a + b), pages.priceOf(supply, a) + pages.priceOf(supply + a, b));
        assertLe(pages.priceOf(supply, a + b), (a + b) * 10 ether);
    }

    function testCurveEdgesAndUint64SupplyRemainQuoted() public view {
        assertEq(pages.priceOf(198, 3), 29.95 ether);
        assertEq(pages.priceOf(199, 2), 20 ether);
        assertEq(pages.priceOf(200, 10), 100 ether);
        assertEq(pages.priceOf(0, 210), 1105 ether);
        assertEq(pages.priceOf(type(uint64).max, 10), 100 ether);
        assertEq(pages.priceOf(type(uint256).max, 0), 0);
    }

    function testFuzzRepeatedRoundTripsLoseExactlyTwoFees(uint8 quantity, uint8 repetitions, bool selfIssuer)
        public
    {
        uint256 amount = bound(quantity, 1, 10);
        uint256 cycles = bound(repetitions, 1, 12);
        bytes32 subject = pages.subjectOf(selfIssuer ? alice : carol);
        uint256 before = imd.balanceOf(alice);
        uint256 value = _sum(0, amount);
        uint256 oneFee = value / 10;
        for (uint256 i; i < cycles; ++i) {
            vm.startPrank(alice);
            pages.buy(subject, amount, value + oneFee);
            pages.sell(subject, amount, value - oneFee);
            vm.stopPrank();
        }
        uint256 loss = cycles * 2 * oneFee;
        if (selfIssuer) loss = loss * 2 / 10; // issuer recovers 80% of both fees, never the other 20%
        assertEq(before - imd.balanceOf(alice), loss);
        assertEq(pages.pagesOf(subject, alice), 0);
        (uint64 supply,,,) = pages.subjects(subject);
        assertEq(supply, 0);
        assertEq(pages.reserveOf(subject), 0);
        assertEq(imd.balanceOf(address(pages)), 0);
    }

    function _state(bytes32 subject) internal view returns (bytes32) {
        (uint64 supply, address payee, uint256 escrow, uint64 since) = pages.subjects(subject);
        return keccak256(
            abi.encode(
                supply,
                payee,
                escrow,
                since,
                pages.reserveOf(subject),
                pages.pendingBurn(),
                pages.pagesOf(subject, alice),
                pages.pagesOf(subject, bob),
                imd.balanceOf(alice),
                imd.balanceOf(bob),
                imd.balanceOf(carol),
                imd.balanceOf(address(pages)),
                token.balanceOf(pages.DEAD()),
                _pools()
            )
        );
    }

    function testRejectedTradesAreAtomicAndLimitsArePerSubject() public {
        bytes32 subject = pages.registerHandle("atomic");
        bytes32 before = _state(subject);
        vm.startPrank(alice);
        vm.expectRevert(MarginaliaPages.ZeroAmount.selector);
        pages.buy(subject, 0, 0);
        vm.expectRevert(MarginaliaPages.ZeroAmount.selector);
        pages.sell(subject, 0, 0);
        vm.expectRevert(MarginaliaPages.TooManyPages.selector);
        pages.buy(subject, 11, type(uint256).max);
        vm.expectRevert(MarginaliaPages.InsufficientPages.selector);
        pages.sell(subject, 1, 0);
        vm.expectRevert(MarginaliaPages.Slippage.selector);
        pages.buy(subject, 1, 0.055 ether - 1);
        vm.stopPrank();
        assertEq(_state(subject), before);
        vm.prank(alice);
        pages.buy(subject, 10, 3.025 ether);
        before = _state(subject);
        vm.startPrank(alice);
        vm.expectRevert(MarginaliaPages.TooManyPages.selector);
        pages.buy(subject, 1, type(uint256).max);
        vm.expectRevert(MarginaliaPages.Slippage.selector);
        pages.sell(subject, 1, 0.45 ether + 1);
        vm.stopPrank();
        assertEq(_state(subject), before);
        vm.prank(alice);
        pages.sell(subject, 1, 0.45 ether);
        vm.prank(alice);
        pages.buy(subject, 1, 0.55 ether);
        assertEq(pages.pagesOf(subject, alice), 10);
        bytes32 second = pages.subjectOf(carol);
        vm.prank(alice);
        pages.buy(second, 10, 3.025 ether);
        assertEq(pages.pagesOf(second, alice), 10);
        assertEq(pages.pagesOf(subject, alice), 10);
    }

    function testNoAllowanceOrBalanceCannotMintPages() public {
        bytes32 subject = pages.subjectOf(carol);
        vm.prank(alice);
        imd.approve(address(pages), 0);
        bytes32 before = _state(subject);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(pages), 0, 0.055 ether
            )
        );
        pages.buy(subject, 1, 1 ether);
        assertEq(_state(subject), before);
        address empty = makeAddr("eligible but no IMD");
        whitelist.set(empty, 1);
        vm.startPrank(empty);
        imd.approve(address(pages), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, empty, 0, 0.055 ether)
        );
        pages.buy(subject, 1, 1 ether);
        vm.stopPrank();
        assertEq(_state(subject), before);
        assertEq(pages.pagesOf(subject, empty), 0);
    }

    function testRevertingIssuerPaymentRollsBackSell() public {
        bytes32 subject = pages.subjectOf(carol);
        vm.prank(alice);
        pages.buy(subject, 3, 0.33 ether);
        bytes32 before = _state(subject);
        bytes memory failure = abi.encodeWithSignature("IssuerTransferFailed()");
        vm.mockCallRevert(address(imd), abi.encodeCall(IERC20.transfer, (carol, 0.012 ether)), failure);
        vm.prank(alice);
        vm.expectRevert(failure);
        pages.sell(subject, 1, 0);
        assertEq(_state(subject), before);
        vm.clearMockedCalls();
        vm.prank(alice);
        pages.sell(subject, 1, 0.135 ether);
        assertEq(pages.pagesOf(subject, alice), 2);
    }

    function testTransferAndApprovalSelectorsCannotMovePages() public {
        bytes32 subject = pages.subjectOf(carol);
        vm.prank(alice);
        pages.buy(subject, 2, 1 ether);
        bytes32 before = _state(subject);
        bytes[] memory attempts = new bytes[](5);
        attempts[0] = abi.encodeWithSignature("transfer(address,uint256)", bob, 1);
        attempts[1] = abi.encodeWithSignature("transferFrom(address,address,uint256)", alice, bob, 1);
        attempts[2] = abi.encodeWithSignature(
            "safeTransferFrom(address,address,uint256,uint256,bytes)",
            alice,
            bob,
            uint256(subject),
            1,
            bytes("")
        );
        attempts[3] = abi.encodeWithSignature("setApprovalForAll(address,bool)", bob, true);
        attempts[4] = abi.encodeWithSignature("approve(address,uint256)", bob, 1);
        for (uint256 i; i < attempts.length; ++i) {
            vm.prank(alice);
            (bool ok,) = address(pages).call(attempts[i]);
            assertFalse(ok, "pages unexpectedly implement transfer/approval");
        }
        assertEq(_state(subject), before);
    }

    function testFuzzEveryHandleByteIsValidated(uint8 c, uint8 lengthSeed, uint8 positionSeed) public {
        uint256 length = bound(lengthSeed, 1, 15);
        uint256 position = bound(positionSeed, 0, length - 1);
        bytes memory candidate = new bytes(length);
        for (uint256 i; i < length; ++i) {
            candidate[i] = "a";
        }
        candidate[position] = bytes1(c);
        bytes memory alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_";
        bytes memory lower = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz0123456789_";
        bool allowed;
        bytes1 expectedByte;
        for (uint256 i; i < alphabet.length; ++i) {
            if (bytes1(c) == alphabet[i]) {
                allowed = true;
                expectedByte = lower[i];
                break;
            }
        }
        if (!allowed) {
            vm.expectRevert(MarginaliaPages.BadHandle.selector);
            pages.registerHandle(string(candidate));
            return;
        }
        string memory normalized = pages.normalizeHandle(string(candidate));
        bytes memory expected = new bytes(length);
        for (uint256 i; i < length; ++i) {
            expected[i] = i == position ? expectedByte : bytes1("a");
        }
        assertEq(normalized, string(expected));
        assertEq(pages.normalizeHandle(normalized), normalized);
        assertEq(pages.subjectOfHandle(normalized), pages.subjectOfHandle(string(candidate)));
        bytes32 subject = pages.registerHandle(string(candidate));
        assertEq(pages.registerHandle(normalized), subject);
        assertEq(pages.payeeOf(subject), address(0));
        (uint64 supply,, uint256 escrow, uint64 since) = pages.subjects(subject);
        assertEq(supply, 0);
        assertEq(escrow, 0);
        assertEq(since, 0);
    }

    function testHandleLengthBoundariesUseBytes() public {
        assertEq(pages.normalizeHandle("A"), "a");
        assertEq(pages.normalizeHandle("ABCDEFGHIJKLMNO"), "abcdefghijklmno");
        vm.expectRevert(MarginaliaPages.BadHandle.selector);
        pages.registerHandle("abcdefghijklmnop"); // actually sixteen bytes
        vm.expectRevert(MarginaliaPages.BadHandle.selector);
        pages.registerHandle(unicode"caf\u00e9");
    }

    function _probe(PagesIntakeProbe probe) internal returns (MarginaliaPages p) {
        p = new MarginaliaPages(
            IMarginaliaHookPages(address(hook)),
            IMarginaliaRecords(address(annexRecords)),
            probe,
            ACTION,
            signerAddr
        );
        vm.prank(alice);
        imd.approve(address(p), type(uint256).max);
    }

    function testFuzzRequestPaysOnlyCurrentPriceAndClearsAllowance(uint96 priceSeed) public {
        uint256 price = bound(priceSeed, 1, 1 ether);
        PagesIntakeProbe probe = new PagesIntakeProbe();
        probe.configure(price, keccak256("paid request"), false);
        MarginaliaPages p = _probe(probe);
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        bytes32 id = p.requestClaim("EnVeLoPe", type(uint256).max);
        assertEq(id, keccak256("paid request"));
        assertEq(imd.balanceOf(alice), before - price);
        assertEq(imd.balanceOf(address(probe)), price);
        assertEq(imd.balanceOf(address(p)), 0);
        assertEq(imd.allowance(address(p), address(probe)), 0);
        assertEq(probe.actionSeen(), ACTION);
        assertEq(probe.assetSeen(), address(imd));
        (address target, bytes4 selector) = probe.callbackSeen();
        assertEq(target, address(p));
        assertEq(selector, p.onOracleResult.selector);
        assertEq(probe.body(), bytes(p.questionBody("envelope", type(uint256).max)));
        (bytes32 pending, address asker, uint256 paid, uint64 at) = p.claims(p.subjectOfHandle("envelope"));
        assertEq(pending, id);
        assertEq(asker, alice);
        assertEq(paid, price);
        assertEq(at, vm.getBlockTimestamp());
    }

    function testIntakeFailureZeroAndCollidingIdsRollBackPayment() public {
        PagesIntakeProbe probe = new PagesIntakeProbe();
        MarginaliaPages p = _probe(probe);
        uint256 before = imd.balanceOf(alice);
        probe.configure(0.5 ether, keccak256("id"), true);
        vm.prank(alice);
        vm.expectRevert(PagesIntakeProbe.Refused.selector);
        p.requestClaim("failure", 1);
        assertEq(imd.balanceOf(alice), before);
        assertEq(probe.requests(), 0);
        probe.configure(0.5 ether, bytes32(0), false);
        vm.prank(alice);
        vm.expectRevert(MarginaliaPages.ClaimPending.selector);
        p.requestClaim("failure", 1);
        assertEq(imd.balanceOf(alice), before);
        assertEq(probe.requests(), 0);
        probe.configure(0.5 ether, keccak256("id"), false);
        vm.prank(alice);
        p.requestClaim("first", 1);
        vm.prank(alice);
        vm.expectRevert(MarginaliaPages.ClaimPending.selector);
        p.requestClaim("second", 2);
        assertEq(imd.balanceOf(alice), before - 0.5 ether);
        assertEq(probe.requests(), 1);
        assertEq(imd.balanceOf(address(probe)), 0.5 ether);
        assertEq(imd.allowance(address(p), address(probe)), 0);
        (bytes32 pending,,,) = p.claims(p.subjectOfHandle("second"));
        assertEq(pending, bytes32(0));
        (pending,,,) = p.claims(p.subjectOfHandle("first"));
        assertEq(pending, keccak256("id"));
    }

    function testOraclePriceCeilingIsInclusive() public {
        uint256 before = imd.balanceOf(alice);
        intake.setPrice(1 ether + 1);
        vm.prank(alice);
        vm.expectRevert(MarginaliaPages.PriceMismatch.selector);
        pages.requestClaim("pricebound", 1);
        assertEq(imd.balanceOf(alice), before);
        intake.setPrice(1 ether);
        vm.prank(alice);
        pages.requestClaim("pricebound", 2);
        assertEq(imd.balanceOf(alice), before - 1 ether);
        assertEq(imd.allowance(address(pages), address(intake)), 0);
    }
}
