// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PagesFixture} from "./Pages.t.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MarginaliaPages} from "src/MarginaliaPages.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Test-only adversarial IMD behavior. Preserves MockERC20's storage layout and token accounting,
/// but attempts an armed callback when Pages pays or receives IMD. Live IMD is not assumed to have hooks.
contract PagesReentryToken is MockERC20 {
    address private target;
    bytes private payload;
    bool private inside;
    uint256 public attempts;
    bool public allRejected;

    constructor() MockERC20("probe", "PROBE", 0) {}

    function arm(address to, bytes calldata data) external {
        target = to;
        payload = data;
        allRejected = true;
        attempts = 0;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (!inside && target != address(0) && (from == target || to == target)) {
            inside = true;
            (bool ok, bytes memory reason) = target.call(payload);
            attempts++;
            if (
                ok
                    || keccak256(reason)
                        != keccak256(
                            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
                        )
            ) {
                allRejected = false;
            }
            inside = false;
        }
        super._update(from, to, value);
    }
}

contract PagesReentrancyTest is PagesFixture {
    function _payload(
        uint256 inner,
        bytes32 subject,
        bytes32 id,
        OracleAttestation.Attestation memory a,
        bytes memory sig
    ) private pure returns (bytes memory) {
        if (inner == 0) {
            return abi.encodeCall(MarginaliaPages.buy, (subject, 1, type(uint256).max));
        }
        if (inner == 1) return abi.encodeCall(MarginaliaPages.sell, (subject, 1, 0));
        if (inner == 2) return abi.encodeCall(MarginaliaPages.requestClaim, ("nested", 1));
        if (inner == 3) return abi.encodeCall(MarginaliaPages.onOracleResult, (id, a, sig));
        if (inner == 4) return abi.encodeCall(MarginaliaPages.abandonClaim, (subject));
        if (inner == 5) return abi.encodeCall(MarginaliaPages.recycle, (subject));
        return abi.encodeCall(MarginaliaPages.burn, (1, 0));
    }

    function _attempt(uint256 outer, uint256 inner) private {
        bytes32 subject = pages.registerHandle("guarded");
        _twentyOf(subject);
        whitelist.set(carol, 1);
        vm.prank(bob);
        bytes32 id = pages.requestClaim("guarded", 1);
        OracleAttestation.Attestation memory a = _att(keccak256("reentry oracle UUID"), carol);
        bytes memory sig = _sign(a);
        uint256 burnAmount;
        if (outer == 5) {
            vm.warp(vm.getBlockTimestamp() + 90 days);
            pages.abandonClaim(subject);
        } else if (outer == 6) {
            liquidity.add(key, -6000, 6000, -10_000_000 ether);
            vm.prank(carol);
            pages.buy(subject, 1, type(uint256).max);
            liquidity.add(key, -6000, 6000, 10_000_000 ether);
            burnAmount = pages.pendingBurn();
        }
        PagesReentryToken implementation = new PagesReentryToken();
        vm.etch(address(imd), address(implementation).code);
        PagesReentryToken probe = PagesReentryToken(address(imd));
        probe.arm(address(pages), _payload(inner, subject, id, a, sig));
        if (outer == 0) {
            vm.prank(carol);
            pages.buy(subject, 1, type(uint256).max);
        } else if (outer == 1) {
            vm.prank(alice);
            pages.sell(subject, 1, 0);
        } else if (outer == 2) {
            vm.prank(bob);
            pages.requestClaim("another_guard", 2);
        } else if (outer == 3) {
            // Direct delivery isolates reentrancy from the gas overhead deliberately added to the token.
            vm.prank(address(intake));
            pages.onOracleResult(id, a, sig);
        } else if (outer == 4) {
            // Pending claims may be abandoned without a token call, so drive the protected entry from
            // inside another payment instead; the nested abandonment must fail despite an elapsed deadline.
            vm.warp(vm.getBlockTimestamp() + 3 days);
            probe.arm(address(pages), abi.encodeCall(MarginaliaPages.abandonClaim, (subject)));
            vm.prank(bob);
            pages.requestClaim("abandon_probe", 3);
            (bytes32 pending,,,) = pages.claims(subject);
            assertEq(pending, id);
        } else if (outer == 5) {
            pages.recycle(subject);
        } else {
            pages.burn(burnAmount, 1);
        }
        assertGt(probe.attempts(), 0, "the malicious token callback must actually run");
        assertTrue(probe.allRejected(), "a guarded entry accepted reentry or reached its body");
        (,, uint256 escrow,) = pages.subjects(subject);
        assertEq(imd.balanceOf(address(pages)), pages.reserveOf(subject) + escrow + pages.pendingBurn());
    }

    /// @dev Exhaust the small Cartesian product instead of relying on random selection to hit each guard.
    function testAllPaymentPathsRejectEveryGuardedReentry() public {
        uint256 snapshot = vm.snapshotState();
        for (uint256 outer; outer < 7; ++outer) {
            for (uint256 inner; inner < 7; ++inner) {
                _attempt(outer, inner);
                assertTrue(vm.revertToState(snapshot));
            }
        }
    }
}
