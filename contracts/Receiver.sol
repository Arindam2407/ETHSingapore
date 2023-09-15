// SPDX-License-Identifier: GPL-3.0-only

pragma solidity ^0.8.10;
pragma experimental ABIEncoderV2;

import "./MerkleTree.sol";
import "./MerkleTreeSubset.sol";
import "./Blacklist.sol";
import "./WETH.sol";
import "./Verifier.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { AxelarExecutable } from '@axelar-network/axelar-gmp-sdk-solidity/contracts/executable/AxelarExecutable.sol';
import { IAxelarGateway } from '@axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGateway.sol';
import { IAxelarGasService } from '@axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGasService.sol';

struct Proof {
    uint256[2] a;
    uint256[2][2] b;
    uint256[2] c;
}


interface IVerifier {
    function verifyProof(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[6] calldata input
    ) external view returns (bool);
}

contract Receiver is AxelarExecutable, MerkleTree, MerkleTreeSubset, Blacklist, ReentrancyGuard {
    uint256 public immutable denomination;
    IVerifier public immutable verifier;
    WETHToken public weth;
    IAxelarGasService gasService;

    mapping(bytes32 => bool) public nullifierHashes;

    event Withdrawal(
        address to,
        bytes32 nullifierHash,
        address indexed relayer,
        uint256 fee
    );

    event Deposit(
        bytes32 indexed commitment,
        uint32 leafIndex,
        uint256 timestamp
    );

    event AddedToAllowList(
        bytes32 indexed commitment,
        uint32 leafIndexSubset,
        uint256 timestamp
    );
   
    constructor(
        address gateway_,
        address gasReceiver_,
        IVerifier _verifier,
        uint256 _denomination,
        address poseidon
    ) MerkleTree(poseidon) MerkleTreeSubset(poseidon) AxelarExecutable(gateway_) {
        gasService = IAxelarGasService(gasReceiver_);
        require(_denomination > 0, "denomination should be greater than 0");
        verifier = _verifier;
        denomination = _denomination;
        weth = new WETHToken("Wraped ETH","WETH", address(this));
    }

   // move to sender later
   // Handles calls created by setAndSend. Updates this contract's value
   function _execute(
        string calldata sourceChain_,
        string calldata sourceAddress_,
        bytes calldata payload_
    ) internal override {
        (bytes32 commitment, address depositor) = abi.decode(payload_, (bytes32, address));
        uint32 insertedIndex = _insert(commitment);
        uint32 insertedIndexSubset;

        if(!isBlacklisted(depositor)){ 
            insertedIndexSubset = _insertSubset(commitment);
            emit AddedToAllowList(commitment, insertedIndexSubset,block.timestamp);
        }

        emit Deposit(commitment, insertedIndex, block.timestamp);
    }

    /**
    @dev Withdraw a deposit from the contract. `proof` is a zkSNARK proof data, and input is an array of circuit public inputs
    `input` array consists of:
      - merkle root of all deposits in the contract
      - hash of unique deposit nullifier to prevent double spends
      - the recipient of funds
      - optional fee that goes to the transaction sender (usually a relay)
    */
    function withdraw(
        Proof calldata _proof,
        bytes32 _root,
        bytes32 _subsetRoot,
        bytes32 _nullifierHash,
        address  _recipient,
        address  _relayer,
        uint256 _fee
    ) external payable nonReentrant {
        require(_fee <= denomination, "Fee exceeds transfer value");
        require(
            !nullifierHashes[_nullifierHash],
            "The note has been already spent"
        );
        require(isKnownRoot(_root), "Cannot find your merkle root"); // Make sure to use a recent one
        require(
            verifier.verifyProof(
                _proof.a,
                _proof.b,
                _proof.c,
                [
                    uint256(_root),
                    uint256(_subsetRoot),
                    uint256(_nullifierHash),
                    uint256(uint160(_recipient)),
                    uint256(uint160(_relayer)),
                    _fee
                ]
            ),
            "Invalid withdraw proof"
        );

        nullifierHashes[_nullifierHash] = true;
        _processWithdraw(_recipient, _relayer, _fee);
        emit Withdrawal(_recipient, _nullifierHash, _relayer, _fee);
    }

    function _processWithdraw(
        address  _recipient,
        address  _relayer,
        uint256 _fee
    ) internal {
        // sanity checks
        require(
            msg.value == 0,
            "Message value is supposed to be zero for ETH instance"
        );
        weth.mint(_recipient, denomination - _fee);

        if(_fee > 0){
            weth.mint(_relayer, _fee);
        }
    }

    function isSpent(bytes32 _nullifierHash) public view returns (bool) {
        return nullifierHashes[_nullifierHash];
    }

    function isSpentArray(bytes32[] calldata _nullifierHashes)
        external
        view
        returns (bool[] memory spent)
    {
        spent = new bool[](_nullifierHashes.length);
        for (uint256 i = 0; i < _nullifierHashes.length; i++) {
            if (isSpent(_nullifierHashes[i])) {
                spent[i] = true;
            }
        }
    }
}
