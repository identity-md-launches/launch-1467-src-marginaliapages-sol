// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MarginaliaPages, IMarginaliaHookPages, IMarginaliaRecords} from "../src/MarginaliaPages.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {ClaimIntake} from "./Pages.t.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract PagesFactoryProbe {
    function deploy(bytes memory code, bytes32 salt) external returns (address result) {
        assembly ("memory-safe") { result := create2(0, add(code, 32), mload(code), salt) }
        require(result != address(0), "Pages constructor failed");
    }
}

contract PagesDeploymentTest is Test {
    address constant HOOK = 0xf0457dD0Cf526686190e4f057Ba19dB14D34a0cc;
    address constant ANNEX = 0xD0C0d97aeBE9194606BCC46ce56524Eee4615543;
    address constant INTAKE = 0x1397434cd35e8a9C8aC312A61D3A285EB31dea56;
    address constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    bytes32 constant ACTION = bytes32("oracle.request@oracle-1");

    function testFactoryDeploysExactlyPagesWithNoDependencyCode() public {
        vm.chainId(1);
        assertEq(HOOK.code.length, 0);
        assertEq(ANNEX.code.length, 0);
        assertEq(INTAKE.code.length, 0);
        assertEq(SIGNER.code.length, 0);
        PagesFactoryProbe factory = new PagesFactoryProbe();
        bytes memory code = abi.encodePacked(
            type(MarginaliaPages).creationCode, abi.encode(HOOK, ANNEX, INTAKE, ACTION, SIGNER)
        );
        assertLe(code.length, 49_152);
        bytes32 salt = keccak256("pages v0.10 constructor rehearsal");
        address expected = address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(code))))
            )
        );
        MarginaliaPages p = MarginaliaPages(factory.deploy(code, salt));
        assertEq(address(p), expected);
        assertEq(address(p.hook()), HOOK);
        assertEq(address(p.annex()), ANNEX);
        assertEq(address(p.intake()), INTAKE);
        assertEq(p.action(), ACTION);
        assertEq(p.oracleSigner(), SIGNER);
        assertEq(p.BASE(), 0.05 ether);
        assertEq(p.CAP(), 10 ether);
        assertEq(p.CAP_PAGE(), 200);
        assertEq(p.MAX_PER_WALLET(), 10);
        assertEq(p.MARG_GATE(), 10_000 ether);
        assertEq(p.FEE_BPS(), 1000);
        assertEq(p.ISSUER_BPS(), 8000);
        assertEq(p.BURN_BPS(), 1000);
        assertEq(p.WHITELIST(), 0xcB0b0531e86A9aC36Fa865cA8e3dbccF047FDA91);
        assertEq(p.DEAD(), 0x000000000000000000000000000000000000dEaD);
        assertEq(p.CLAIM_WINDOW(), 90 days);
        assertEq(p.ANSWER_DEADLINE(), 3 days);
        assertEq(p.PANEL_SIZE(), 5);
        assertEq(p.QUORUM(), 4);
        assertEq(p.MAX_PRICE(), 1 ether);
        bytes memory runtime = address(p).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden application opcode");
        }
    }

    function testConstructorRejectsMissingRequiredValues() public {
        vm.expectRevert(MarginaliaPages.BadClaim.selector);
        new MarginaliaPages(
            IMarginaliaHookPages(address(0)), IMarginaliaRecords(ANNEX), IIntake(INTAKE), ACTION, SIGNER
        );
        vm.expectRevert(MarginaliaPages.BadClaim.selector);
        new MarginaliaPages(
            IMarginaliaHookPages(HOOK), IMarginaliaRecords(ANNEX), IIntake(address(0)), ACTION, SIGNER
        );
        vm.expectRevert(MarginaliaPages.BadClaim.selector);
        new MarginaliaPages(
            IMarginaliaHookPages(HOOK), IMarginaliaRecords(ANNEX), IIntake(INTAKE), bytes32(0), SIGNER
        );
        vm.expectRevert(OracleAttestationConsumer.ZeroSigner.selector);
        new MarginaliaPages(
            IMarginaliaHookPages(HOOK), IMarginaliaRecords(ANNEX), IIntake(INTAKE), ACTION, address(0)
        );
    }
}

/// @dev Verification-only test harness: the protocol vector is a bytes32[] answer about chain 1, while Pages
/// accepts address answers about its own chain. Production callback requirements are not relaxed.
contract PagesSignatureHarness is MarginaliaPages {
    constructor(IMarginaliaHookPages h, IIntake i, address signer)
        MarginaliaPages(h, IMarginaliaRecords(address(0)), i, bytes32("oracle.request@oracle-1"), signer)
    {}

    function verify(OracleAttestation.Attestation calldata a, bytes calldata sig) external view {
        _verifyAttestation(a, sig);
    }
}

contract PagesOracleConformanceTest is Test {
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;
    string constant CALLBACK =
        "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";
    MockERC20 public imd;
    ClaimIntake intake;
    PagesSignatureHarness consumer;

    function setUp() public {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        imd = new MockERC20("IMD", "IMD", 10 ether);
        intake = new ClaimIntake();
        deployCodeTo(
            "PagesDeployment.t.sol:PagesSignatureHarness",
            abi.encode(address(this), address(intake), SIGNER),
            VECTOR_CONSUMER
        );
        consumer = PagesSignatureHarness(VECTOR_CONSUMER);
        imd.approve(address(consumer), 1 ether);
    }

    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    function testDigestMatchesPinnedProtocolVector() public view {
        assertEq(consumer.attestationDigest(vector()), VECTOR_DIGEST);
    }

    function testCallbackSelectorMatchesProtocol() public view {
        assertEq(consumer.onOracleResult.selector, bytes4(keccak256(bytes(CALLBACK))));
    }

    function testVerifiesPinnedProtocolSignature() public view {
        consumer.verify(vector(), VECTOR_SIGNATURE);
    }

    function testAddressAnswerFromVectorKeyDeliveredUnderStipend() public {
        bytes32 rid = consumer.requestClaim("vector", 1);
        OracleAttestation.Attestation memory a = vector();
        a.chainId = VECTOR_CHAIN;
        a.answerType = OracleAttestation.ANSWER_ADDRESS;
        a.answer = abi.encode(SIGNER);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, consumer.attestationDigest(a));
        bytes memory sig = abi.encodePacked(r, s, v);
        assertTrue(intake.deliver(address(consumer), rid, a, sig));
        assertTrue(consumer.consumed(a.requestId));
        assertEq(consumer.payeeOf(consumer.subjectOfHandle("vector")), SIGNER);
        assertFalse(intake.deliver(address(consumer), rid, a, sig));
    }
}
