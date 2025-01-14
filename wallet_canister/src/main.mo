import Debug "mo:base/Debug";
import Error "mo:base/Error";
import Principal "mo:base/Principal";
import Prim "mo:prim";
import Cycles "mo:base/ExperimentalCycles";
import Blob "mo:base/Blob";
import Hash "mo:base/Hash";

// Data structure for concurrency-safe nonce management
import StableBTreemap "mo:stableheapbtreemap/StableBTreemap";

// Additional or optional imports
import ICRC7 "mo:icrc7-mo/ICRC7";
import ICRC3 "mo:icrc3-mo/ICRC3";
import ICRC37 "mo:icrc37-mo/ICRC37";
import Star "mo:star/Star";
import LibSecp256k1 "mo:libsecp256k1/LibSecp256k1";
import RLPRelaxed "mo:rlprelaxed/RlpRelaxed";
import EVMTxs "mo:evm-txs/EvmTxs";
import ClassPlus "mo:class-plus/ClassPlus";
import TimerTool "mo:timer-tool/TimerTool";

// EVM encoding
import ABI "mo:encoding.mo/abi";
import EVM "mo:encoding.mo/EVM";
import Hex "mo:encoding.mo/hex";
import Buffer "mo:buffer/Buffer";

////////////////////////////////////////////////////
// EVM RPC Module
////////////////////////////////////////////////////
module EVMRPC {
  public type RpcServices = {};

  public type EthSendRawTransactionResult = variant {
    Ok : opt text;
    NonceTooLow;
    NonceTooHigh;
    InsufficientFunds;
    Other : text;
  };

  public type Service = actor {
    eth_sendRawTransaction : (
      RpcServices,
      ?{
        responseSizeEstimate : ?nat64;
        responseConsensus : ?variant { Equality; SuperMajority; Absolute };
      },
      text
    ) -> async variant {
      Consistent : variant {
        Ok : EthSendRawTransactionResult;
        Err : text;
      };
      Inconsistent : text;
    };
}

////////////////////////////////////////////////////
// Errors / Results
////////////////////////////////////////////////////
public type TxError = variant {
  NotOwner;
  InvalidSignature;
  NonceTooLow;
  NonceTooHigh;
  InsufficientFunds;
  RpcError : text;
  GenericError : text;
};

public module Result {
  public type Result<OkType, ErrType> = variant {
    ok : OkType;
    err : ErrType;
  };
}

////////////////////////////////////////////////////
// Environment & Network
////////////////////////////////////////////////////
public type DeploymentEnv = {
  #Mainnet;
  #Testnet;
};

public type Network = variant {
  Ethereum : opt Nat;
  Base : opt Nat;
};

public type RemoteNFTPointer = {
  tokenId : Nat;
  contract : Text;
  network : Network;
};

// Example bridging snippet
module Hub {
  public type BridgeArgs = record {
    token : principal;
    from_tx_id : opt text;
    recipient : text;
    target_chain_id : text;
    from_address : opt text;
    amount : nat;
  };
  public type BridgeResponse = record { history_id : nat64 };
  public type HubError = variant { PermissionDenied; };
  public type Result_1 = variant { Ok : BridgeResponse; Err : HubError };
  public type HubService = actor {
    bridge : (BridgeArgs) -> (Result_1);
  };
}

////////////////////////////////////////////////////
// Stable Vars
////////////////////////////////////////////////////
// Owner principal
stable var owner : Principal = Principal.fromText("aaaaa-aa");
// BTreeMap for (derivationPath -> nextNonce)
stable let nonceMap = StableBTreemap.init<Blob, Nat>(1, Blob.compare);
// ECDSA key name
stable var ecdsaKeyName : Text = "dfx_test_key";
// EVM RPC canister ID
stable var evmRpcCanisterId : Principal = principal "7hfb6-caaaa-aaaar-qadga-cai";
// Env setting
stable var env : DeploymentEnv = #Testnet;

////////////////////////////////////////////////////
// Management canister for ECDSA
////////////////////////////////////////////////////
type ICManagement = actor {
  ecdsa_public_key : ({
    canister_id : ?Principal;
    derivation_path : [Blob];
    key_id : { curve : { #secp256k1 }; name : Text };
  }) -> async ({ public_key : Blob; chain_code : Blob });

  sign_with_ecdsa : ({
    message_hash : Blob;
    derivation_path : [Blob];
    key_id : { curve : { #secp256k1 }; name : Text };
  }) -> async ({ signature : Blob });
};

////////////////////////////////////////////////////
// Private Helpers
////////////////////////////////////////////////////
private func is_owner(p : Principal) : Bool {
  // If you do NOT want the controller to have ownership rights, remove this line:
  if (Principal.isController(p)) { 
    return true; 
  };
  p == owner
};

/// getNextNonce : reads/increments stable BTreeMap for concurrency safety
private func getNextNonce(path : Blob) : Nat {
  let existing = nonceMap.get(path);
  switch (existing) {
    case null {
      nonceMap.put(path, 1);
      0
    };
    case (?current) {
      let next = current + 1;
      nonceMap.put(path, next);
      current
    };
  }
};

/// sendToEvmRpc : sends a raw hex transaction to EVM RPC
private func sendToEvmRpc(rawTx : Text) : async Result.Result<Text, TxError> {
  let evmActor = actor(evmRpcCanisterId) : EVMRPC.Service;
  let result = await evmActor.eth_sendRawTransaction({}, null, "0x" # rawTx);

  switch (result) {
    case (#Consistent(#Ok(#Ok(?txHash)))) { #ok(txHash) };
    case (#Consistent(#Ok(#Ok(null))))     { #ok("0x") };
    case (#Consistent(#Ok(#NonceTooLow)))  { #err(#NonceTooLow) };
    case (#Consistent(#Ok(#NonceTooHigh))) { #err(#NonceTooHigh) };
    case (#Consistent(#Ok(#InsufficientFunds))) { #err(#InsufficientFunds) };
    case (#Consistent(#Ok(#Other(err))))   { #err(#RpcError(err)) };
    case (#Consistent(#Err(err)))          { #err(#RpcError(err)) };
    case (#Inconsistent(err))              { #err(#RpcError(err)) };
  }
};

////////////////////////////////////////////////////
// Actor Definition
////////////////////////////////////////////////////
actor {

  //---------------------------------------------
  // Admin & Env Functions
  //---------------------------------------------
  public shared({caller}) func setOwner(newOwner : Principal) : async () {
    if (!is_owner(caller)) {
      Debug.print("Unauthorized attempt to set owner.");
      return;
    };
    owner := newOwner;
  };

  public shared({caller}) func setEnv(newEnv : DeploymentEnv) : async () {
    if (!is_owner(caller)) {
      Debug.print("Unauthorized attempt to set environment.");
      return;
    };
    env := newEnv;
  };

  public shared(query) func getEnv() : async DeploymentEnv {
    env
  }

  public shared(query) func getOwner() : async Principal {
    owner
  }

  //---------------------------------------------
  // ECDSA PubKey & Signing
  //---------------------------------------------
  private func signWithEcdsa(
    msgHash : Blob,
    derivationPath : [Blob]
  ) : async Result.Result<Blob, TxError> {
    try {
      let mgmt : ICManagement = actor("aaaaa-aa");
      // If needed, add cycles: Cycles.add(25_000_000_000);

      let { signature } = await mgmt.sign_with_ecdsa({
        message_hash = msgHash;
        derivation_path = derivationPath;
        key_id = { curve = #secp256k1; name = ecdsaKeyName };
      });
      #ok(signature);
    } catch (err) {
      Debug.print("signWithEcdsa error: " # Error.message(err));
      #err(#GenericError(Error.message(err)));
    }
  }

  private func getEcdsaPublicKey(
    derivationPath : [Blob]
  ) : async Result.Result<Blob, TxError> {
    try {
      let mgmt : ICManagement = actor("aaaaa-aa");
      let { public_key } = await mgmt.ecdsa_public_key({
        canister_id = null;
        derivation_path = derivationPath;
        key_id = { curve = #secp256k1; name = ecdsaKeyName };
      });
      #ok(public_key);
    } catch (err) {
      Debug.print("getEcdsaPublicKey error: " # Error.message(err));
      #err(#GenericError(Error.message(err)));
    }
  }

  /// getEvmAddress : Derive EVM address from secp256k1 pubkey
  public shared(query) func getEvmAddress() : async Text {
    let pkResult = await getEcdsaPublicKey([]);
    switch (pkResult) {
      case (#err(e)) {
        "ERROR_ECDSA_PUBKEY: " # Error.message(e)
      };
      case (#ok(pubKey)) {
        if (pubKey.size() < 65) {
          "ERROR: unexpected pubKey size"
        } else {
          let raw = pubKey[1:65];  // skip 0x04
          let hash = Hash.keccak256(raw);
          let addrBytes = hash[(hash.size() - 20) : hash.size()];
          "0x" # Hex.encode(addrBytes)
        }
      }
    }
  }

  //---------------------------------------------
  // EIP-1559 Generic Calls
  //---------------------------------------------
  public type Eip1559Params = {
    to : Text;
    value : Nat;
    data : [Nat8];
    gasLimit : Nat;
    maxFeePerGas : Nat;
    maxPriorityFeePerGas : Nat;
    chainId : Nat;
    derivationPath : Blob;
  };

  /// eip1559Call : generic EIP-1559 sign & send
  public shared({caller}) func eip1559Call(
    p : Eip1559Params
  ) : async Result.Result<Text, TxError> {
    if (!is_owner(caller)) { return #err(#NotOwner); };

    let nonce = getNextNonce(p.derivationPath);
    let prepRes = EVM.Transaction1559.getMessageToSign({
      chainId = Nat64.fromNat(p.chainId);
      nonce = Nat64.fromNat(nonce);
      maxPriorityFeePerGas = Nat64.fromNat(p.maxPriorityFeePerGas);
      gasLimit = Nat64.fromNat(p.gasLimit);
      maxFeePerGas = Nat64.fromNat(p.maxFeePerGas);
      to = p.to;
      value = p.value;
      data = "0x" # Hex.encode(p.data);
      accessList = [];
      r = "0x00";
      s = "0x00";
      v = "0x00";
    });

    switch (prepRes) {
      case (#err(eMsg)) {
        #err(#GenericError("Transaction1559.getMessageToSign failed: " # eMsg));
      };
      case (#ok(msgToSign)) {
        let signRes = await signWithEcdsa(Blob.fromArray(msgToSign), [p.derivationPath]);
        switch (signRes) {
          case (#err(e)) { #err(e) };
          case (#ok(sig)) {
            if (sig.size() != 64) {
              #err(#InvalidSignature)
            } else {
              let finalTxRes = EVM.Transaction1559.signAndSerialize({
                chainId = Nat64.fromNat(p.chainId);
                nonce = Nat64.fromNat(nonce);
                maxPriorityFeePerGas = Nat64.fromNat(p.maxPriorityFeePerGas);
                gasLimit = Nat64.fromNat(p.gasLimit);
                maxFeePerGas = Nat64.fromNat(p.maxFeePerGas);
                to = p.to;
                value = p.value;
                data = "0x" # Hex.encode(p.data);
                accessList = [];
                r = "0x00";
                s = "0x00";
                v = "0x00";
              }, Blob.toArray(sig), [0x04], null);

              switch (finalTxRes) {
                case (#err(serErr)) {
                  #err(#GenericError("Transaction1559.signAndSerialize failed: " # serErr));
                };
                case (#ok(finalTx)) {
                  let rawTx = Hex.encode(finalTx.1);
                  await sendToEvmRpc(rawTx);
                }
              }
            }
          }
        }
      }
    }
  }

  //---------------------------------------------
  // Mint NFT (Example)
  //---------------------------------------------
  public type MintParams = {
    pointer : RemoteNFTPointer;
    to : Text;
    uri : Text;
    gasLimit : Nat;
    maxFeePerGas : Nat;
    maxPriorityFeePerGas : Nat;
    derivationPath : Blob;
  };

  public shared({caller}) func mintNft(
    p : MintParams
  ) : async Result.Result<Text, TxError> {
    if (!is_owner(caller)) { return #err(#NotOwner); };

    let chainId = switch (p.pointer.network) {
      case (#Ethereum(null)) { 1 };
      case (#Ethereum(?val)) { val };
      case (#Base(null)) { 8453 };
      case (#Base(?val)) { val };
    };

    let methodSig = "mint_icrc99(uint256,address,string)";
    let callData = ABI.encodeFunctionCall(methodSig, [
      ABI.Value.uint256(p.pointer.tokenId),
      ABI.Value.address(ABI.Address.fromText(p.to)),
      ABI.Value.string(p.uri)
    ]);

    let txParams : Eip1559Params = {
      to = p.pointer.contract;
      value = 0;
      data = callData;
      gasLimit = p.gasLimit;
      maxFeePerGas = p.maxFeePerGas;
      maxPriorityFeePerGas = p.maxPriorityFeePerGas;
      chainId = chainId;
      derivationPath = p.derivationPath;
    };

    eip1559Call(txParams)
  }

  //---------------------------------------------
  // BaseSwap Contract Interactions
  //---------------------------------------------
  /// Generic function to call BaseSwap at "0xde151d5c92bfaa288db4b67c21cd55d5826bcc93"
  public type BaseCallParams = {
    chainId : Nat;
    gasLimit : Nat;
    maxFeePerGas : Nat;
    maxPriorityFeePerGas : Nat;
    derivationPath : Blob;
    methodSig : Text;
    args : [ABI.Value];
  };

  public shared({caller}) func callBaseProxyContract(
    p : BaseCallParams
  ) : async Result.Result<Text, TxError> {
    if (!is_owner(caller)) { return #err(#NotOwner); };

    let contractAddr = "0xde151d5c92bfaa288db4b67c21cd55d5826bcc93";
    let callData = ABI.encodeFunctionCall(p.methodSig, p.args);

    let txParams : Eip1559Params = {
      to = contractAddr;
      value = 0;
      data = callData;
      gasLimit = p.gasLimit;
      maxFeePerGas = p.maxFeePerGas;
      maxPriorityFeePerGas = p.maxPriorityFeePerGas;
      chainId = p.chainId;
      derivationPath = p.derivationPath;
    };

    eip1559Call(txParams)
  }

  //---------------------------------------------
  // Approve ERC20 for BaseSwap
  //---------------------------------------------
  /// This is how you might specifically call `approve(address,uint256)`
  public shared({caller}) func baseSwapApprove(
    chainId : Nat,
    derivationPath : Blob,
    tokenAddress : Text,
    spender : Text,
    amount : Nat,
    maxFeePerGas : Nat,
    maxPriorityFeePerGas : Nat,
    gasLimit : Nat
  ) : async Result.Result<Text, TxError> {
    if (!is_owner(caller)) { return #err(#NotOwner); };

    let methodSig = "approve(address,uint256)";
    let callData = ABI.encodeFunctionCall(methodSig, [
      ABI.Value.address(ABI.Address.fromText(spender)),
      ABI.Value.uint256(amount)
    ]);

    let txParams : Eip1559Params = {
      to = tokenAddress;
      value = 0;
      data = callData;
      gasLimit = gasLimit;
      maxFeePerGas = maxFeePerGas;
      maxPriorityFeePerGas = maxPriorityFeePerGas;
      chainId = chainId;
      derivationPath = derivationPath;
    };

    eip1559Call(txParams)
  }

  //---------------------------------------------
  // Increase Liquidity for BaseSwap
  //---------------------------------------------
  public type IncreaseLiquidityParams = {
    chainId : Nat;
    derivationPath : Blob;
    gasLimit : Nat;
    maxFeePerGas : Nat;
    maxPriorityFeePerGas : Nat;
    // The typical arguments for BaseSwap's "increaseLiquidity"
    tokenId : Nat;
    amount0Desired : Nat;
    amount1Desired : Nat;
    amount0Min : Nat;
    amount1Min : Nat;
    recipient : Text;
    deadline : Nat;
  };

  /// A sample specialized function to call `increaseLiquidity(...)` on BaseSwap
  public shared({caller}) func increaseLiquidityBaseSwap(
    p : IncreaseLiquidityParams
  ) : async Result.Result<Text, TxError> {
    if (!is_owner(caller)) { return #err(#NotOwner); };

    // Typically: increaseLiquidity(uint256 tokenId, uint256 amount0Desired, 
    // uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min, 
    // address recipient, uint256 deadline)

    let contractAddr = "0xde151d5c92bfaa288db4b67c21cd55d5826bcc93";
    let methodSig = "increaseLiquidity(uint256,uint256,uint256,uint256,uint256,address,uint256)";
    let callData = ABI.encodeFunctionCall(methodSig, [
      ABI.Value.uint256(p.tokenId),
      ABI.Value.uint256(p.amount0Desired),
      ABI.Value.uint256(p.amount1Desired),
      ABI.Value.uint256(p.amount0Min),
      ABI.Value.uint256(p.amount1Min),
      ABI.Value.address(ABI.Address.fromText(p.recipient)),
      ABI.Value.uint256(p.deadline)
    ]);

    let txParams : Eip1559Params = {
      to = contractAddr;
      value = 0;
      data = callData;
      gasLimit = p.gasLimit;
      maxFeePerGas = p.maxFeePerGas;
      maxPriorityFeePerGas = p.maxPriorityFeePerGas;
      chainId = p.chainId;
      derivationPath = p.derivationPath;
    };

    eip1559Call(txParams)
  }

  //---------------------------------------------
  // SEND ERC20
  //---------------------------------------------
  public type Erc20Params = {
    tokenAddress : Text;
    to : Text;
    amount : Nat;
    gasLimit : Nat;
    maxFeePerGas : Nat;
    maxPriorityFeePerGas : Nat;
    chainId : Nat;
    derivationPath : Blob;
  };

  public shared({caller}) func sendErc20(
    p : Erc20Params
  ) : async Result.Result<Text, TxError> {
    if (!is_owner(caller)) { return #err(#NotOwner); };

    let methodSig = "transfer(address,uint256)";
    let callData = ABI.encodeFunctionCall(methodSig, [
      ABI.Value.address(ABI.Address.fromText(p.to)),
      ABI.Value.uint256(p.amount)
    ]);

    let txParams : Eip1559Params = {
      to = p.tokenAddress;
      value = 0;
      data = callData;
      gasLimit = p.gasLimit;
      maxFeePerGas = p.maxFeePerGas;
      maxPriorityFeePerGas = p.maxPriorityFeePerGas;
      chainId = p.chainId;
      derivationPath = p.derivationPath;
    };

    eip1559Call(txParams)
  }

  //---------------------------------------------
  // MAKE ETH VALUE TRANSACTION (EIP-1559)
  //---------------------------------------------
  public shared({caller}) func makeEthereumValueTrx(request : {
    canisterId : Principal;
    rpcs : EVMRPC.RpcServices;
    to : Text;
    value : Nat;
    gasPrice : Nat;
    gasLimit : Nat;
    maxPriorityFeePerGas : Nat;
    network : Network;
    tecdsaSha : Blob;
    publicKey : [Nat8];
  }) : async Result.Result<Text, TxError> {
    if (!is_owner(caller)) { return #err(#NotOwner); };

    let chainId = switch (request.network) {
      case (#Ethereum(val)) {
        switch (val) {
          case null { 1 };      // default Ethereum mainnet
          case (?cid) { cid };
        }
      };
      case (#Base(val)) {
        switch (val) {
          case null { 8453 };   // default Base mainnet
          case (?cid) { cid };
        }
      };
    };

    // We'll use `gasPrice` as maxFeePerGas, as is typical in a transitional approach
    let txParams : Eip1559Params = {
      to = request.to;
      value = request.value;
      data = "0x";
      gasLimit = request.gasLimit;
      maxFeePerGas = request.gasPrice;
      maxPriorityFeePerGas = request.maxPriorityFeePerGas;
      chainId = chainId;
      derivationPath = request.tecdsaSha;
    };

    eip1559Call(txParams)
  }

  //---------------------------------------------
  // MAKE GENERAL ETH TRANSACTION (EIP-1559)
  //---------------------------------------------
  public shared({caller}) func makeEthereumTrx(request : {
    canisterId : Principal;
    rpcs : EVMRPC.RpcServices;
    method : Text;       
    args : [Nat8];       
    gasPrice : Nat;
    gasLimit : Nat;
    maxPriorityFeePerGas : Nat;
    contract : Text;     
    network : Network;
    tecdsaSha : Blob;    
    publicKey : [Nat8];
  }) : async Result.Result<Text, TxError> {
    if (!is_owner(caller)) { return #err(#NotOwner); };

    let chainId = switch (request.network) {
      case (#Ethereum(val)) {
        switch (val) {
          case null { 1 };
          case (?cid) { cid };
        }
      };
      case (#Base(val)) {
        switch (val) {
          case null { 8453 };
          case (?cid) { cid };
        }
      };
    };

    if (request.method.size() > 0) {
      // Prepend 4-byte selector
      let sha3 = SHA3.Keccak(256);
      sha3.update(Blob.toArray(Text.encodeUtf8(request.method)));
      let methodHash = Array.take<Nat8>(sha3.finalize(), 4);

      let combinedBuf = Buffer.Buffer<Nat8>(0);
      combinedBuf.append(Buffer.fromArray<Nat8>(methodHash));
      combinedBuf.append(Buffer.fromArray<Nat8>(request.args));
      let finalData = Buffer.toArray<Nat8>(combinedBuf);

      let txParams : Eip1559Params = {
        to = request.contract;
        value = 0;
        data = "0x" # Hex.encode(finalData);
        gasLimit = request.gasLimit;
        maxFeePerGas = request.gasPrice;
        maxPriorityFeePerGas = request.maxPriorityFeePerGas;
        chainId = chainId;
        derivationPath = request.tecdsaSha;
      };

      return await eip1559Call(txParams);
    } else {
      return #err(#GenericError("No method provided"));
    }
  }

  //---------------------------------------------
  // BURN BASE TOKEN (Example bridging method)
  //---------------------------------------------
  public shared({caller}) func burnBaseToken(
    chainId : Nat,
    derivationPath : Blob,
    maxFeePerGas : Nat,
    maxPriorityFeePerGas : Nat,
    gasLimit : Nat,
    toChainBytes : [Nat8],
    tokenAddress : Text,
    withdrawAmount : Nat,
    icpAddress : Text
  ) : async Result.Result<Text, TxError> {
    if (!is_owner(caller)) {
      return #err(#NotOwner);
    };

    let helper_contract = "0xDB4270fd1fa025A9403539fA8696092A6451E7FC";
    let methodSig = "burn(bytes,address,uint256,bytes)";
    let chainAddress = formatICPAddressFuc(icpAddress);

    let callData = ABI.encodeFunctionCall(methodSig, [
      ABI.Value.bytes(toChainBytes),
      ABI.Value.address(ABI.Address.fromText(tokenAddress)),
      ABI.Value.uint256(withdrawAmount),
      ABI.Value.bytes(chainAddress)
    ]);

    let txParams : Eip1559Params = {
      to = helper_contract;
      value = 0;
      data = callData;
      gasLimit = gasLimit;
      maxFeePerGas = maxFeePerGas;
      maxPriorityFeePerGas = maxPriorityFeePerGas;
      chainId = chainId;
      derivationPath = derivationPath;
    };

    eip1559Call(txParams)
  }

  // Utility for formatting an ICP principal as [len, principalBytes...]
  private func formatICPAddressFuc(address : Text) : [Nat8] {
    let p = Principal.fromText(address);
    let arr = Principal.toBlob(p);
    let length = Blob.size(arr);

    var newArr = Array.init<Nat8>(length + 1, 0);
    newArr[0] := Nat8.fromNat(length);
    Array.copy<Nat8>(newArr, 1, arr, 0, length);

    newArr
  }
}
