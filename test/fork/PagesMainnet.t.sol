// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MarginaliaPages, IMarginaliaHookPages, IMarginaliaRecords} from "../../src/MarginaliaPages.sol";
import {IIntake} from "../../src/interfaces/IIntake.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";
import {ClaimIntake} from "../Pages.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface LivePagesHook is IMarginaliaHookPages {
    function INTAKE() external view returns (address);
    function ACTION() external view returns (bytes32);
    function ORACLE_SIGNER() external view returns (address);
}

/// @dev Optional read-only mainnet rehearsal. All deployments, balances and signatures exist only on the fork.
contract PagesMainnetTest is Test {
    address constant HOOK = 0xf0457dD0Cf526686190e4f057Ba19dB14D34a0cc;
    address constant ANNEX = 0xD0C0d97aeBE9194606BCC46ce56524Eee4615543;
    address constant INTAKE = 0x1397434cd35e8a9C8aC312A61D3A285EB31dea56;
    address constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant MARG = 0xfA0EfEa559bdE229031c2B0A219472316647759c;
    bytes32 constant ACTION = bytes32("oracle.request@oracle-1");
    uint256 constant LOCAL_SIGNER_KEY = 0x5E7;
    MarginaliaPages pages;
    ClaimIntake mockIntake;
    address reader;
    address asker;
    address payee;
    bytes32 subject;
    bytes32 pending;
    OracleAttestation.Attestation a;
    bytes signature;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 26178476);
        mockIntake = new ClaimIntake();
        // The signer and Intake are local mocks solely for exercising the callback with the live IMD token.
        pages = new MarginaliaPages(
            IMarginaliaHookPages(HOOK),
            IMarginaliaRecords(ANNEX),
            mockIntake,
            ACTION,
            vm.addr(LOCAL_SIGNER_KEY)
        );
        reader = makeAddr("pages-mainnet-reader-one");
        asker = makeAddr("pages-mainnet-asker");
        payee = makeAddr("pages-mainnet-payee");
        address reader2 = makeAddr("pages-mainnet-reader-two");
        subject = pages.registerHandle("forkclaim");
        deal(IMD, reader, 100 ether);
        deal(IMD, reader2, 100 ether);
        deal(MARG, reader, 10_000 ether);
        deal(MARG, reader2, 10_000 ether);
        vm.startPrank(reader);
        IERC20(IMD).approve(address(pages), 100 ether);
        pages.buy(subject, 10, 100 ether);
        vm.stopPrank();
        vm.startPrank(reader2);
        IERC20(IMD).approve(address(pages), 100 ether);
        pages.buy(subject, 10, 100 ether);
        vm.stopPrank();
        deal(IMD, asker, 0.5 ether);
        vm.startPrank(asker);
        IERC20(IMD).approve(address(pages), 0.5 ether);
        pending = pages.requestClaim("forkclaim", 777);
        vm.stopPrank();
        a.requestId = keccak256("pages-local-oracle-request");
        a.chainId = block.chainid;
        a.questionHash = keccak256("pages-local-question");
        a.answerType = OracleAttestation.ANSWER_ADDRESS;
        a.answer = abi.encode(payee);
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 5;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LOCAL_SIGNER_KEY, pages.attestationDigest(a));
        signature = abi.encodePacked(r, s, v);
    }

    function testLiveCallbackWithFreshBalancesFits200k() public {
        uint256 before = gasleft();
        assertTrue(
            mockIntake.deliver(address(pages), pending, a, signature), "live IMD callback exceeded stipend"
        );
        emit log_named_uint(
            "Live IMD callback delivery gas (including mock and test storage reads)", before - gasleft()
        );
        assertEq(IERC20(IMD).balanceOf(asker), 0.5 ether);
        assertEq(IERC20(IMD).balanceOf(payee), 0.34 ether);
        assertEq(pages.payeeOf(subject), payee);
        assertFalse(mockIntake.deliver(address(pages), pending, a, signature));
    }

    function testExactMainnetConstructorWiringAndTrade() public {
        LivePagesHook live = LivePagesHook(HOOK);
        assertEq(live.INTAKE(), INTAKE);
        assertEq(live.ACTION(), ACTION);
        assertEq(live.ORACLE_SIGNER(), SIGNER);
        assertEq(live.imd(), IMD);
        assertEq(live.token(), MARG);
        assertEq(SIGNER.code.length, 0, "the requested signer is an EOA");
        assertEq(IIntake(INTAKE).priceOf(ACTION, IMD), 0.5 ether);
        MarginaliaPages deployed =
            new MarginaliaPages(live, IMarginaliaRecords(ANNEX), IIntake(INTAKE), ACTION, SIGNER);
        bytes32 addressSubject = deployed.subjectOf(payee);
        uint256 burned = IERC20(MARG).balanceOf(deployed.DEAD());
        vm.startPrank(reader);
        IERC20(IMD).approve(address(deployed), 1 ether);
        deployed.buy(addressSubject, 1, 1 ether);
        deployed.sell(addressSubject, 1, 0.045 ether);
        vm.stopPrank();
        assertGt(IERC20(MARG).balanceOf(deployed.DEAD()), burned);
        assertEq(deployed.reserveOf(addressSubject), 0);
        assertEq(IERC20(IMD).balanceOf(address(deployed)), 0);
        assertEq(address(deployed.hook()), HOOK);
        assertEq(address(deployed.annex()), ANNEX);
        assertEq(address(deployed.intake()), INTAKE);
        assertEq(deployed.action(), ACTION);
        assertEq(deployed.oracleSigner(), SIGNER);
    }
}
