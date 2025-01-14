import Debug "mo:base/Debug";
import Error "mo:base/Error";
import Principal "mo:base/Principal";
import Prim "mo:prim";
import Cycles "mo:base/ExperimentalCycles";
import Blob "mo:base/Blob";
import Hash "mo:base/Hash";

// Mops dependencies (adjust paths if your setup differs)
import Vector "mo:vector/Vector";
import Candy "mo:candy/Candy";
import Map "mo:map/Map";
import Serde "mo:serde/Serde";
import SHA3 "mo:sha3/SHA3";
import SHA2 "mo:sha2/SHA2";
import TEcdsa "mo:tecdsa/TEcdsa";
import StableBTreemap "mo:stableheapbtreemap/StableBTreemap";
import ICRC7 "mo:icrc7-mo/ICRC7";
import ICRC3 "mo:icrc3-mo/ICRC3";
import ICRC37 "mo:icrc37-mo/ICRC37";
import Star "mo:star/Star";
import LibSecp256k1 "mo:libsecp256k1/LibSecp256k1";
import RLPRelaxed "mo:rlprelaxed/RlpRelaxed";
import EVMTxs "mo:evm-txs/EvmTxs";
import ClassPlus "mo:class-plus/ClassPlus";
import TimerTool "mo:timer-tool/TimerTool";

// For EVM encoding
import ABI "mo:encoding.mo/abi";
import EVM "mo:encoding.mo/EVM";
import Hex "mo:encoding.mo/hex";
import Buffer "mo:buffer/Buffer";

////////////////////////////////////
// 1) EVM RPC definitions
////////////////////////////////////
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

////////////////////////////////////
// 2) Errors + Result
////////////////////////////////////
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

////////////////////////////////////
// 3) Deployment Env + Networks
////////////////////////////////////
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

////////////////////////////////////
// 4) Hub bridging snippet
////////////////////////////////////
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

////////////////////////////////////
// 5) STABLE VARS
////////////////////////////////////
stable var owner : Principal = Principal.fromText("aaaaa-aa");
stable var nonceMap : [(blob, Nat)] = [];
stable var ecdsaKeyName : Text = "dfx_test_key";    // ECDSA key name
stable var evmRpcCanisterId : Principal = principal "7hfb6-caaaa-aaaar-qadga-cai"; 
stable var env : DeploymentEnv = #Testnet; 

////////////////////////////////////
// 6) Management canister for ECDSA
////////////////////////////////////
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

////////////////////////////////////
// 7) getHubPrincipal
////////////////////////////////////
private func getHubPrincipal(e : DeploymentEnv) : Principal {
  switch e {
    case (#Mainnet) { principal "n6ii2-2yaaa-aaaaj-azvia-cai" };
    case (#Testnet) { principal "l5h5f-miaaa-aaaal-qjioq-cai" };
  }
}

////////////////////////////////////
// 8) The actor
////////////////////////////////////
actor {

  ////////////////////////////////////
  // A) Ownership checks
  ////////////////////////////////////
  private func is_owner(p : Principal) : Bool {
    if (Principal.isController(p)) { return true; }
    if (p == owner) { return true; }
    false
  };

  public shared({caller}) func setOwner(newOwner : Principal) : async () {
    if (!is_owner(caller)) { return; }
    owner := newOwner;
  };

  public shared({caller}) func setEnv(newEnv : DeploymentEnv) : async () {
    if (!is_owner(caller)) { return; }
    env := newEnv;
  };

  public shared(query) func getEnv() : async DeploymentEnv {
    env
  }

  public shared(query) func getOwner() : async Principal {
    owner
  }

  ////////////////////////////////////
  // B) ECDSA calls
  ////////////////////////////////////
  private func signWithEcdsa(
    msgHash : Blob,
    derivationPath : [Blob]
  ) : async Result.Result<Blob, TxError> {
    try {
      let mgmt : ICManagement = actor("aaaaa-aa");
      // optionally add cycles e.g. Cycles.add(25_000_000_000);

      let { signature } = await mgmt.sign_with_ecdsa({
        message_hash = msgHash;
        derivation_path = derivationPath;
        key_id = { curve = #secp256k1; name = ecdsaKeyName };
      });
      #ok(signature);
    } catch (err) {
      Debug.print(Error.message(err));
      #err(#GenericError(Error.message(err)));
    }
  }

  private func getEcdsaPublicKey(derivationPath : [Blob]) : async Result.Result<Blob, TxError> {
    try {
      let mgmt : ICManagement = actor("aaaaa-aa");
      let { public_key } = await mgmt.ecdsa_public_key({
        canister_id = null;
        derivation_path = derivationPath;
        key_id = { curve = #secp256k1; name = ecdsaKeyName };
      });
      #ok(public_key);
    } catch (err) {
      Debug.print(Error.message(err));
      #err(#GenericError(Error.message(err)));
    }
  }

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
          let raw = pubKey[1:65];
          let hash = Hash.keccak256(raw);
          let addrBytes = hash[(hash.size() - 20) : hash.size()];
          "0x" # Hex.encode(addrBytes)
        }
      }
    }
  };

  ////////////////////////////////////
  // C) Nonce Management
  ////////////////////////////////////
  private func getNextNonce(path : Blob) : Nat {
    let idx = List.findIndex<Nat>(nonceMap, func((k, _v)) { k == path });
    if (idx == null) {
      nonceMap := nonceMap # [(path, 0)];
      0
    } else {
      let current = nonceMap[idx!].1;
      nonceMap[idx!] := (path, current + 1);
      current
    }
  }

  ////////////////////////////////////
  // D) sendToEvmRpc
  ////////////////////////////////////
  private func sendToEvmRpc(rawTx : Text) : async Result.Result<Text, TxError> {
    let evmActor = actor(evmRpcCanisterId) : EVMRPC.Service;
    let result = await evmActor.eth_sendRawTransaction({}, null, "0x" # rawTx);
    switch (result) {
      case (#Consistent(#Ok(#Ok(?txHash)))) { #ok(txHash) };
      case (#Consistent(#Ok(#Ok(null)))) { #ok("0x") };
      case (#Consistent(#Ok(#NonceTooLow))) { #err(#NonceTooLow) };
      case (#Consistent(#Ok(#NonceTooHigh))) { #err(#NonceTooHigh) };
      case (#Consistent(#Ok(#InsufficientFunds))) { #err(#InsufficientFunds) };
      case (#Consistent(#Ok(#Other(err)))) { #err(#RpcError(err)) };
      case (#Consistent(#Err(err))) { #err(#RpcError(err)) };
      case (#Inconsistent(err)) { #err(#RpcError(err)) };
    }
  }

  ////////////////////////////////////
  // E) EIP-1559 structure
  ////////////////////////////////////
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

  ////////////////////////////////////
  // F) eip1559Call => improved ECDSA usage
  ////////////////////////////////////
  public shared({caller}) func eip1559Call(p : Eip1559Params) : async Result.Result<Text, TxError> {
    if (!is_owner(caller)) { return #err(#NotOwner) };
    let nonce = getNextNonce(p.derivationPath);

    let #ok(msgToSign) = EVM.Transaction1559.getMessageToSign({
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

    let signResult = await signWithEcdsa(Blob.fromArray(msgToSign), [p.derivationPath]);
    switch (signResult) {
      case (#err(e)) { #err(e) };
      case (#ok(signature)) {
        if (signature.size() != 64) {
          #err(#InvalidSignature)
        } else {
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
          await sendToEvmRpc(rawTx);
        }
      }
    }
  }

  ////////////////////////////////////
  // G) Example: mintNft => uses eip1559Call
  ////////////////////////////////////
  public type MintParams = {
    pointer : RemoteNFTPointer;
    to : Text;
    uri : Text;
    gasLimit : Nat;
    maxFeePerGas : Nat;
    maxPriorityFeePerGas : Nat;
    derivationPath : Blob;
  };

  public shared({caller}) func mintNft(p : MintParams) : async Result.Result<Text, TxError> {
    if (!is_owner(caller)) { return #err(#NotOwner) };
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

  ////////////////////////////////////
  // H) Additional calls: bridging, etc.
  ////////////////////////////////////
  private func hubActor() : Hub.HubService {
    actor(getHubPrincipal(env)) : Hub.HubService
  }

  public shared({caller}) func bridgeBaseToIcrc(
    tokenPid : principal,
    fromTxId : ?Text,
    fromAddress : Text,
    recipientIcrc : Text,
    amount : Nat
  ) : async Hub.Result_1 {
    if (!is_owner(caller)) {
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
    await hubActor().bridge(bridgeArgs)
  }

  ////////////////////////////////////
  // I) A function to call a base contract with eip1559Call
  ////////////////////////////////////
  public type BaseCallParams = {
    chainId : Nat;            
    gasLimit : Nat;           
    maxFeePerGas : Nat;       
    maxPriorityFeePerGas : Nat;
    derivationPath : Blob;    
    methodSig : Text;         
    args : [ABI.Value];
  };

  public shared({caller}) func callBaseProxyContract(p : BaseCallParams) : async Result.Result<Text, TxError> {
    if (!is_owner(caller)) { return #err(#NotOwner) };
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

  ////////////////////////////////////
  // J) Additional specialized methods 
  ////////////////////////////////////
  // like sendErc20, makeEthereumTrx, etc. 
  // We'll define them below:

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
    if (!is_owner(caller)) { return #err(#NotOwner) };
    let sig = "transfer(address,uint256)";
    let callData = ABI.encodeFunctionCall(sig, [
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
    if (!is_owner(caller)) { return #err(#NotOwner) };
    // build EIP-1559 data => call eip1559Call(...)
    #err(#GenericError("Implementation omitted for brevity; adapt from eip1559Call."))
  }

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
    if (!is_owner(caller)) { return #err(#NotOwner) };
    // build methodSig => encode => eip1559Call => signWithEcdsa
    #err(#GenericError("Implementation omitted for brevity; adapt from eip1559Call."))
  }

  // K) If you have a "burnBaseToken(...)" for a 4-arg burn(...) signature, do similarly:
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
    let callData = ABI.encodeFunctionCall(
      methodSig,
      [
        ABI.Value.bytes(toChainBytes),
        ABI.Value.address(ABI.Address.fromText(tokenAddress)),
        ABI.Value.uint256(withdrawAmount),
        ABI.Value.bytes(chainAddress)
      ]
    );
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

  // L) Format ICP principal => [length, principalBytes...]
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
