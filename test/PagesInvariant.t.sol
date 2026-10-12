// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture, LiquidityHelper} from "./helpers/Fixture.sol";
import {ClaimIntake, MockWhitelist, MockAnnexRecords} from "./Pages.t.sol";
import {MarginaliaPages, IMarginaliaHookPages, IMarginaliaRecords} from "src/MarginaliaPages.sol";
import {MarginaliaHook} from "src/MarginaliaHook.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @dev Drives production Pages, Hook and PoolManager, with only the offchain oracle and gate sources mocked.
/// All successful operations update a separate cash-flow ledger. Unexpected reverts fail the campaign.
contract PagesHandler is Test {
    uint256 public constant ACTORS = 24;
    uint256 public constant SUBJECTS = 4;
    uint256 private constant SIGNER_KEY = 0x5E7;
    uint256 private constant BURN_UNIT = 0.0005 ether;
    MarginaliaPages public immutable pages;
    MarginaliaHook public immutable hook;
    IERC20 public immutable imd;
    IERC20 public immutable marg;
    ClaimIntake public immutable intake;
    MockWhitelist public immutable whitelist;
    MockAnnexRecords public immutable annex;
    LiquidityHelper public immutable lp;
    PoolKey private key;

    address[24] public actors;
    address[4] public writers;
    bytes32[4] public subjects;
    string[4] private handles;
    uint8[24] public gate;
    mapping(bytes32 => mapping(address => uint256)) public holdings;

    struct Model {
        uint256 supply;
        uint256 reserve;
        uint256 escrow;
        uint64 since;
        address payee;
    }

    struct Pending {
        bytes32 id;
        address asker;
        uint256 price;
        uint64 at;
    }
    mapping(bytes32 => Model) public model;
    mapping(bytes32 => Pending) public pending;
    mapping(address => uint256) public issuerPaid;
    bytes32[4] public lastClosed;
    bytes32[] private usedOracleIds;
    bool public liquid = true;
    uint256 public donated;
    uint256 public totalFees;
    uint256 public totalIssuerPaid;
    uint256 public reimbursements;
    uint256 public recycled;
    uint256 public poolsFunded;
    uint256 public burnSpent;
    uint256 public burnPending;
    uint256 public bought;
    uint256 public sold;
    uint256 public successfulAnswers;
    uint256 public zeroAnswers;
    uint256 public abandoned;
    uint256 public successfulRecycles;
    uint256 public requests;

    constructor(
        MarginaliaPages p,
        ClaimIntake i,
        MockWhitelist w,
        MockAnnexRecords a,
        LiquidityHelper l,
        PoolKey memory k
    ) {
        pages = p;
        hook = MarginaliaHook(address(p.hook()));
        imd = IERC20(hook.imd());
        marg = IERC20(hook.token());
        intake = i;
        whitelist = w;
        annex = a;
        lp = l;
        key = k;
        handles = ["", "invariant_one", "invariant_two", "invariant_three"];
        for (uint256 n; n < SUBJECTS; ++n) {
            writers[n] = makeAddr(string.concat("invariant writer ", vm.toString(n)));
            subjects[n] = n == 0 ? p.subjectOf(writers[n]) : p.registerHandle(handles[n]);
            if (n == 0) model[subjects[n]].payee = writers[n];
        }
        for (uint256 n; n < ACTORS; ++n) {
            actors[n] = makeAddr(string.concat("invariant reader ", vm.toString(n)));
            gate[n] = 1;
            w.set(actors[n], 1);
            vm.prank(actors[n]);
            imd.approve(address(p), type(uint256).max);
        }
    }

    function _cost(uint256 start, uint256 amount) private pure returns (uint256 value) {
        for (uint256 n = 1; n <= amount; ++n) {
            uint256 marginal = (start + n) * 0.05 ether;
            value += marginal < 10 ether ? marginal : 10 ether;
        }
    }

    function _fees(bytes32 subject, uint256 fee) private {
        Model storage m = model[subject];
        uint256 issuer = fee * 8 / 10;
        uint256 burnFee = fee / 10;
        totalFees += fee;
        if (m.payee == address(0)) {
            m.escrow += issuer;
            if (m.since == 0) m.since = uint64(vm.getBlockTimestamp());
        } else {
            issuerPaid[m.payee] += issuer;
            totalIssuerPaid += issuer;
        }
        poolsFunded += fee - issuer - burnFee;
        if (liquid) burnSpent += burnFee;
        else burnPending += burnFee;
    }

    function _buy(uint256 who, uint256 which, uint256 amount) private {
        address actor = actors[who];
        bytes32 subject = subjects[which];
        Model storage m = model[subject];
        uint256 value = _cost(m.supply, amount);
        uint256 fee = value / 10;
        (uint256 quote, uint256 feeQuote) = pages.buyPrice(subject, amount);
        assertEq(quote, value);
        assertEq(feeQuote, fee);
        uint256 before = imd.balanceOf(actor);
        vm.prank(actor);
        pages.buy(subject, amount, value + fee);
        assertEq(imd.balanceOf(actor), before - value - fee);
        holdings[subject][actor] += amount;
        m.supply += amount;
        m.reserve += value;
        bought += amount;
        _fees(subject, fee);
    }

    function _sell(uint256 who, uint256 which, uint256 amount) private {
        address actor = actors[who];
        bytes32 subject = subjects[which];
        Model storage m = model[subject];
        uint256 value = _cost(m.supply - amount, amount);
        uint256 fee = value / 10;
        (uint256 quote, uint256 feeQuote) = pages.sellPrice(subject, amount);
        assertEq(quote, value);
        assertEq(feeQuote, fee);
        uint256 before = imd.balanceOf(actor);
        vm.prank(actor);
        pages.sell(subject, amount, value - fee);
        assertEq(imd.balanceOf(actor), before + value - fee);
        holdings[subject][actor] -= amount;
        m.supply -= amount;
        m.reserve -= value;
        sold += amount;
        _fees(subject, fee);
    }

    function buy(uint256 actorSeed, uint256 subjectSeed, uint256 quantity) public {
        uint256 who = actorSeed % ACTORS;
        uint256 which = subjectSeed % SUBJECTS;
        uint256 owned = holdings[subjects[which]][actors[who]];
        if (owned == 10) {
            vm.prank(actors[who]);
            vm.expectRevert(MarginaliaPages.TooManyPages.selector);
            pages.buy(subjects[which], 1, type(uint256).max);
        } else if (gate[who] == 0) {
            vm.prank(actors[who]);
            vm.expectRevert(MarginaliaPages.NotEligible.selector);
            pages.buy(subjects[which], 1, type(uint256).max);
        } else {
            _buy(who, which, bound(quantity, 1, 10 - owned));
        }
    }

    function sell(uint256 actorSeed, uint256 subjectSeed, uint256 quantity) public {
        uint256 who = actorSeed % ACTORS;
        uint256 which = subjectSeed % SUBJECTS;
        uint256 owned = holdings[subjects[which]][actors[who]];
        if (owned == 0) {
            vm.prank(actors[who]);
            vm.expectRevert(MarginaliaPages.InsufficientPages.selector);
            pages.sell(subjects[which], 1, 0);
        } else {
            _sell(who, which, bound(quantity, 1, owned));
        }
    }

    function setGate(uint256 seed, uint8 modeSeed) public {
        uint256 who = seed % ACTORS;
        address actor = actors[who];
        uint8 mode = modeSeed % 4;
        whitelist.set(actor, mode == 1 ? 1 : 0);
        annex.set(actor, mode == 2 ? 1 : 0);
        uint256 held = marg.balanceOf(actor);
        if (held != 0) {
            vm.prank(actor);
            marg.transfer(address(this), held);
        }
        if (mode == 3) marg.transfer(actor, 10_000 ether);
        gate[who] = mode;
        assertEq(pages.eligible(actor), mode != 0);
    }

    function exitWithoutGate(uint256 actorSeed, uint256 subjectSeed) public {
        uint256 who = actorSeed % ACTORS;
        uint256 which = subjectSeed % SUBJECTS;
        setGate(who, 0);
        uint256 owned = holdings[subjects[which]][actors[who]];
        if (owned > 0) _sell(who, which, owned);
    }

    function roundTrip(uint256 actorSeed, uint256 subjectSeed, uint8 countSeed) public {
        uint256 who = actorSeed % ACTORS;
        uint256 which = subjectSeed % SUBJECTS;
        bytes32 subject = subjects[which];
        uint256 held = holdings[subject][actors[who]];
        if (held == 10 || gate[who] == 0) return;
        uint256 cycles = bound(countSeed, 1, 3);
        uint256 amount = 10 - held;
        uint256 fee = _cost(model[subject].supply, amount) / 10;
        uint256 before = imd.balanceOf(actors[who]);
        for (uint256 n; n < cycles; ++n) {
            _buy(who, which, amount);
            _sell(who, which, amount);
        }
        assertEq(imd.balanceOf(actors[who]), before - 2 * fee * cycles);
        assertEq(holdings[subject][actors[who]], held);
    }

    function request(uint256 actorSeed, uint256 subjectSeed, uint96 priceSeed) public {
        uint256 which = 1 + subjectSeed % (SUBJECTS - 1);
        bytes32 subject = subjects[which];
        address actor = actors[actorSeed % ACTORS];
        uint256 price = bound(priceSeed, 1, 1 ether);
        intake.setPrice(price);
        if (model[subject].payee != address(0)) {
            vm.prank(actor);
            vm.expectRevert(MarginaliaPages.AlreadyClaimed.selector);
            pages.requestClaim(handles[which], requests + 1);
        } else if (pending[subject].id != bytes32(0)) {
            vm.prank(actor);
            vm.expectRevert(MarginaliaPages.ClaimPending.selector);
            pages.requestClaim(handles[which], requests + 1);
        } else {
            uint256 before = imd.balanceOf(actor);
            vm.prank(actor);
            bytes32 id = pages.requestClaim(handles[which], requests + 1);
            assertEq(imd.balanceOf(actor), before - price);
            pending[subject] = Pending(id, actor, price, uint64(vm.getBlockTimestamp()));
            requests++;
        }
        assertEq(imd.allowance(address(pages), address(intake)), 0);
    }

    function _att(bytes32 id, address payee) private view returns (OracleAttestation.Attestation memory a) {
        a.requestId = keccak256(abi.encode("oracle UUID", id));
        a.chainId = block.chainid;
        a.questionHash = keccak256(abi.encode("resolved oracle question", id));
        a.answerType = OracleAttestation.ANSWER_ADDRESS;
        a.answer = abi.encode(payee);
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 4;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 days);
    }

    function _signature(OracleAttestation.Attestation memory a) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, pages.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function answer(uint256 subjectSeed, bool success) public {
        uint256 which = 1 + subjectSeed % (SUBJECTS - 1);
        bytes32 subject = subjects[which];
        Pending memory c = pending[subject];
        if (c.id == bytes32(0)) return;
        address payee = success ? writers[which] : address(0);
        OracleAttestation.Attestation memory a = _att(c.id, payee);
        uint256 askerBefore = imd.balanceOf(c.asker);
        assertTrue(intake.deliver(address(pages), c.id, a, _signature(a)), "valid callback failed");
        usedOracleIds.push(a.requestId);
        lastClosed[which] = c.id;
        delete pending[subject];
        if (success) {
            Model storage m = model[subject];
            uint256 refund = m.escrow >= c.price ? c.price : 0;
            uint256 payout = m.escrow - refund;
            m.payee = payee;
            m.escrow = 0;
            reimbursements += refund;
            issuerPaid[payee] += payout;
            totalIssuerPaid += payout;
            assertEq(imd.balanceOf(c.asker), askerBefore + refund);
            successfulAnswers++;
        } else {
            assertEq(imd.balanceOf(c.asker), askerBefore);
            zeroAnswers++;
        }
        assertTrue(pages.consumed(a.requestId));
        assertFalse(intake.deliver(address(pages), c.id, a, _signature(a)), "closed request replay");
    }

    function advanceTime(uint32 seed) public {
        vm.warp(vm.getBlockTimestamp() + bound(seed, 0, 31 days));
    }

    function abandon(uint256 subjectSeed) public {
        uint256 which = 1 + subjectSeed % (SUBJECTS - 1);
        bytes32 subject = subjects[which];
        Pending memory c = pending[subject];
        if (c.id == bytes32(0)) {
            vm.expectRevert(MarginaliaPages.UnknownRequest.selector);
            pages.abandonClaim(subject);
        } else if (vm.getBlockTimestamp() < uint256(c.at) + 3 days) {
            vm.expectRevert(MarginaliaPages.TooEarly.selector);
            pages.abandonClaim(subject);
        } else {
            pages.abandonClaim(subject);
            delete pending[subject];
            lastClosed[which] = c.id;
            OracleAttestation.Attestation memory a = _att(c.id, writers[which]);
            assertFalse(intake.deliver(address(pages), c.id, a, _signature(a)), "abandoned request delivered");
            assertFalse(pages.consumed(a.requestId));
            abandoned++;
        }
    }

    function recycle(uint256 subjectSeed) public {
        uint256 which = subjectSeed % SUBJECTS;
        bytes32 subject = subjects[which];
        Model storage m = model[subject];
        if (m.payee != address(0) || m.escrow == 0) {
            vm.expectRevert(MarginaliaPages.NothingToRecycle.selector);
            pages.recycle(subject);
        } else if (pending[subject].id != bytes32(0)) {
            vm.expectRevert(MarginaliaPages.ClaimPending.selector);
            pages.recycle(subject);
        } else if (vm.getBlockTimestamp() < uint256(m.since) + 90 days) {
            vm.expectRevert(MarginaliaPages.TooEarly.selector);
            pages.recycle(subject);
        } else {
            pages.recycle(subject);
            recycled += m.escrow;
            poolsFunded += m.escrow;
            m.escrow = 0;
            m.since = 0;
            successfulRecycles++;
        }
    }

    function setLiquidity(bool on) public {
        if (on == liquid) return;
        lp.add(key, -6000, 6000, on ? int256(10_000_000 ether) : -int256(10_000_000 ether));
        liquid = on;
    }

    function burn(uint256 amountSeed, bool excessiveMinimum) public {
        if (burnPending == 0) {
            vm.expectRevert(MarginaliaPages.InsufficientPendingBurn.selector);
            pages.burn(1, 0);
            return;
        }
        // Every fee is a multiple of this unit. Avoid sub-wei MARG output in this successful-action handler;
        // price/slippage failures and full/partial retries are still exercised explicitly below.
        uint256 amount = bound(amountSeed, 1, burnPending / BURN_UNIT) * BURN_UNIT;
        uint256 before = imd.balanceOf(address(pages));
        uint256 burnedBefore = marg.balanceOf(pages.DEAD());
        if (!liquid || excessiveMinimum) {
            vm.expectRevert();
            pages.burn(amount, excessiveMinimum ? type(uint256).max : 0);
            assertEq(imd.balanceOf(address(pages)), before);
            assertEq(marg.balanceOf(pages.DEAD()), burnedBefore);
        } else {
            pages.burn(amount, 1);
            burnPending -= amount;
            burnSpent += amount;
            assertEq(imd.balanceOf(address(pages)), before - amount);
            assertGt(marg.balanceOf(pages.DEAD()), burnedBefore);
        }
    }

    function donate(uint96 seed) public {
        uint256 amount = bound(seed, 0, 1 ether);
        imd.transfer(address(pages), amount);
        donated += amount;
    }

    function assertAccounting() public view {
        uint256 liabilities = burnPending + donated;
        uint256 escrowTotal;
        uint256 totalSupply;
        for (uint256 s; s < SUBJECTS; ++s) {
            bytes32 subject = subjects[s];
            Model memory m = model[subject];
            (uint64 supply, address payee, uint256 escrow, uint64 since) = pages.subjects(subject);
            assertEq(supply, m.supply, "supply ledger");
            assertEq(pages.payeeOf(subject), m.payee, "payee is permanent after claim");
            if (s > 0) assertEq(payee, m.payee);
            assertEq(escrow, m.escrow, "escrow ledger");
            assertEq(since, m.since, "escrow window");
            assertEq(pages.reserveOf(subject), m.reserve, "reserve cash flows");
            assertEq(m.reserve, _cost(0, m.supply), "reserve covers full curve unwind");
            uint256 sum;
            for (uint256 n; n < ACTORS; ++n) {
                uint256 held = pages.pagesOf(subject, actors[n]);
                assertEq(held, holdings[subject][actors[n]], "holder ledger");
                assertLe(held, 10, "wallet limit");
                sum += held;
            }
            assertEq(sum, supply, "sum of holders");
            (bytes32 id, address asker, uint256 price, uint64 at) = pages.claims(subject);
            Pending memory c = pending[subject];
            assertEq(id, c.id);
            assertEq(asker, c.asker);
            assertEq(price, c.price);
            assertEq(at, c.at);
            assertEq(imd.balanceOf(writers[s]), issuerPaid[writers[s]], "actual issuer receipts");
            liabilities += m.reserve + m.escrow;
            escrowTotal += m.escrow;
            totalSupply += m.supply;
        }
        assertEq(totalSupply, bought - sold);
        assertEq(
            imd.balanceOf(address(pages)), liabilities, "each IMD has exactly one obligation or donation"
        );
        assertEq(pages.pendingBurn(), burnPending);
        assertEq(totalFees * 8 / 10, totalIssuerPaid + reimbursements + recycled + escrowTotal);
        assertEq(totalFees / 10, burnSpent + burnPending);
        assertEq(totalFees / 10 + recycled, poolsFunded);
        assertEq(hook.poolManager().balanceOf(address(hook), uint256(uint160(address(imd)))), poolsFunded);
        assertEq(imd.allowance(address(pages), address(intake)), 0);
        assertEq(imd.allowance(address(pages), address(hook)), 0);
        assertEq(marg.balanceOf(address(pages)), 0, "burn output cannot remain in Pages");
        assertEq(hook.poolManager().balanceOf(address(pages), uint256(uint160(address(imd)))), 0);
        for (uint256 n; n < usedOracleIds.length; ++n) {
            assertTrue(pages.consumed(usedOracleIds[n]));
        }
    }

    /// @dev Called only by the deterministic tests and afterInvariant, never selected as a random handler.
    /// Actually pays every holder, without buy eligibility or launch-pool liquidity, then checks what remains.
    function unwindAll() external {
        setLiquidity(false);
        for (uint256 n; n < ACTORS; ++n) {
            setGate(n, 0);
            for (uint256 s; s < SUBJECTS; ++s) {
                uint256 held = holdings[subjects[s]][actors[n]];
                if (held != 0) _sell(n, s, held);
            }
        }
        assertEq(bought, sold, "all pages redeemed");
        assertAccounting();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract PagesInvariantTest is Fixture {
    PagesHandler private handler;
    MarginaliaPages private pages;

    function setUp() public {
        _setup();
        ClaimIntake intake = new ClaimIntake();
        MockAnnexRecords annex = new MockAnnexRecords();
        pages = new MarginaliaPages(
            IMarginaliaHookPages(address(hook)),
            IMarginaliaRecords(address(annex)),
            intake,
            bytes32("oracle.request@oracle-1"),
            vm.addr(0x5E7)
        );
        MockWhitelist whitelist = new MockWhitelist();
        vm.etch(pages.WHITELIST(), address(whitelist).code);
        handler = new PagesHandler(pages, intake, MockWhitelist(pages.WHITELIST()), annex, liquidity, key);
        for (uint256 n; n < handler.ACTORS(); ++n) {
            imd.transfer(handler.actors(n), 100_000 ether);
        }
        imd.transfer(address(handler), 100_000 ether);
        token.transfer(address(handler), 500_000 ether);
        // Seed genuine purchases across the cap, and a separate unclaimed handle with reimbursable escrow.
        for (uint256 n; n < 21; ++n) {
            handler.buy(n, 0, 10);
        }
        handler.buy(0, 1, 10);
        handler.buy(1, 1, 10);
        handler.assertAccounting();
        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = PagesHandler.buy.selector;
        selectors[1] = PagesHandler.sell.selector;
        selectors[2] = PagesHandler.setGate.selector;
        selectors[3] = PagesHandler.exitWithoutGate.selector;
        selectors[4] = PagesHandler.roundTrip.selector;
        selectors[5] = PagesHandler.request.selector;
        selectors[6] = PagesHandler.answer.selector;
        selectors[7] = PagesHandler.advanceTime.selector;
        selectors[8] = PagesHandler.abandon.selector;
        selectors[9] = PagesHandler.recycle.selector;
        selectors[10] = PagesHandler.setLiquidity.selector;
        selectors[11] = PagesHandler.burn.selector;
        selectors[12] = PagesHandler.donate.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_reservesEscrowFeesAndOwnershipConserved() public view {
        handler.assertAccounting();
    }

    function afterInvariant() public {
        handler.unwindAll();
    }

    function testHandlerExercisesClaimRecycleBurnAndUngatedExit() public {
        handler.setLiquidity(false);
        handler.buy(2, 1, 5);
        handler.sell(2, 1, 3);
        handler.request(3, 0, 0.5 ether);
        handler.answer(0, false);
        handler.request(4, 0, 0.5 ether);
        handler.answer(0, true);
        handler.buy(5, 1, 1);
        handler.buy(0, 2, 10);
        handler.request(6, 1, 0.25 ether);
        handler.advanceTime(3 days);
        handler.abandon(1);
        for (uint256 i; i < 3; ++i) {
            handler.advanceTime(31 days);
        }
        handler.recycle(2);
        handler.setLiquidity(true);
        handler.burn(type(uint256).max, false);
        handler.exitWithoutGate(1, 0);
        handler.donate(1);
        handler.assertAccounting();
        assertEq(handler.successfulAnswers(), 1);
        assertEq(handler.zeroAnswers(), 1);
        assertEq(handler.abandoned(), 1);
        assertEq(handler.successfulRecycles(), 1);
        assertGt(handler.burnSpent(), 0);
        handler.unwindAll();
    }
}
