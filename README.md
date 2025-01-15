# Sneed EVM
## Multi-Canister Approach to Bridging ICRCs to EVM with a Handler Canister

Sneed EVM interface and handler.

### Acknowledgements
- Thank you, Bitomni.
- Thank you, ICDevs.
- Thank you, Sneed DAO.
- Thank you, Bitcorn Labs.

---

## Project Overview

This project includes:

### 1. **Hub Client Canister**
   - Calls an existing bridge canister via `hub.did` to move ICRC tokens from the IC to Base.

### 2. **Wallet Canister**
   - Owns an EVM address (via the IC’s ECDSA).
   - Uses the [Aviate Labs Encoding.mo](https://github.com/aviate-labs/encoding.mo) library for EVM transaction building and ABI encoding.
   - Can send/receive ERC-20 tokens, mint NFTs, and check balances.

---

## Quick Start

### 1. **Install DFX**
```bash
dfx start --clean --background
```

### 2. **EVM RPC Deployment**

Start the local replica:
```bash
dfx start --background
```

Locally deploy the `evm_rpc` canister:
```bash
dfx deps pull
dfx deps init evm_rpc --argument '(record {})'
dfx deps deploy
```

Deploy all canisters:
```bash
dfx deploy
```

---

## Hub Client Canister

### Switch Environment (Mainnet or Testnet)
```bash
dfx canister call hub_client_canister setDeploymentEnv '(variant { Testnet })'
```

- **Hub Canister ID**:
  - Mainnet: `n6ii2-2yaaa-aaaaj-azvia-cai`
  - Testnet: `l5h5f-miaaa-aaaal-qjioq-cai`

- **Target Chain ID**:
  - Mainnet: `base`
  - Testnet: `base_sepolia`

### Bridge ICRC Tokens
Bridge ICRC to Base:
```bash
dfx canister call hub_client_canister bridgeICRCToken '(
  principal "aaaaa-bbb-ccc-ddddd-cai",  // tokenPid
  null,                                 // fromTxId
  "0xRecipientEvmAddress",
  null,                                 // fromAddress
  1000000000:nat                        // amount
)'
```
Send an ICRC1:
```bash
dfx canister call hub_client_canister send_icrc1_tokens '(
  principal "icrc1-canister-id", // tokenCanister
  "sender-text-addr",            // from
  "recipient-text-addr",         // to
  50000:nat,                     // amount
  null                           // fee
)'
```



---

## Wallet Canister

### Check Your EVM Address
```bash
dfx canister call wallet_canister getEvmAddress
```

### Send an ERC-20 Token
```bash
dfx canister call wallet_canister sendErc20 '(
  principal "<EVM_RPC_CANISTER>",
  record {},
  "0x14A04d7Dec9299121f7842a4446f15d04C4111d5",  // token address
  "0xRecipient",
  100000000:nat,
  2000000000:nat,
  300000:nat,
  1500000000:nat,
  variant { Ethereum = null },
  blob "yourPublicKey"
)'
```

### Mint an NFT
```bash
dfx canister call wallet_canister doEthereumMintNFT '( ... )'
```

### Call BaseSwap Smart Contract
- **Base Chain ID**: `8453`
- **Contract Address**: `0xde151d5c92bfaa288db4b67c21cd55d5826bcc93`

BaseSwap Contract Calls:
```bash
dfx canister call wallet_canister callBaseProxyContract '(
  record {
    chainId = 8453:nat;
    gasLimit = 300000:nat;
    maxFeePerGas = 2000000000:nat;
    maxPriorityFeePerGas = 1500000000:nat;
    derivationPath = blob "derivationPath";
    methodSig = "someMethod(uint256)";
    args = vec { variant { uint256 = 1234:nat } };
  }
)'
```

### Bridge Base to ICRC:
```bash
dfx canister call wallet_canister burnBaseToken '(
  8453:nat,                    // chainId for Base
  blob "yourDerivationPath",
  2000000000:nat,             // maxFeePerGas
  1500000000:nat,             // maxPriorityFeePerGas
  300000:nat,                 // gasLimit
  1000000:nat,                // amount to burn
  "icp"                        // target chain
)'
```
Signs an EIP-1559 call:
```plaintext
burn(1000000, "icp")
```

---

## EIP-1559 Calls
```bash
dfx canister call wallet_canister makeEthereumValueTrx '(
  record {
    canisterId = principal "<EVM_RPC_CANISTER_PID>";
    rpcs = record {};
    to = "0xRecipient";
    value = 1000000000000000000:nat; // e.g., 1 ETH
    gasPrice = 2000000000:nat;
    gasLimit = 300000:nat;
    maxPriorityFeePerGas = 1500000000:nat;
    network = variant { Base = null };
    tecdsaSha = blob "yourDerivationPath";
    publicKey = blob "somePublicKey";
  }
)'
```

---

## NFTs
- **Mint NFT**:
  Calls `mint_icrc99(uint256,address,string)` on an NFT contract.

- **Send ERC-20**:
  Calls `transfer(address,uint256)` on an ERC-20 contract.
