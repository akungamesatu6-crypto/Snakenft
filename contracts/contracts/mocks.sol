// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice Test-only mock of the SPACE ID .ai Agent ID NFT.
/// Mimics the real registry's balanceOf check: an address holds
/// an Agent ID when it owns at least one of these tokens.
/// mintBatch lets tests give many wallets an Agent ID in one tx.
/// NOT part of the production contract — on the live network,
/// SnakeAgentNFT uses the public SPACE ID registry
/// 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F.
contract MockAgentIdRegistry is ERC721 {
    uint256 private _nextId = 1;

    constructor() ERC721("Mock Agent ID", "AGENTID") {}

    function mintTo(address to) external returns (uint256 tokenId) {
        tokenId = _nextId++;
        _mint(to, tokenId);
    }

    function mintBatch(address[] calldata recipients) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            _mint(recipients[i], _nextId++);
        }
    }
}

/// @notice Test-only generic contract caller, used to prove
/// mint() rejects calls from contracts (NoContracts).
contract MockGenericCaller {
    function tryCall(address target, bytes calldata data) external payable returns (bool ok) {
        (ok, ) = target.call{value: msg.value}(data);
    }

    /// @notice Same as tryCall, but bubbles the inner revert
    /// reason so tests can assert the exact custom error.
    function tryCallRevert(address target, bytes calldata data) external payable {
        (bool ok, bytes memory ret) = target.call{value: msg.value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

/// @notice Test-only force-send helper: selfdestructs into a
/// target so it receives BNB outside mint() (for withdraw()).
/// NOTE: on Cancun (EIP-6780) selfdestruct only transfers ETH
/// when called in the same tx as creation — use
/// MockForceSendCtor instead.
contract MockForceSend {
    function boom(address payable target) external payable {
        selfdestruct(target);
    }
}

/// @notice Test-only force-send that works on Cancun: the
/// selfdestruct runs in the CONSTRUCTOR (creation tx), so
/// the ETH actually reaches the target (EIP-6780).
contract MockForceSendCtor {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}
