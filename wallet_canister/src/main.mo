import Debug "mo:base/Debug";
import Principal "mo:base/Principal";
import Prim "mo:prim";
import Hash "mo:base/Hash";
import ABI "mo:encoding.mo/abi";
import EVM "mo:encoding.mo/EVM";
import Hex "mo:encoding.mo/hex";
import Buffer "mo:buffer/Buffer";
import SHA3 "mo:crypto/sha3";

// 1) EVM RPC
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

// 2) Error + Result
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

// 3) Network + NFT
public type Network = variant {
  Ethereum : opt Nat; 
  Base : opt Nat;
};

public type RemoteNFTPointer = {
  tokenId : Nat;
  contract : Text;
  network : Network;
};

// 4) Hub bridging snippet
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

// 5) STABLE VARS
stable var owner : Principal = Principal.fromText("aaaaa-aa");
stable var nonceMap : [(blob, Nat)] = [];
stable var ecdsaKeyName : Text = "Key_1";
stable var evmRpcCanisterId : Principal = principal "7hfb6-caaaa-aaaar-qadga-cai";
stable var hubCanisterPid : Principal = principal "n6ii2-2yaaa-aaaaj-azvia-cai";

// 6) The Actor
actor {

  // Private check for ownership (canister controller or stable var "owner")
  private func is_owner(p : Principal) : Bool {
    if (Principal.isController(p)) { return true; }
    if (p == owner) { return true; }
    return false;
  };

  public shared({caller}) func setOwner(newOwner : Principal) : async () {
    if (! is_owner(caller)) { return; }
    owner := newOwner;
  };

  public shared(query) func getOwner() : async Principal {
    return owner;
  }

  public shared(query) func getEvmAddress() : async Text {
    let mgmt = actor(Prim.managementCanister()) : actor {
      ecdsa_public_key : shared {
        key_name : Text;
        derivation_path : [Blob];
      } -> ({ public_key : Blob; chain_code : Blob })
    };
    let res = await mgmt.ecdsa_public_key({
      key_name = ecdsaKeyName;
      derivation_path = [];
    });
    let pubKey = res.public_key;
    if (pubKey.size() < 65) {
      Debug.print("ECDSA pubkey < 65 bytes => " # Nat.toText(pubKey.size()));
      return "ERROR_ECDSA_PUBKEY";
    };
    let raw = pubKey[1:65];
    let hash = Hash.keccak256(raw);
    let addrBytes = hash[(hash.size() - 20) : hash.size()];
    return "0x" # Hex.encode(addrBytes);
  };

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
    if (! is_owner(caller)) { return #err(#NotOwner); }
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
    return await sendToEvmRpc(rawTx);
  };

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
    if (! is_owner(caller)) { return #err(#NotOwner); }
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
    let thisNonce = getNextNonce(request.tecdsaSha);
    let #ok(msgToSign) = EVM.Transaction1559.getMessageToSign({
      chainId = Nat64.fromNat(chainId);
      nonce = Nat64.fromNat(thisNonce);
      maxPriorityFeePerGas = Nat64.fromNat(request.maxPriorityFeePerGas);
      gasLimit = Nat64.fromNat(request.gasLimit);
      maxFeePerGas = Nat64.fromNat(request.gasPrice);
      to = request.to;
      value = request.value;
      data = "0x";
      accessList = [];
      r = "0x00";
      s = "0x00";
      v = "0x00";
    }) else {
      return #err(#GenericError("Failed to build messageToSign"));
    };
    let mgmt = actor(Prim.managementCanister()) : actor {
      ecdsa_sign : shared {
        key_name : Text;
        derivation_path : [Blob];
        message_hash : Blob;
      } -> ({ signature : Blob })
    };
    let sres = await mgmt.ecdsa_sign({
      key_name = ecdsaKeyName;
      derivation_path = [request.tecdsaSha];
      message_hash = Blob.fromArray(msgToSign);
    });
    let sigBytes = sres.signature;
    if (sigBytes.size() != 64) {
      return #err(#InvalidSignature);
    };
    let #ok(finalTx) = EVM.Transaction1559.signAndSerialize({
      chainId = Nat64.fromNat(chainId);
      nonce = Nat64.fromNat(thisNonce);
      maxPriorityFeePerGas = Nat64.fromNat(request.maxPriorityFeePerGas);
      gasLimit = Nat64.fromNat(request.gasLimit);
      maxFeePerGas = Nat64.fromNat(request.gasPrice);
      to = request.to;
      value = request.value;
      data = "0x";
      accessList = [];
      r = "0x00";
      s = "0x00";
      v = "0x00";
    }, sigBytes, request.publicKey, null) else {
      return #err(#GenericError("signAndSerialize failed"));
    };
    let rawTx = Hex.encode(finalTx.1);
    return await sendToEvmRpc(rawTx);
  };

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
    if (! is_owner(caller)) { return #err(#NotOwner); }
    let chainId = switch (request.network) {
      case (#Ethereum(val)) {
        switch (val) {
          case(null) { 1 };
          case(?cid) { cid };
        }
      };
      case (#Base(val)) {
        switch (val) {
          case(null) { 8453 };
          case(?cid) { cid };
        }
      };
    };
    var abiBytes = request.args;
    if (request.method.size() > 0) {
      let sha3 = SHA3.Keccak(256);
      sha3.update(Blob.toArray(Text.encodeUtf8(request.method)));
      let methodHash = Array.take<Nat8>(sha3.finalize(), 4);
      let buf = Buffer.Buffer<Nat8>(0);
      buf.append(Buffer.fromArray<Nat8>(methodHash));
      buf.append(Buffer.fromArray<Nat8>(abiBytes));
      abiBytes := Buffer.toArray<Nat8>(buf);
    };
    let thisNonce = getNextNonce(request.tecdsaSha);
    let #ok(msgToSign) = EVM.Transaction1559.getMessageToSign({
      chainId = Nat64.fromNat(chainId);
      nonce = Nat64.fromNat(thisNonce);
      maxPriorityFeePerGas = Nat64.fromNat(request.maxPriorityFeePerGas);
      gasLimit = Nat64.fromNat(request.gasLimit);
      maxFeePerGas = Nat64.fromNat(request.gasPrice);
      to = request.contract;
      value = 0;
      data = "0x" # Hex.encode(abiBytes);
      accessList = [];
      r = "0x00";
      s = "0x00";
      v = "0x00";
    }) else {
      return #err(#GenericError("Failed to get messageToSign"));
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
      derivation_path = [request.tecdsaSha];
      message_hash = Blob.fromArray(msgToSign);
    });
    let signature = signRes.signature;
    if (signature.size() != 64) {
      return #err(#InvalidSignature);
    };
    let #ok(finalTx) = EVM.Transaction1559.signAndSerialize({
      chainId = Nat64.fromNat(chainId);
      nonce = Nat64.fromNat(thisNonce);
      maxPriorityFeePerGas = Nat64.fromNat(request.maxPriorityFeePerGas);
      gasLimit = Nat64.fromNat(request.gasLimit);
      maxFeePerGas = Nat64.fromNat(request.gasPrice);
      to = request.contract;
      value = 0;
      data = "0x" # Hex.encode(abiBytes);
      accessList = [];
      r = "0x00";
      s = "0x00";
      v = "0x00";
    }, Blob.toArray(signature), request.publicKey, null) else {
      return #err(#GenericError("signAndSerialize for makeEthereumTrx failed"));
    };
    let rawTx = Hex.encode(finalTx.1);
    return await sendToEvmRpc(rawTx);
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
    if (! is_owner(caller)) { return #err(#NotOwner); }
    let chainId = switch (p.pointer.network) {
      case (#Ethereum(null)) { 1 };
      case (#Ethereum(?v)) { v };
      case (#Base(null)) { 8453 };
      case (#Base(?val)) { val };
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
    if (! is_owner(caller)) { return #err(#NotOwner); }
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
    return await eip1559Call(txParams);
  };

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
    if (! is_owner(caller)) { return #err(#NotOwner); }
    let contractAddr = "0xde151d5c92bfaa288db4b67c21cd55d5826bcc93";
    let callData = ABI.encodeFunctionCall(p.methodSig, p.args);
    let eipParams : Eip1559Params = {
      to = contractAddr;
      value = 0;
      data = callData;
      gasLimit = p.gasLimit;
      maxFeePerGas = p.maxFeePerGas;
      maxPriorityFeePerGas = p.maxPriorityFeePerGas;
      chainId = p.chainId;
      derivationPath = p.derivationPath;
    };
    return await eip1559Call(eipParams);
  };

  private func hubActor() : Hub.HubService {
    return actor(hubCanisterPid) : Hub.HubService;
  }

  public shared({caller}) func bridgeBaseToIcrc(
    tokenPid : principal,
    fromTxId : ?Text,
    fromAddress : Text,
    recipientIcrc : Text,
    amount : Nat
  ) : async Hub.Result_1 {
    if (! is_owner(caller)) {
      return #Err(#PermissionDenied);
    };
    let bridgeArgs : Hub.BridgeArgs = {
      token = tokenPid;
      from_tx_id = fromTxId;
      recipient = recipientIcrc;
      target_chain_id = "icp";
      from_address = ?fromAddress;
      amount = amount;
    };
    return await hubActor().bridge(bridgeArgs);
  }
}
