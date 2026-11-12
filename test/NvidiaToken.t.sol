// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {NvidiaToken} from "../src/NvidiaToken.sol";
import {DeployNvidiaToken} from "../script/DeployNvidiaToken.s.sol";
import {
    MockLaunchFactory,
    RevertingFactory,
    MalformedFactory,
    DirtyWordFactory,
    GasBurningFactory,
    HugeAnswerFactory,
    MiniPoolManager,
    EscrowRoute
} from "./mocks/MockLaunchFactory.sol";

contract NvidiaTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000e18;
    address constant JENSEN = 0xc59b0c072f73ceEA3Dc354031165501c0Ff25023;
    uint64 constant LAUNCH_NUMBER = 42;

    MockLaunchFactory factory;
    NvidiaToken token;

    address poolManager = makeAddr("poolManager");
    address distributor = makeAddr("distributor");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        factory = new MockLaunchFactory();
        vm.prank(address(factory));
        token = new NvidiaToken(address(factory), poolManager, LAUNCH_NUMBER);
    }

    // ------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------

    function _fund(address to, uint256 amount) internal {
        vm.prank(address(factory));
        token.transfer(to, amount);
    }

    function _split(uint256 amount) internal pure returns (uint256 net, uint256 tribute, uint256 burned) {
        tribute = (amount * 50) / 10_000;
        burned = (amount * 100) / 10_000;
        net = amount - tribute - burned;
    }

    // ------------------------------------------------------------------------
    // Metadata and constructor
    // ------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Nvidia");
        assertEq(token.symbol(), "ADVN");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), 1_000_000_000 * 10 ** 18);
    }

    function test_mintsWholeSupplyToDeployerOnce() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
    }

    function test_constantsAndLaunchAddresses() public view {
        assertEq(token.TRIBUTE_BPS(), 50);
        assertEq(token.BURN_BPS(), 100);
        assertEq(token.BPS_DENOMINATOR(), 10_000);
        assertEq(token.TRIBUTE_RECIPIENT(), JENSEN);
        assertEq(token.factory(), address(factory));
        assertEq(token.poolManager(), poolManager);
        assertEq(token.launchNumber(), LAUNCH_NUMBER);
        assertEq(token.distributor(), address(0));
    }

    function test_constructorRejectsZeroFactory() public {
        vm.expectRevert(NvidiaToken.ZeroAddress.selector);
        new NvidiaToken(address(0), poolManager, LAUNCH_NUMBER);
    }

    function test_constructorRejectsZeroPoolManager() public {
        vm.expectRevert(NvidiaToken.ZeroAddress.selector);
        new NvidiaToken(address(factory), address(0), LAUNCH_NUMBER);
    }

    function test_constructorDoesNotCallTheFactory() public {
        // An address with no code works as the factory at deploy: the launch checks run on an empty chain.
        address bare = makeAddr("bareFactory");
        vm.prank(bare);
        NvidiaToken fresh = new NvidiaToken(bare, poolManager, LAUNCH_NUMBER);
        assertEq(fresh.balanceOf(bare), SUPPLY);
    }

    function test_deployScriptFunctionDeploysWithConfig() public {
        DeployNvidiaToken script = new DeployNvidiaToken();
        NvidiaToken deployed = script.deploy(
            DeployNvidiaToken.Config({factory: address(factory), poolManager: poolManager, launchNumber: 7})
        );
        assertEq(deployed.factory(), address(factory));
        assertEq(deployed.poolManager(), poolManager);
        assertEq(deployed.launchNumber(), 7);
        // The token mints to msg.sender, which for a direct deploy is the script contract.
        assertEq(deployed.balanceOf(address(script)), SUPPLY);
    }

    // ------------------------------------------------------------------------
    // Launch flows move exactly what they say
    // ------------------------------------------------------------------------

    function test_factoryOutboundIsUntaxed() public {
        uint256 amount = 100_000_000e18;
        vm.prank(address(factory));
        vm.expectEmit(address(token));
        emit IERC20.Transfer(address(factory), alice, amount);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(factory)), SUPPLY - amount);
        assertEq(token.balanceOf(JENSEN), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_factoryInboundIsUntaxed() public {
        _fund(alice, 1_000e18);
        vm.prank(alice);
        token.transfer(address(factory), 1_000e18);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_poolManagerInboundIsUntaxedOutboundIsTaxed() public {
        _fund(alice, 1_000e18);
        // Sell: alice -> pool manager, exact.
        vm.prank(alice);
        token.transfer(poolManager, 1_000e18);
        assertEq(token.balanceOf(poolManager), 1_000e18);
        assertEq(token.balanceOf(JENSEN), 0);
        assertEq(token.totalSupply(), SUPPLY);
        // Buy: pool manager -> bob, taxed; the whole tax comes out of the pool manager's balance.
        (uint256 net, uint256 tribute, uint256 burned) = _split(1_000e18);
        vm.prank(poolManager);
        token.transfer(bob, 1_000e18);
        assertEq(token.balanceOf(poolManager), 0);
        assertEq(token.balanceOf(bob), net);
        assertEq(token.balanceOf(JENSEN), tribute);
        assertEq(token.totalSupply(), SUPPLY - burned);
    }

    function test_routingThroughPoolManagerEscrowIsTaxed() public {
        MiniPoolManager pm = new MiniPoolManager();
        NvidiaToken t = new NvidiaToken(address(this), address(pm), LAUNCH_NUMBER);
        EscrowRoute route = new EscrowRoute(pm, address(t));
        t.transfer(address(route), 1_000_000e18);

        route.send(bob, 1_000_000e18);
        (uint256 net, uint256 tribute, uint256 burned) = _split(1_000_000e18);
        assertEq(t.balanceOf(bob), net, "pass-through skipped the tax");
        assertEq(t.balanceOf(JENSEN), tribute);
        assertEq(t.totalSupply(), SUPPLY - burned);
        assertEq(t.balanceOf(address(pm)), 0);
    }

    function test_distributorFlowsAreUntaxedAndCached() public {
        factory.setDistributor(LAUNCH_NUMBER, distributor);
        uint256 swarm = SUPPLY / 10;
        _fund(distributor, swarm);
        assertEq(token.balanceOf(distributor), swarm);
        assertEq(token.distributor(), address(0), "nothing looked up yet: the factory was a side");

        // The claim: distributor -> claimant, neither the factory nor the pool manager, so the token
        // looks the distributor up and caches it.
        vm.prank(distributor);
        vm.expectEmit(address(token));
        emit NvidiaToken.DistributorCached(distributor);
        assertTrue(token.transfer(alice, swarm));
        assertEq(token.balanceOf(alice), swarm, "claim arrived short");
        assertEq(token.balanceOf(distributor), 0);
        assertEq(token.distributor(), distributor);
        assertEq(token.totalSupply(), SUPPLY);

        // Sending back to the distributor is also exact.
        vm.prank(alice);
        token.transfer(distributor, 1e18);
        assertEq(token.balanceOf(distributor), 1e18);
    }

    function test_isExemptReflectsLaunchAddresses() public {
        assertTrue(token.isExempt(address(factory)));
        assertFalse(token.isExempt(poolManager), "only transfers into the pool manager are untaxed");
        assertFalse(token.isExempt(distributor), "unknown until the factory names it");
        assertFalse(token.isExempt(alice));
        assertFalse(token.isExempt(JENSEN));
        factory.setDistributor(LAUNCH_NUMBER, distributor);
        assertTrue(token.isExempt(distributor), "read live from the factory before caching");
    }

    function test_distributorOfAnotherLaunchIsNotExempt() public {
        factory.setDistributor(LAUNCH_NUMBER + 1, distributor);
        _fund(distributor, 1_000e18);
        vm.prank(distributor);
        token.transfer(alice, 1_000e18);
        (uint256 net,,) = _split(1_000e18);
        assertEq(token.balanceOf(alice), net, "a stranger's distributor is taxed like anyone");
        assertEq(token.distributor(), address(0));
    }

    // ------------------------------------------------------------------------
    // Ordinary transfers are taxed
    // ------------------------------------------------------------------------

    function test_ordinaryTransferSplitsThreeWays() public {
        _fund(alice, 10_000e18);
        uint256 amount = 1_000e18;
        (uint256 net, uint256 tribute, uint256 burned) = _split(amount);
        assertEq(net, 985e18);
        assertEq(tribute, 5e18);
        assertEq(burned, 10e18);

        vm.prank(alice);
        vm.expectEmit(address(token));
        emit IERC20.Transfer(alice, bob, net);
        vm.expectEmit(address(token));
        emit IERC20.Transfer(alice, JENSEN, tribute);
        vm.expectEmit(address(token));
        emit IERC20.Transfer(alice, address(0), burned);
        vm.expectEmit(address(token));
        emit NvidiaToken.TransferTaxed(alice, bob, net, tribute, burned);
        assertTrue(token.transfer(bob, amount));

        assertEq(token.balanceOf(alice), 10_000e18 - amount, "sender pays the whole amount");
        assertEq(token.balanceOf(bob), net);
        assertEq(token.balanceOf(JENSEN), tribute);
        assertEq(token.totalSupply(), SUPPLY - burned);
    }

    function test_splitTransferMatchesReference() public view {
        (uint256 net, uint256 tribute, uint256 burned) = token.splitTransfer(1_000e18);
        assertEq(net, 985e18);
        assertEq(tribute, 5e18);
        assertEq(burned, 10e18);
    }

    function test_tinyAmountsRoundCutsDown() public {
        _fund(alice, 1_000);
        // 199 wei: 0.5% rounds to 0, 1% rounds to 1.
        vm.prank(alice);
        token.transfer(bob, 199);
        assertEq(token.balanceOf(bob), 198);
        assertEq(token.balanceOf(JENSEN), 0);
        assertEq(token.totalSupply(), SUPPLY - 1);
        // 99 wei: both cuts round to 0, the receiver gets it all.
        vm.prank(alice);
        token.transfer(carol, 99);
        assertEq(token.balanceOf(carol), 99);
        assertEq(token.totalSupply(), SUPPLY - 1);
    }

    function test_zeroAmountTransferIsAllowedAndFree() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromIsTaxedAndSpendsFullAllowance() public {
        _fund(alice, 10_000e18);
        vm.prank(alice);
        token.approve(carol, 1_000e18);

        vm.prank(carol);
        assertTrue(token.transferFrom(alice, bob, 1_000e18));
        (uint256 net, uint256 tribute, uint256 burned) = _split(1_000e18);
        assertEq(token.balanceOf(bob), net);
        assertEq(token.balanceOf(JENSEN), tribute);
        assertEq(token.balanceOf(alice), 9_000e18);
        assertEq(token.allowance(alice, carol), 0, "the allowance is spent in full, not net");
        assertEq(token.totalSupply(), SUPPLY - burned);
    }

    function test_tributeRecipientPaysTaxLikeAnyHolder() public {
        _fund(JENSEN, 1_000e18);
        vm.prank(JENSEN);
        token.transfer(alice, 1_000e18);
        (uint256 net, uint256 tribute, uint256 burned) = _split(1_000e18);
        assertEq(token.balanceOf(alice), net);
        assertEq(token.balanceOf(JENSEN), tribute, "the tribute on his own transfer comes back to him");
        assertEq(token.totalSupply(), SUPPLY - burned);
    }

    function test_selfTransferIsTaxed() public {
        _fund(alice, 1_000e18);
        vm.prank(alice);
        token.transfer(alice, 1_000e18);
        (, uint256 tribute, uint256 burned) = _split(1_000e18);
        assertEq(token.balanceOf(alice), 1_000e18 - tribute - burned);
        assertEq(token.balanceOf(JENSEN), tribute);
    }

    // ------------------------------------------------------------------------
    // Failure paths
    // ------------------------------------------------------------------------

    function test_transferMoreThanBalanceRevertsWithFullAmount() public {
        _fund(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 100e18, 101e18));
        token.transfer(bob, 101e18);
    }

    function test_exemptSenderStillNeedsBalance() public {
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poolManager, 0, 1));
        token.transfer(bob, 1);
    }

    function test_factoryCannotSendMoreThanSupply() public {
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(factory), SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
    }

    function test_transferToZeroReverts() public {
        _fund(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1e18);
    }

    function test_transferFromWithoutAllowanceReverts() public {
        _fund(alice, 100e18);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, carol, 0, 1e18));
        token.transferFrom(alice, bob, 1e18);
    }

    function test_transferFromAboveAllowanceReverts() public {
        _fund(alice, 100e18);
        vm.prank(alice);
        token.approve(carol, 1e18);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, carol, 1e18, 2e18));
        token.transferFrom(alice, bob, 2e18);
    }

    function test_factoryCannotPullFromAHolderWithoutAllowance() public {
        _fund(alice, 100e18);
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, 1)
        );
        token.transferFrom(alice, address(factory), 1);
        assertEq(token.balanceOf(alice), 100e18);
    }

    function test_noMintOwnerOrAdminEntrypoints() public {
        string[14] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "owner()",
            "transferOwnership(address)",
            "renounceOwnership()",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "setBlacklist(address,bool)",
            "burnFrom(address,uint256)",
            "setFee(uint256)",
            "setTributeRecipient(address)",
            "setExempt(address,bool)",
            "upgradeTo(address)"
        ];
        _fund(alice, 100e18);
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, type(uint128).max);
            vm.prank(address(factory));
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 100e18);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        bool reachable = true;
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "DELEGATECALL");
                assertTrue(op != 0xF2, "CALLCODE");
                assertTrue(op != 0xFF, "SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    // ------------------------------------------------------------------------
    // The factory lookup never blocks ordinary transfers
    // ------------------------------------------------------------------------

    function test_factoryWithoutCodeDoesNotBlockTransfers() public {
        address bare = makeAddr("bareFactory");
        vm.prank(bare);
        NvidiaToken fresh = new NvidiaToken(bare, poolManager, LAUNCH_NUMBER);
        vm.prank(bare);
        fresh.transfer(alice, 1_000e18);
        vm.prank(alice);
        assertTrue(fresh.transfer(bob, 1_000e18));
        (uint256 net,,) = _split(1_000e18);
        assertEq(fresh.balanceOf(bob), net);
        assertEq(fresh.distributor(), address(0));
        assertFalse(fresh.isExempt(alice));
    }

    function test_revertingFactoryDoesNotBlockTransfers() public {
        RevertingFactory reverting = new RevertingFactory();
        vm.prank(address(reverting));
        NvidiaToken fresh = new NvidiaToken(address(reverting), poolManager, LAUNCH_NUMBER);
        vm.prank(address(reverting));
        fresh.transfer(alice, 1_000e18);
        vm.prank(alice);
        assertTrue(fresh.transfer(bob, 1_000e18));
        assertEq(fresh.distributor(), address(0));
    }

    function test_malformedFactoryAnswerDoesNotBlockTransfers() public {
        MalformedFactory malformed = new MalformedFactory();
        vm.prank(address(malformed));
        NvidiaToken fresh = new NvidiaToken(address(malformed), poolManager, LAUNCH_NUMBER);
        vm.prank(address(malformed));
        fresh.transfer(alice, 1_000e18);
        vm.prank(alice);
        assertTrue(fresh.transfer(bob, 1_000e18));
        assertEq(fresh.distributor(), address(0));
    }

    function _assertFactoryTolerated(address bad) internal {
        vm.prank(bad);
        NvidiaToken fresh = new NvidiaToken(bad, poolManager, LAUNCH_NUMBER);
        vm.prank(bad);
        fresh.transfer(alice, 1_000e18);
        assertFalse(fresh.isExempt(bob));
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        assertTrue(fresh.transfer(bob, 100e18));
        assertLt(gasBefore - gasleft(), 300_000, "a bad factory made the transfer expensive");
        (uint256 net, uint256 tribute, uint256 burned) = _split(100e18);
        assertEq(fresh.balanceOf(bob), net);
        assertEq(fresh.balanceOf(JENSEN), tribute);
        assertEq(fresh.totalSupply(), SUPPLY - burned);
        assertEq(fresh.distributor(), address(0));
    }

    function test_dirtyWordFactoryAnswerDoesNotBlockTransfers() public {
        _assertFactoryTolerated(address(new DirtyWordFactory()));
    }

    function test_gasBurningFactoryDoesNotBlockTransfers() public {
        _assertFactoryTolerated(address(new GasBurningFactory()));
    }

    function test_hugeFactoryAnswerDoesNotBlockTransfers() public {
        _assertFactoryTolerated(address(new HugeAnswerFactory()));
    }

    function test_splitTransferHandlesMaxAmount() public view {
        uint256 amount = type(uint256).max;
        (uint256 net, uint256 tribute, uint256 burned) = token.splitTransfer(amount);
        assertEq(tribute, amount / 200);
        assertEq(burned, amount / 100);
        assertEq(net, amount - tribute - burned);
    }

    // ------------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------------

    function testFuzz_taxedTransferConservesValue(uint256 funded, uint256 amount) public {
        funded = bound(funded, 0, SUPPLY);
        amount = bound(amount, 0, funded);
        _fund(alice, funded);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(alice);
        assertTrue(token.transfer(bob, amount));

        (uint256 net, uint256 tribute, uint256 burned) = _split(amount);
        assertEq(net + tribute + burned, amount, "the three cuts add up to the amount");
        assertEq(token.balanceOf(alice), funded - amount);
        assertEq(token.balanceOf(bob), net);
        assertEq(token.balanceOf(JENSEN), tribute);
        assertEq(token.totalSupply(), supplyBefore - burned);
        assertLe(tribute, amount / 200);
        assertLe(burned, amount / 100);
        assertGe(net + 2, (amount * 985) / 1000);
    }

    function testFuzz_splitTransferIsExactAndMonotone(uint256 amount) public view {
        amount = bound(amount, 0, SUPPLY);
        (uint256 net, uint256 tribute, uint256 burned) = token.splitTransfer(amount);
        assertEq(net + tribute + burned, amount);
        assertEq(tribute, amount / 200);
        assertEq(burned, amount / 100);
        assertGe(net, tribute + burned);
    }

    function testFuzz_launchFlowsAreExact(uint256 amount, uint8 which) public {
        amount = bound(amount, 0, SUPPLY);
        factory.setDistributor(LAUNCH_NUMBER, distributor);
        address exempt = which % 2 == 0 ? address(factory) : distributor;
        if (exempt != address(factory)) _fund(exempt, amount);

        vm.prank(exempt);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount, "outbound from a launch address arrived short");

        uint256 held = token.balanceOf(exempt);
        vm.prank(alice);
        assertTrue(token.transfer(exempt, amount));
        assertEq(token.balanceOf(exempt), held + amount, "inbound to a launch address arrived short");
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(JENSEN), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_cannotSpendMoreThanBalance(uint256 funded, uint256 excess) public {
        funded = bound(funded, 0, SUPPLY - 1);
        excess = bound(excess, 1, SUPPLY - funded);
        _fund(alice, funded);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, funded, funded + excess)
        );
        token.transfer(bob, funded + excess);
    }

    function testFuzz_supplyNeverGrows(address from, address to, uint256 amount) public {
        vm.assume(from != address(0) && to != address(0));
        amount = bound(amount, 0, SUPPLY);
        _fund(from, amount);
        vm.prank(from);
        token.transfer(to, amount);
        assertLe(token.totalSupply(), SUPPLY);
    }
}
