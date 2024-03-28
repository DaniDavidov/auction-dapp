// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {AuctionRepository} from "../../src/AuctionRepository.sol";
import {DeedRepository} from "../../src/DeedRepository.sol";

contract AuctionTest is Test {
    AuctionRepository private auctionRepository;
    DeedRepository private deedRepository;

    address payable USER;
    uint256 constant STARTING_USER_BALANCE = 10 ether;
    uint256 constant INTERVAL = 1 days;

    struct Bid {
        address bidder;
        uint256 amount;
    }

    function setUp() external {
        auctionRepository = new AuctionRepository();
        deedRepository = new DeedRepository("TestNFT", "TNFT");
        USER = payable(makeAddr("USER"));
        vm.deal(USER, STARTING_USER_BALANCE);
    }

    //createAuction tests
    function testCreateAuctionRevertsIfAuctionIsNotDeedOperator() public {
        vm.prank(USER);
        deedRepository.registerDeed(USER, 1, "");
        vm.expectRevert(AuctionRepository.AuctionRepository__DeedOperatorMustBeAuctionContract.selector);
        auctionRepository.createAuction(1, address(deedRepository), "", 1 ether, block.timestamp + 1 days);
    }

    modifier createdAuction {
        vm.startPrank(USER);
        deedRepository.registerDeed(USER, 1, "");
        deedRepository.approve(address(auctionRepository), 1);
        vm.stopPrank();
        auctionRepository.createAuction(1, address(deedRepository), "", 1 ether, block.timestamp + 1 days);
        _;
    }

    function testCreatesAuctionSuccessfully() public createdAuction {
        assertEq(auctionRepository.getAuctionById(0).deedId, 1);
    }

    //BidOnAuction tests
    function testRevertsIfAuctionExpired() public createdAuction {
        vm.warp(block.timestamp + INTERVAL + 1);
        address newUser = makeAddr("newUser");
        hoax(newUser, STARTING_USER_BALANCE);
        vm.expectRevert(AuctionRepository.AuctionRepository__AuctionExpired.selector);
        auctionRepository.bidOnAuction{value: 2 ether}(0);
    }

    function testRevertsIfBidderIsAuctionOwner() public createdAuction {
        vm.prank(USER);
        vm.expectRevert(AuctionRepository.AuctionRepository__OwnerCannotBidOnOwnAuction.selector);
        auctionRepository.bidOnAuction{value: 2 ether}(0);
    }


    function testRevertsIfEtherAmountSmallerThanLastBid() public createdAuction {
        address newUser = makeAddr("newUser");
        deal(newUser, STARTING_USER_BALANCE);
        vm.startPrank(newUser);
        auctionRepository.bidOnAuction{value: 1 ether}(0);
        vm.expectRevert(AuctionRepository.AuctionRepository__BidMustBeHigherThanCurrentBid.selector);
        auctionRepository.bidOnAuction{value: 0.1 ether}(0);
        vm.stopPrank();
    }

    function testBidSuccess() public createdAuction {
        address newUser = makeAddr("newUser");
        deal(newUser, STARTING_USER_BALANCE);
        vm.startPrank(newUser);
        auctionRepository.bidOnAuction{value: 1 ether}(0);
        vm.stopPrank();
        (address bidder, uint256 amount) = auctionRepository.getAuctionCurrentBid(0);
        assertEq(newUser, bidder);
        assertEq(1 ether, amount);
    }

    function testAuctionRefundsAmountToLastBidder() public createdAuction {
        address user1 = makeAddr("user1");
        deal(user1, STARTING_USER_BALANCE);
        vm.startPrank(user1);
        auctionRepository.bidOnAuction{value: 1 ether}(0);
        vm.stopPrank();

        address user2 = makeAddr("user2");
        deal(user2, STARTING_USER_BALANCE);
        vm.startPrank(user2);
        auctionRepository.bidOnAuction{value: 2 ether}(0);
        vm.stopPrank();

        (address bidder, uint256 amount) = auctionRepository.getAuctionCurrentBid(0);
        assertEq(bidder, user2);
        assertEq(2 ether, amount);
        assertEq(user1.balance, STARTING_USER_BALANCE);
    }

    // cancelAuction tests
    function testRevertsIfSenderIsNotAuctionOwner() public createdAuction {
        address user1 = makeAddr("user1");
        vm.prank(user1);
        vm.expectRevert(AuctionRepository.AuctionRepository__OnlyOwnerCanCancelAuction.selector);
        auctionRepository.cancelAuction(0, address(deedRepository));
    }

    function testCancelAuctionRevertsIfAuctionExpired() public createdAuction {
        vm.warp(block.timestamp + INTERVAL + 1);
        vm.prank(USER);
        vm.expectRevert(AuctionRepository.AuctionRepository__AuctionExpired.selector);
        auctionRepository.cancelAuction(0, address(deedRepository));
    }

    function testCancelAuctionRefundsEtherToTheBidder() public createdAuction {
        address bidder = makeAddr("bidder");
        hoax(bidder, STARTING_USER_BALANCE);
        auctionRepository.bidOnAuction{value: 2 ether}(0);
        console.log(bidder.balance);
        vm.prank(USER);
        auctionRepository.cancelAuction(0, address(deedRepository));

        assertEq(bidder.balance, STARTING_USER_BALANCE);
    }

    // revokeOperator tests
    function testRevertsIfTheAuctionIsNotCanceled() public createdAuction {
        vm.prank(USER);
        vm.expectRevert(AuctionRepository.AuctionRepository__AuctionNotCanceled.selector);
        auctionRepository.revokeOperator(0, address(deedRepository));
    }

    function testRevokeOperatorRevertsIfSenderIsNotAuctionOwner() public createdAuction {
        vm.prank(USER);
        auctionRepository.cancelAuction(0, address(deedRepository));
        vm.expectRevert(AuctionRepository.AuctionRepository__Unauthorized.selector);
        auctionRepository.revokeOperator(0, address(deedRepository));
    }

    function testRevokeSuccessfull() public createdAuction {
        vm.startPrank(USER);
        auctionRepository.cancelAuction(0, address(deedRepository));
        auctionRepository.revokeOperator(0, address(deedRepository));
        vm.stopPrank();

        address operator = deedRepository.getApproved(auctionRepository.getAuctionById(0).deedId);
        bool isApproved = deedRepository.isApprovedForAll(USER, operator);
        assertEq(isApproved, false);
    }

    // finalizeAuction tests
    function testRevertsIfAuctionFinalized() public createdAuction {
        vm.startPrank(USER);
        auctionRepository.cancelAuction(0, address(deedRepository));
        vm.expectRevert(AuctionRepository.AuctionRepository__AuctionExpired.selector);
        auctionRepository.finalizeAuction(0, address(deedRepository));
        vm.stopPrank();
    }

    function testRevertsIfAuctionNotEnded() public createdAuction {
        vm.prank(USER);
        vm.expectRevert(AuctionRepository.AuctionRepository__AuctionNotEnded.selector);
        auctionRepository.finalizeAuction(0, address(deedRepository));
    }

    function testFinalizeAuctionSuccess() public createdAuction {
        address bidder = makeAddr("bidder");
        hoax(bidder, STARTING_USER_BALANCE);
        auctionRepository.bidOnAuction{value: 2 ether}(0);

        vm.warp(block.timestamp + INTERVAL + 1);
        vm.prank(USER);
        auctionRepository.finalizeAuction(0, address(deedRepository));

        uint256 deedId = auctionRepository.getAuctionById(0).deedId;
        address deedOwner = deedRepository.ownerOf(deedId);

        uint256 expectedBalance = 12 ether;
        assertEq(deedOwner, bidder);
        assertEq(USER.balance, expectedBalance);
    }
}