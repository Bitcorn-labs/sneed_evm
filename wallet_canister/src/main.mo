import Debug "mo:base/Debug";
import Principal "mo:base/Principal";
import Prim "mo:prim";
import Hash "mo:base/Hash";

import ABI "mo:encoding.mo/abi";
import EVM "mo:encoding.mo/EVM";
import Hex "mo:encoding.mo/hex";


//1) EVM RPC Canister Interface
module EVMRPC {
  public type RpcServices = {
    // Add fields if needed for your configuration
  };

  // The result variant from the EVM RPC canister's "eth_sendRawTransaction"
  public type EthSendRawTransactionResult = variant {
    Ok : opt text;
    NonceTooLow;
    NonceTooHigh;
    InsufficientFunds;
    Other : text;  // for unexpected errors
  };

  public type Service = actor {
    /// Calls "eth_sendRawTransaction" with the raw signed tx
    /// Returns the transaction hash or an error
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
    err : ErrType 
  };
}

public type Network = variant {
  Ethereum : opt Nat; 
  Base : opt Nat;
};

public type RemoteNFTPointer = {
  tokenId : Nat;
  contract : Text;
  network : Network;
};

stable var owner : Principal = Principal.fromText("aaaaa-aa");
stable var nonceMap : [(blob, Nat)] = [];
stable var ecdsaKeyName : Text = "dfx_test_key";

// Replace with your actual EVM RPC canister principal:
stable var evmRpcCanisterId : Principal = principal "7hfb6-caaaa-aaaar-qadga-cai"; 

actor {

  //
  // A) Basic Owner / Admin
  //
  public shared({caller}) func setOwner(newOwner : Principal) : async () {
    if (caller != owner) { return; }
    owner := newOwner;
  };

  public shared(query) func getOwner() : async Principal {
    return owner;
  }

  //
  // B) EVM Address Derivation
  //
  public shared(query) func getEvmAddress() : async Text {
    let mgmtActor = actor(Prim.managementCanister()) : actor {
      ecdsa_public_key : shared {
        key_name : Text;
        derivation_path : [Blob];
      } -> ({ public_key : Blob; chain_code : Blob })
    };
    let pkRes = await mgmtActor.ecdsa_public_key({
      key_name = ecdsaKeyName;
      derivation_path = [];
    });
    let pubKey = pkRes.public_key;
    if (pubKey.size() < 65) {
      Debug.print("ECDSA pubkey < 65 bytes => " # Nat.toText(pubKey.size()));
      return "ERROR_ECDSA_PUBKEY";
    };
    let raw = pubKey[1:65]; // skip 0x04 prefix
    let hash = Hash.keccak256(raw);
    let addrBytes = hash[(hash.size() - 20) : hash.size()];
    return "0x" # Hex.encode(addrBytes);
  };

  //
  // C) Nonce Management
  //
  private func getNextNonce(path : Blob) : Nat {
    let idx = List.findIndex<Nat>(nonceMap, func((k, _v)) { k == path });
    if (idx == null) {
      nonceMap := nonceMap # [(path, 0)];
      return 0;
    } else {
      let current = nonceMap[idx!].1;
      nonceMap[idx!] := (path, current + 1);
      return current;
    }
  }

  //
  // D) EIP-1559 Transaction
  //
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

  public shared({caller}) func eip1559Call(
    p : Eip1559Params
  ) : async Result.Result<Text, TxError> {
    if (caller != owner) { return #err(#NotOwner); }

    let nonce = getNextNonce(p.derivationPath);

    let #ok(msgHash) = EVM.Transaction1559.getMessageToSign({
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
    }) else {
      return #err(#GenericError("Transaction1559.getMessageToSign failed"));
    };

    let mgmt = actor(Prim.managementCanister()) : actor {
      ecdsa_sign : shared {
        key_name : Text;
        derivation_path : [Blob];
        message_hash : Blob;
      } -> ({ signature : Blob })
    };
    let signRes = await mgmt.ecdsa_sign({
      key_name = ecdsaKeyName;
      derivation_path = [p.derivationPath];
      message_hash = Blob.fromArray(msgHash);
    });
    let signature = signRes.signature;
    if (signature.size() != 64) {
      return #err(#InvalidSignature);
    };

    let #ok(finalTx) = EVM.Transaction1559.signAndSerialize({
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
    }, Blob.toArray(signature), [0x04], null) else {
      return #err(#GenericError("Transaction1559.signAndSerialize failed"));
    };
    let rawTx = Hex.encode(finalTx.1);

    // Now call the EVM RPC canister to actually send
    return await sendToEvmRpc(rawTx);
  };

  private func sendToEvmRpc(rawTx : Text) : async Result.Result<Text, TxError> {
    let evmActor = actor(evmRpcCanisterId) : EVMRPC.Service;
    let result = await evmActor.eth_sendRawTransaction({}, null, "0x" # rawTx);

    switch (result) {
      case (#Consistent(#Ok(#Ok(?txHash)))) { return #ok(txHash); };
      case (#Consistent(#Ok(#Ok(null)))) { return #ok("0x"); };
      case (#Consistent(#Ok(#NonceTooLow))) { return #err(#NonceTooLow); };
      case (#Consistent(#Ok(#NonceTooHigh))) { return #err(#NonceTooHigh); };
      case (#Consistent(#Ok(#InsufficientFunds))) { return #err(#InsufficientFunds); };
      case (#Consistent(#Ok(#Other(err)))) { return #err(#RpcError(err)); };
      case (#Consistent(#Err(err))) { return #err(#RpcError(err)); };
      case (#Inconsistent(err)) { return #err(#RpcError(err)); };
    }
  }

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
    if (caller != owner) { return #err(#NotOwner); }

    let chainId = switch (p.pointer.network) {
      case (#Ethereum(null)) { 1 };
      case (#Ethereum(?v)) { v };
    };
    let sig = "mint_icrc99(uint256,address,string)";
    let callData = ABI.encodeFunctionCall(sig, [
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
    return await eip1559Call(txParams);
  };

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
    if (caller != owner) { return #err(#NotOwner); }

    let methodSig = "transfer(address,uint256)";
    let callData = ABI.encodeFunctionCall(
      methodSig,
      [
        ABI.Value.address(ABI.Address.fromText(p.to)),
        ABI.Value.uint256(p.amount)
      ]
    );
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
    return await eip1559Call(txParams);
  };

 
// 1) baseswap functions  ////////////////////////////
public type BaseCallParams = {
  chainId : Nat;             // e.g. 8453 for Base mainnet
  gasLimit : Nat;            // e.g. 300000
  maxFeePerGas : Nat;        // e.g. 2000000000
  maxPriorityFeePerGas : Nat;// e.g. 1500000000
  derivationPath : Blob;     // your derivation path
  methodSig : Text;          // e.g. "someMethod(uint256,address)"
  args : [ABI.Value];        // ABI-encoded arguments
};

///////////////////////////////////////////////////////////////////
// 2) The function that calls the proxy contract
public shared({caller}) func callBaseProxyContract(
  p : BaseCallParams
) : async Result.Result<Text, TxError> {
  // Optional: check that only the owner can call
  if (caller != owner) {
    return #err(#NotOwner);
  };

  // The specific Base proxy contract address
  let contractAddr = "0xde151d5c92bfaa288db4b67c21cd55d5826bcc93";

  // 1) Encode the function call using Aviate Labs ABI
  let callData = ABI.encodeFunctionCall(p.methodSig, p.args);

  // 2) Build your EIP-1559 transaction parameters
  let eipParams : Eip1559Params = {
    to = contractAddr;
    value = 0;                    // sending 0 base-ETH
    data = callData;
    gasLimit = p.gasLimit;
    maxFeePerGas = p.maxFeePerGas;
    maxPriorityFeePerGas = p.maxPriorityFeePerGas;
    chainId = p.chainId;
    derivationPath = p.derivationPath;
  };

  let #ok(msgHash) = EVM.Transaction1559.getMessageToSign({
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
  }) else {
    return #err(#GenericError("Failed to build unsigned EIP-1559 transaction"));
  };

  // 4) Sign with ECDSA from the management canister
  let mgmt = actor(Prim.managementCanister()) : actor {
    ecdsa_sign : shared {
      key_name : Text;
      derivation_path : [Blob];
      message_hash : Blob;
    } -> ( { signature : Blob } )
  };
  let signRes = await mgmt.ecdsa_sign({
    key_name = ecdsaKeyName;
    derivation_path = [p.derivationPath];
    message_hash = Blob.fromArray(msgHash);
  });
  let signature = signRes.signature;
  if (signature.size() != 64) {
    return #err(#InvalidSignature);
  };

  // 5) Combine signature -> final raw transaction
  let #ok(finalTx) = EVM.Transaction1559.signAndSerialize({
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
  }, Blob.toArray(signature), [0x04], null) else {
    return #err(#GenericError("Failed to sign & serialize EIP-1559 transaction"));
  };
  let rawTx = Hex.encode(finalTx.1);

  // 6) Send the rawTx to the EVM RPC canister
  return await sendToEvmRpc(rawTx);
  };
}




