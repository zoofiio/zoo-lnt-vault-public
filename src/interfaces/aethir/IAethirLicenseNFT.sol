// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IERC4907} from "src/interfaces/IERC4907.sol";

interface IAethirLicenseNFT is IERC721, IERC4907 {
  
    function isBanned(uint256 tokenId) external view returns (bool);

    function batchSetUser(
        uint256[] calldata tokenIds,
        address[] calldata users,
        uint64 expires
    ) external; 
    
}