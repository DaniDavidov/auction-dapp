// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DeedRepository} from "./DeedRepository.sol";

contract AuctionRepository is ReentrancyGuard {
    error AuctionRepository__OnlyDeedOwnerCanStartAuciton();
    error AuctionRepository__InvalidAuciton();
    error AuctionRepository__OwnerCannotBidOnOwnAuction();
    error AuctionRepository__AuctionExpired();
    error AuctionRepository__AuctionNotEnded();
    error AuctionRepository__BidMustBeHigherThanCurrentBid();
    error AuctionRepository__OnlyOwnerCanCancelAuction();
    error AuctionRepository__DeedOperatorMustBeAuctionContract();
    error AuctionRepository__AuctionNotCanceled();
    error AuctionRepository__Unauthorized();


    Auction[] private auctions;

    mapping (address owner => uint256[] auctions) private ownerAuctions;
    mapping (uint256 auctionId => Bid[] bids) private auctionBids;

    modifier contractIsDeedOperator(uint256 _tokenId, address _deedRepoAddress) {
        DeedRepository deedRepository = DeedRepository(_deedRepoAddress);
        address operator = deedRepository.getApproved(_tokenId);
        if (operator != address(this)) {
            revert AuctionRepository__DeedOperatorMustBeAuctionContract();
        }
        _;
    }

    struct Bid {
        address bidder;
        uint256 amount;
    }

    struct Auction {
        string name;
        uint256 blockDeadline;
        uint256 deedId;
        uint256 startPrice;
        address payable owner;
        bool finalized;
        bool canceled;
    }

    event AuctionCreated(uint256 indexed auctionId, uint256 indexed deedId);
    event BidSuccess(address indexed bidder, uint256 indexed auctionId, uint256 bidAmount);
    event AuctionCancelled(uint256 indexed actionId);
    event AuctionFinalized(address indexed sender, uint256 indexed autionId);

    // block direct payments to the contract
    receive() external payable {
        revert();
    }

    function getAuctionsCount() public view returns (uint256) {
        return auctions.length;
    }

    function getAuctionById(uint256 _auctionId) public view returns (Auction memory) {
        if (_auctionId > getAuctionsCount()) {
            revert AuctionRepository__InvalidAuciton();
        }
        return auctions[_auctionId];
    }

    function getAuctionCurrentBid(uint256 _auctionId) external view returns (address, uint256) {
        Bid[] memory bids = auctionBids[_auctionId];
        Bid memory currentBid = bids[bids.length - 1];
        return (currentBid.bidder, currentBid.amount);
    }

    /**
     * Implements CEI
     * @param _auctionId The ID number of the auction
     * @dev Bidder bids on auction in case every one of these conditions are true
     *      - Bidder is not the owner of the auction
     *      - Auction not finalized
     *      - Auction not expired
     *      - Bid amount is greater than current bid or starting price(if no bid)
     */
    function bidOnAuction(uint256 _auctionId) external payable nonReentrant {
        // checks
        if (_auctionId > getAuctionsCount()) {
            revert AuctionRepository__InvalidAuciton();
        }

        Auction memory auction = getAuctionById(_auctionId);
        if (auction.finalized) {
            revert AuctionRepository__AuctionExpired();
        }

        if (msg.sender == auction.owner) {
            revert AuctionRepository__OwnerCannotBidOnOwnAuction();
        }

        if (block.timestamp > auction.blockDeadline) {
            revert AuctionRepository__AuctionExpired();
        }

        Bid[] memory bids = auctionBids[_auctionId];
        uint256 bidsCount = bids.length;
        Bid memory lastBid;
        if (bidsCount > 0) {
            lastBid = bids[bids.length - 1];
        }

        if (lastBid.amount >= msg.value) {
            revert AuctionRepository__BidMustBeHigherThanCurrentBid();
        }
        
        // effects
        Bid memory newBid;
        newBid.bidder = msg.sender;
        newBid.amount = msg.value;
        auctionBids[_auctionId].push(newBid);
        
        // interactions
        if (bidsCount > 0) {
            (bool success, ) = payable(lastBid.bidder).call{value: lastBid.amount}("");
            if (!success) {
                revert();
            }
        }
        emit BidSuccess(msg.sender, _auctionId, msg.value);
    }

    /**
     * Implements CEI
     * @param _auctionId ID number of the auction
     * @param _deedRepoAddress address of the DeedRepository contract
     * @dev Everyone can call this function so the ether and the deed ownership are not potentially locked
     * @dev The auction can be finalized if both conditions are respected:
     *      - The auction has ended
     *      - There is at least one bid for the auction
     * @dev If all conditions are respected the function transfers
     *      the deed of the auction to the last bidder
     *      and pays the bid amount to the auction owners
     */
    function finalizeAuction(uint256 _auctionId, address _deedRepoAddress) external nonReentrant {
        Auction memory auction = getAuctionById(_auctionId);
        Bid[] memory bids = auctionBids[_auctionId];

        if (auction.finalized) {
            revert AuctionRepository__AuctionExpired();
        }

        if (block.timestamp < auction.blockDeadline) {
            revert AuctionRepository__AuctionNotEnded();
        }

        if (bids.length == 0) {
            cancelAuction(_auctionId, _deedRepoAddress);
        } else {
            // pay the bid to the auction owner
            Bid memory lastBid = bids[bids.length - 1];
            (bool success, ) = payable(auction.owner).call{value: lastBid.amount}("");
            if (!success) {
                revert();
            }

            // transfer the deed to the last bidder of the auction
            DeedRepository deedRepository = DeedRepository(_deedRepoAddress);
            deedRepository.safeTransferFrom(auction.owner, lastBid.bidder, auction.deedId);
            auctions[_auctionId].finalized = true;
            emit AuctionFinalized(msg.sender, _auctionId);
        }
    }
    
    /**
    * @dev Creates an auction with the given informatin
    * @param _deedId uint256 of the deed registered in DeedRepository
    * @param _deedRepoAddress address of the DeedRepository contract
    * @param _auctionTitle string containing auction title
    * @param _startPrice uint256 starting price of the auction
    * @param _blockDeadline uint is the timestamp in which the auction expires
    */
    function createAuction(uint256 _deedId, address _deedRepoAddress, string memory _auctionTitle, uint256 _startPrice, uint _blockDeadline) external contractIsDeedOperator(_deedId, _deedRepoAddress) {
        DeedRepository deedRepository = DeedRepository(_deedRepoAddress);
        address owner = deedRepository.ownerOf(_deedId);
        uint256 auctionId = getAuctionsCount() + 1;
        Auction memory auction;
        auction.name = _auctionTitle;
        auction.blockDeadline = _blockDeadline;
        auction.deedId = _deedId;
        auction.startPrice = _startPrice;
        auction.owner = payable(owner);
        auction.finalized = false;
        ownerAuctions[owner].push(auctionId);
        auctions.push(auction);

        emit AuctionCreated(auctionId, _deedId);
    }


    /**
     * Implements CEI
     * @param _auctionId ID number of an auction
     * @param _deedRepoAddress address of the DeedRepository contract
     * @dev The owner of the auction cancels the auction then he gets back his deed and the bidder gets back his ether 
     */
    function cancelAuction(uint256 _auctionId, address _deedRepoAddress) public nonReentrant {
        Auction memory auction = getAuctionById(_auctionId);
        if (auction.owner != msg.sender) {
            revert AuctionRepository__OnlyOwnerCanCancelAuction();
        }

        if (block.timestamp > auction.blockDeadline) {
            revert AuctionRepository__AuctionExpired();
        }
        Auction storage s_auction = auctions[_auctionId];
        s_auction.finalized = true;
        s_auction.canceled = true;

        Bid[] memory bids = auctionBids[_auctionId];
        if (bids.length > 0) {
            Bid memory lastBid = bids[bids.length - 1];
            (bool success, ) = payable(lastBid.bidder).call{value: lastBid.amount}("");
            if (!success) {
                revert();
            }
        }
        emit AuctionCancelled(_auctionId);
    }

    /**
     * @param _auctionId ID number of the auction 
     * @param _deedRepoAddress address of the deed repository
     * @dev Only if the auction is canceled the owner of the deed can revoke the operator of his own deed
     */
    function revokeOperator(uint256 _auctionId, address _deedRepoAddress) external {
        Auction memory auction = getAuctionById(_auctionId);
        if (!auction.canceled) {
            revert AuctionRepository__AuctionNotCanceled();
        }

        if (msg.sender != auction.owner) {
            revert AuctionRepository__Unauthorized();
        }

        DeedRepository deedRepository = DeedRepository(_deedRepoAddress);
        deedRepository.setApprovalForAll(address(this), false);
    }
}