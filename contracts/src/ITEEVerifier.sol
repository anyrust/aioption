// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ITEEVerifier — TEE Attestation Verification Interface
 * @notice Any verifier that can validate a TEE attestation quote
 *         and return the code hash + TEE public key.
 */
interface ITEEVerifier {
    /**
     * @notice Verify a TEE attestation quote on-chain
     * @param quote Raw attestation quote (Intel SGX/TDX format)
     * @return valid       Whether the TEE is genuine and the quote checks out
     * @return mrenclave   Code measurement (identifies which code is running)
     * @return teePubKey   Public key of the TEE (for signature verification)
     */
    function verify(bytes calldata quote)
        external view returns (bool valid, bytes32 mrenclave, bytes memory teePubKey);
}
