# sneed_evm
# multi canister approach to bridging icrcs to evm with a handler canister
sneed evm interface and handler.
thank your bitomni 
thank your icdevs
thank your sneeds
This project includes:

1. **hub_client_canister**  
   - Calls an existing Bridge canister via `hub.did` to move ICRC tokens from the IC to base/bnb/sui chain.

2. **wallet_canister**  
   - Owns an EVM address (via the IC’s ECDSA).
   - Uses the [aviate-labs/encoding.mo](https://github.com/aviate-labs/encoding.mo) library for EVM transaction building and ABI encoding.
   - Can send/receive ERC-20 tokens, mint NFTs, and check balances.

## Quick Start

1. **Install** dfx:
   ```bash
   dfx start --clean --background


dfx deploy

hub_client_canister
# Switch environment if desired (Mainnet vs. Testnet)
dfx canister call hub_client_canister setDeploymentEnv '(variant { Testnet })'

Hub canister id: 
- Mannet: n6ii2-2yaaa-aaaaj-azvia-cai
- Testnet:  l5h5f-miaaa-aaaal-qjioq-cai

target_chain_id: 
- Mainnet: base
- Testnet: base_sepolia

# Bridge ICRC tokens
dfx canister call hub_client_canister bridgeICRCToken '(
  principal "<ICRC_TOKEN_PID>",
  null,
  "0x<YourWalletCanisterEvmAddr>",
  null,
  1000000:nat
)'

wallet_canister
# Check your EVM address
dfx canister call wallet_canister getEvmAddress

# Send an ERC-20 token
dfx canister call wallet_canister sendErc20 '(
  principal "<EVM_RPC_CANISTER>",
  record {},
  "0x14A04d7Dec9299121f7842a4446f15d04C4111d5",  # token address
  "0xRecipient",
  100000000:nat,
  2000000000:nat,
  300000:nat,
  1500000000:nat,
  variant { Ethereum = null },
  blob "yourPublicKey"
)'

# send icrc1 tokens from this canister to another address
dfx canister call hub_client_canister send_icrc1_tokens '(
  principal "<ICRC1_TOKEN_CANISTER>",
  "aaaa-bbbb-cc",
  "ddd-eee-fff",
  100000000:nat
)'


# Mint an NFT
dfx canister call wallet_canister doEthereumMintNFT '( ... )'
