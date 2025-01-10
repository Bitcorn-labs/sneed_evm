import Debug "mo:base/Debug";
import Principal "mo:base/Principal";
import Prim "mo:prim";
import Hash "mo:base/Hash";

// Aviate labs imports
import ABI "mo:encoding.mo/abi";
import EVM "mo:encoding.mo/EVM";
import Hex "mo:encoding.mo/hex";

// 1) EVM RPC definitions
module EVMRPC {
  public type RpcServices = {};
  public type Service = actor {
    eth_sendRawTransaction : (
      RpcServices,
      ?{
        responseSizeEstimate : ?nat64;
        responseConsensus : ?variant { Equality; SuperMajority; Absolute; };
      },
      text
    ) -> async variant {
      Consistent : variant {
        Ok : variant {
          Ok : opt text;
          NonceTooLow;
          NonceTooHigh;
          InsufficientFunds;
        };
        Err : text;
      };
      Inconsistent : text;
    };

    eth_call : (
      RpcServices,
      ?{
        responseSizeEstimate : ?nat64;
        responseConsensus : ?variant { Equality; SuperMajority; Absolute; };
      },
      text
    ) -> async text;  // raw hex data
  };
}

// 2) Errors & results
public type RemoteError = variant {
  GenericError : text;
  RPC : variant {
    EthereumMultiSend : variant {
      Consistent : variant {
        Ok : variant {
          Ok : opt text;
          NonceTooLow;
          NonceTooHigh;
          InsufficientFunds;
        };
        Err : text;
      };
      Inconsistent : text;
    }
  };
};

public module Result {
  public type Result<OkType, ErrType> = variant { ok : OkType; err : ErrType };
}

// 3) Some environment definitions (like "Network")
public type Network = variant {
  Ethereum : opt Nat;
};

// For NFT references
public type RemoteNFTPointer = {
  tokenId : Nat;
  contract : Text;
  network : Network;
};

// stable state (nonceMap, tecdsaKeyName, etc.)
stable var state = {
  nonceMap = ({} : { /*some DS*/ }),
  settings = {
    tecdsaKeyName = "dfx_test_key"
  },
  cycleSettings = {
    tecdsaSigCost = 10_000_000_000 : nat,
    baseCharge = 1_000_000_000 : nat,
    bytesPerEthTransferRequest = 100_000_000 : nat
  }
};

let debug_channel = { announce = true };
private func debug_show<T>(x : T) : text { return Debug.printable(x); }

module Cycles {
  public func add<system>(n : nat) : () {}
  public func refunded() : nat { return 0 }
}

module Map {
  public func get<K, V>(
    _map : { /*some DS*/ },
    _hashing : shared (K -> Blob),
    key : K
  ) : ?V { return null; }

  public func put<K, V>(
    _map : { /*some DS*/ },
    _hashing : shared (K -> Blob),
    key : K,
    value : V
  ) : () {}
}

// trivial hashing
public shared func bhash(k : Blob) : Blob {
  return k;
}

// ECDSA canister or mgmt approach
public type ICTECDSA = actor {
  sign_with_ecdsa : ({
    message_hash : Blob;
    derivation_path : [Blob];
    key_id : {
      curve : variant { secp256k1 };
      name : Text;
    }
  }) -> ({ signature : Blob })
};

// ---------------------------------------------------------------------------
// The main actor
// ---------------------------------------------------------------------------
actor {

  stable var owner : Principal = Principal.fromText("aaaaa-aa");

  public shared({caller}) func setOwner(newOwner : Principal) : async () {
    if (caller != owner) {
      Debug.print("Unauthorized setOwner attempt by " # caller.toText());
      return;
    };
    owner := newOwner;
  };

  //
  // 1) EVM address from ECDSA public key
  //
  public shared(query) func getEvmAddress() : async Text {
    let mgmtActor = actor(Prim.managementCanister()) : actor {
      ecdsa_public_key : shared {
        key_name : Text;
        derivation_path : [Blob];
      } -> ({ public_key : Blob; chain_code : Blob })
    };
    let pkRes = await mgmtActor.ecdsa_public_key({
      key_name = state.settings.tecdsaKeyName;
      derivation_path = [];
    });
    let pubKey = pkRes.public_key;
    if (pubKey.size() < 65) {
      return "ERROR: unexpected pubkey length";
    };
    let pubKeyNoPrefix = pubKey[1:65];
    let hash = Hash.keccak256(pubKeyNoPrefix);
    let addrBytes = hash[(hash.size() - 20) : hash.size()];
    return "0x" # Hex.encode(addrBytes);
  };

  // -------------------------------------------------------------------------
  // 2) Mint an NFT => "mint_icrc99(uint256,address,string)" 
  // -------------------------------------------------------------------------
  private func makeEthereumMint(request : {
    canisterId : Principal;
    rpcs : EVMRPC.RpcServices;
    pointer : RemoteNFTPointer;
    icrc99_canister : Principal;
    targetOwner : Text;
    uri : Text;
    gasPrice : Nat;
    gasLimit : Nat;
    maxPriorityFeePerGas : Nat;
    publicKey : [Nat8];
  }) : async* (Result.Result<Text, RemoteError>, Nat) {

    debug if (debug_channel.announce)
      Debug.print(debug_show(("Minting Ethereum NFT =>",
                              request.pointer.tokenId,
                              request.targetOwner,
                              request.uri)));

    // 2.1) Build the ABI call
    let methodSig = "mint_icrc99(uint256,address,string)";
    let callData = ABI.encodeFunctionCall(
      methodSig,
      [
        ABI.Value.uint256(request.pointer.tokenId),
        ABI.Value.address(ABI.Address.fromText(request.targetOwner)),
        ABI.Value.string(request.uri)
      ]
    );

    // 2.2) We'll do an EIP-1559 transaction => call "makeEthereumTrx"
    let chainId = switch(request.pointer.network) {
      case (#Ethereum(null)) { 1 };
      case (#Ethereum(?cid)) { cid };
      case (_) { 1 };
    };

    let tecdsaPath = get_icrc99_hash(request.icrc99_canister, request.pointer.network);

    return await* makeEthereumTrx({
      canisterId = request.canisterId;
      rpcs = request.rpcs;
      method = methodSig;
      args = callData;
      gasPrice = request.gasPrice;
      gasLimit = request.gasLimit;
      maxPriorityFeePerGas = request.maxPriorityFeePerGas;
      contract = request.pointer.contract;
      network = request.pointer.network;
      tecdsaSha = tecdsaPath;
      publicKey = request.publicKey;
      sendValue = 0;
    });
  };

  //
  // 3) Send ERC-20 tokens => "transfer(address,uint256)"
  //
  private func sendErc20Token(request : {
    canisterId : Principal;
    rpcs : EVMRPC.RpcServices;
    tokenAddress : Text;
    to : Text;
    amount : Nat;
    gasPrice : Nat;
    gasLimit : Nat;
    maxPriorityFeePerGas : Nat;
    network : Network;
    publicKey : [Nat8];
  }) : async* (Result.Result<Text, RemoteError>, Nat) {

    debug if(debug_channel.announce)
      Debug.print(debug_show(("Sending ERC20 =>", request.amount, request.to)));

    let methodSig = "transfer(address,uint256)";
    let callData = ABI.encodeFunctionCall(
      methodSig,
      [
        ABI.Value.address(ABI.Address.fromText(request.to)),
        ABI.Value.uint256(request.amount)
      ]
    );

    // build EIP-1559
    let chainId = switch(request.network) {
      case (#Ethereum(null)) { 1 };
      case (#Ethereum(?cid)) { cid };
      case (_) { 1 };
    };

    return await* makeEthereumTrx({
      canisterId = request.canisterId;
      rpcs = request.rpcs;
      method = methodSig;
      args = callData;
      gasPrice = request.gasPrice;
      gasLimit = request.gasLimit;
      maxPriorityFeePerGas = request.maxPriorityFeePerGas;
      contract = request.tokenAddress;
      network = request.network;
      tecdsaSha = Blob.fromArray([0,1,2]); // or real derivation
      publicKey = request.publicKey;
      sendValue = 0;
    });
  };

  //
  // 4) Check ERC-20 balance => "balanceOf(address) -> uint256" 
  //    via read-only eth_call
  //
  private func getErc20BalanceOf(
    canisterId : Principal,
    rpcs : EVMRPC.RpcServices,
    tokenAddress : Text,
    ownerAddr : Text
  ) : async ?Nat {
    let methodSig = "balanceOf(address)";
    let callData = ABI.encodeFunctionCall(
      methodSig,
      [ ABI.Value.address(ABI.Address.fromText(ownerAddr)) ]
    );

    // call "eth_call"
    let rpcActor = actor(canisterId) : EVMRPC.Service;
    let hexData = "0x" # Hex.encode(callData);

    // We might need a JSON body for the call. This depends on your EVM RPC canister’s format.
    let callBody = buildEthCallBody(tokenAddress, hexData);
    let resultHex = await rpcActor.eth_call(rpcs, null, callBody);

    if (Text.startsWith(resultHex, "0x")) {
      let rawBytes = Hex.decodeToBytes(Text.substr(resultHex, 2, Text.size(resultHex)-2));
      let number = ABI.decodeUint256(rawBytes);
      return ?number;
    } else {
      Debug.print("eth_call result not hex => " # resultHex);
      return null;
    }
  };

  private func buildEthCallBody(toAddress : Text, data : Text) : Text {
    // If your canister expects raw JSON:
    return 
      "{ \"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{ \"to\":\"" 
      # toAddress # "\", \"data\":\"" # data # "\"}, \"latest\"], \"id\":1}";
  };

  //
  // 5) Make an EIP-1559 transaction => sign & broadcast 
  //
  private func makeEthereumTrx(request : {
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
    sendValue : Nat;
  }) : async* (Result.Result<Text, RemoteError>, Nat) {

    let chainId = switch(request.network) {
      case (#Ethereum(null)) { 1 };
      case (#Ethereum(?cid)) { cid };
      case (_) { 1 };
    };

    // get nonce
    let thisNonce = switch(Map.get(state.nonceMap, bhash, request.tecdsaSha)) {
      case (?nonce) nonce;
      case null { 0 };
    };
    Map.put(state.nonceMap, bhash, request.tecdsaSha, thisNonce + 1);

    let #ok(msgToSign) = EVM.Transaction1559.getMessageToSign({
      chainId = Nat64.fromNat(chainId);
      nonce = Nat64.fromNat(thisNonce);
      maxPriorityFeePerGas = Nat64.fromNat(request.maxPriorityFeePerGas);
      gasLimit = Nat64.fromNat(request.gasLimit);
      maxFeePerGas = Nat64.fromNat(request.gasPrice);
      to = request.contract;
      value = request.sendValue;
      data = "0x" # Hex.encode(request.args);
      accessList = [];
      r = "0x00";
      s = "0x00";
      v = "0x00";
    }) else {
      return (#err(#GenericError("Failed to get msg to sign")), state.cycleSettings.baseCharge);
    };

    // sign
    let server : ICTECDSA = actor("aaaaa-aa"); // your ECDSA approach
    Cycles.add<system>(state.cycleSettings.tecdsaSigCost);
    let { signature } = await server.sign_with_ecdsa({
      message_hash = Blob.fromArray(msgToSign);
      derivation_path = [request.tecdsaSha];
      key_id = {
        curve = #secp256k1;
        name = state.settings.tecdsaKeyName;
      };
    });
    let sigBytes = Blob.toArray(signature);

    // finalize
    let as_serialized = EVM.Transaction1559.signAndSerialize({
      chainId = Nat64.fromNat(chainId);
      nonce = Nat64.fromNat(thisNonce);
      maxPriorityFeePerGas = Nat64.fromNat(request.maxPriorityFeePerGas);
      gasLimit = Nat64.fromNat(request.gasLimit);
      maxFeePerGas = Nat64.fromNat(request.gasPrice);
      to = request.contract;
      value = request.sendValue;
      data = "0x" # Hex.encode(request.args);
      accessList = [];
      r = "0x00";
      s = "0x00";
      v = "0x00";
    }, sigBytes, request.publicKey, null);

    let trxBytes = switch(as_serialized) {
      case (#ok(txRes)) { Hex.encode(txRes.1) };
      case (#err(errMsg)) {
        return (#err(#GenericError(errMsg)), state.cycleSettings.baseCharge);
      };
    };

    let result = await* ethSendTrx(
      request.canisterId,
      ?chainId,
      request.rpcs,
      trxBytes,
      state.cycleSettings.bytesPerEthTransferRequest
    );

    switch(result.0) {
      case (#ok(txHash)) {
        return (#ok(txHash), result.1);
      };
      case (#err(err)) {
        switch(err) {
          case (#RPC(#EthereumMultiSend(#Consistent(#Ok(#NonceTooLow))))) {
            return (#err(#GenericError("Nonce too low")), state.cycleSettings.baseCharge);
          };
          case (#RPC(#EthereumMultiSend(#Consistent(#Ok(#NonceTooHigh))))) {
            Map.put(state.nonceMap, bhash, request.tecdsaSha, thisNonce - 1);
            return (#err(#GenericError("Nonce too high")), state.cycleSettings.baseCharge);
          };
          case (_) {
            return (#err(err), result.1);
          };
        }
      };
    }
  }

  //
  // 6) Actually send "eth_sendRawTransaction"
  //
  private func ethSendTrx(
    canisterId : Principal,
    chainId : ?Nat,
    rpcs : EVMRPC.RpcServices,
    trx : Text,
    maxBytes : Nat
  ) : async* (Result.Result<Text, RemoteError>, Nat) {
    let rpcActor = actor(canisterId) : EVMRPC.Service;
    var cyclesCharged = state.cycleSettings.baseCharge;

    let finalTxt = if (Text.startsWith(trx, "0x")) { trx } else { "0x" # trx };

    Cycles.add<system>(cyclesCharged);

    let result = await rpcActor.eth_sendRawTransaction(
      rpcs,
      ?{
        responseSizeEstimate = ?Nat64.fromNat(maxBytes);
        responseConsensus = ?#Equality;
      },
      finalTxt
    );

    let refunded = Cycles.refunded();
    if (refunded < cyclesCharged) {
      cyclesCharged -= refunded;
    };

    switch(result) {
      case (#Consistent(#Ok(#Ok(?trxHash)))) {
        return (#ok(trxHash), cyclesCharged);
      };
      case (#Consistent(#Ok(#Ok(null)))) {
        return (#err(#GenericError("Sent TRX but result was null")), cyclesCharged);
      };
      case (#Consistent(#Ok(#NonceTooLow))) {
        return (#err(#RPC(#EthereumMultiSend(result))), cyclesCharged);
      };
      case (#Consistent(#Ok(#NonceTooHigh))) {
        return (#err(#RPC(#EthereumMultiSend(result))), cyclesCharged);
      };
      case (#Consistent(#Ok(#InsufficientFunds))) {
        return (#err(#GenericError("InsufficientFunds")), cyclesCharged);
      };
      case (#Consistent(#Err(err))) {
        return (#err(#RPC(#EthereumMultiSend(#Consistent(#Err(err))))), cyclesCharged);
      };
      case (#Inconsistent(err)) {
        return (#err(#RPC(#EthereumMultiSend(#Inconsistent(err)))), cyclesCharged);
      };
    }
  }

  //
  // 7) Public wrappers
  //
  // a) Mint an NFT
  public shared({caller}) func doEthereumMintNFT(
    canisterId : Principal,
    rpcs : EVMRPC.RpcServices,
    pointer : RemoteNFTPointer,
    icrc99_canister : Principal,
    targetOwner : Text,
    uri : Text,
    gasPrice : Nat,
    gasLimit : Nat,
    maxPriorityFeePerGas : Nat,
    publicKey : [Nat8]
  ) : async (Result.Result<Text, RemoteError>, Nat) {
    if (caller != owner) {
      return (#err(#GenericError("not owner")), 0);
    };
    return await* makeEthereumMint({
      canisterId; rpcs; pointer; icrc99_canister; targetOwner; uri;
      gasPrice; gasLimit; maxPriorityFeePerGas; publicKey
    });
  }

  // b) Send an ERC-20
  public shared({caller}) func sendErc20(
    canisterId : Principal,
    rpcs : EVMRPC.RpcServices,
    tokenAddress : Text,
    to : Text,
    amount : Nat,
    gasPrice : Nat,
    gasLimit : Nat,
    maxPriorityFeePerGas : Nat,
    network : Network,
    publicKey : [Nat8]
  ) : async (Result.Result<Text, RemoteError>, Nat) {
    if (caller != owner) {
      return (#err(#GenericError("not owner")), 0);
    };
    return await* sendErc20Token({
      canisterId; rpcs; tokenAddress; to; amount;
      gasPrice; gasLimit; maxPriorityFeePerGas; network; publicKey
    });
  }

  // c) Get the balance
  public shared(query) func getErc20Balance(
    canisterId : Principal,
    rpcs : EVMRPC.RpcServices,
    tokenAddress : Text
  ) : async ?Nat {
    let ownerAddr = await getEvmAddress();
    return await getErc20BalanceOf(canisterId, rpcs, tokenAddress, ownerAddr);
  }
  
  // If you want a function to see your stable map, debug, etc. do so as needed.

  //
  // 8) If bridging from hub_client_canister => tokens arrive automatically 
  //    at the EVM address derived above, no special "receive" function needed in Motoko.
  //
}

// end of file
