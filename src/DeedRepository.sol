// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {ERC721URIStorage, ERC721} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";

contract DeedRepository is ERC721URIStorage {

    constructor(string memory _name, string memory _symbol) ERC721(_name, _symbol) {}

    function registerDeed(address _to, uint256 _tokenId, string calldata _tokenURI) external {
        _mint(_to, _tokenId);
        addTokenMetadata(_tokenId, _tokenURI);
    }

    function addTokenMetadata(uint256 _tokenId, string calldata _tokenURI) public {
        _setTokenURI(_tokenId, _tokenURI);
    }

    function getTokenMetadata(uint256 _tokenId) external view returns (string memory) {
        return tokenURI(_tokenId);
    }

}