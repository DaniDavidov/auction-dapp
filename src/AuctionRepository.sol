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

    DeedRepository private immutable i_deedRepository;

    Auction[] private auctions;

    mapping (address owner => uint256[] auctions) private ownerAuctions;
    mapping (uint256 auctionId => Bid[] bids) private auctionBids;

    modifier contractIsDeedOperator(uint256 _tokenId) {
        address operator = i_deedRepository.getApproved(_tokenId);
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
        bool active;
    }

    event AuctionCreated(uint256 indexed auctionId, uint256 indexed deedId);
    event BidSuccess(address indexed bidder, uint256 indexed auctionId, uint256 bidAmount);
    event AuctionCancelled(uint256 indexed actionId);
    event AuctionFinalized(address indexed sender, uint256 indexed autionId);

    constructor(address _deedRepoAddress) {
        i_deedRepository = DeedRepository(_deedRepoAddress);
    }

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

    /**
     * Implements CEI
     * @param _auctionId The ID number of the auction
     * @dev Bidder bids on auction in case every one of these conditions are true
     *      - Bidder is not the owner of the auction
     *      - Auction not expired
     *      - Bid amount is greater than current bid or starting price(if no bid)
     */
    function bidOnAuction(uint256 _auctionId) external payable nonReentrant {
        // checks
        if (_auctionId > getAuctionsCount()) {
            revert AuctionRepository__InvalidAuciton();
        }

        Auction memory auction = getAuctionById(_auctionId);
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
     * @dev Everyone can call this function so the ether and the deed ownership are not potentially locked
     * @dev The auction can be finalized if both conditions are respected:
     *      - The auction has ended
     *      - There is at least one bid for the auction
     */
    function finalizeAuction(uint256 _auctionId) external nonReentrant {
        Auction memory auction = getAuctionById(_auctionId);
        Bid[] memory bids = auctionBids[_auctionId];

        if (block.timestamp < auction.blockDeadline) {
            revert AuctionRepository__AuctionNotEnded();
        }

        if (bids.length == 0) {
            cancelAuction(_auctionId);
        } else {
            // return the bid to the bidder
            Bid memory lastBid = bids[bids.length - 1];
            (bool success, ) = payable(lastBid.bidder).call{value: lastBid.amount}("");
            if (!success) {
                revert();
            }

            // return the deed ownership to the owner of the auction
            i_deedRepository.safeTransferFrom(address(this), auction.owner, auction.deedId);
            auctions[_auctionId].active = false;
            emit AuctionFinalized(msg.sender, _auctionId);
        }
    }
    
    /**
    * @dev Creates an auction with the given informatin
    * @param _deedId uint256 of the deed registered in DeedRepository
    * @param _auctionTitle string containing auction title
    * @param _startPrice uint256 starting price of the auction
    * @param _blockDeadline uint is the timestamp in which the auction expires
    */
    function createAuction(uint256 _deedId, string memory _auctionTitle, uint256 _startPrice, uint _blockDeadline) external contractIsDeedOperator(_deedId) {
        address owner = i_deedRepository.ownerOf(_deedId);
        uint256 auctionId = getAuctionsCount() + 1;
        Auction memory auction;
        auction.name = _auctionTitle;
        auction.blockDeadline = _blockDeadline;
        auction.deedId = _deedId;
        auction.startPrice = _startPrice;
        auction.owner = payable(owner);
        auction.active = true;
        ownerAuctions[owner].push(auctionId);
        auctions.push(auction);

        emit AuctionCreated(auctionId, _deedId);
    }


    /**
     * Implements CEI
     * @param _auctionId ID number of an auction
     * @dev The owner of the auction cancels the auction then he gets back his deed and the bidder gets back his ether 
     */
    function cancelAuction(uint256 _auctionId) public nonReentrant {
        Auction memory auction = getAuctionById(_auctionId);
        if (auction.owner != msg.sender) {
            revert AuctionRepository__OnlyOwnerCanCancelAuction();
        }

        if (block.timestamp > auction.blockDeadline) {
            revert AuctionRepository__AuctionExpired();
        }

        auctions[_auctionId].active = false;

        i_deedRepository.safeTransferFrom(address(this), auction.owner, auction.deedId);

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
}