import Debug "mo:base/Debug";
import Error "mo:base/Error";
import Principal "mo:base/Principal";
import Prim "mo:prim";
import Cycles "mo:base/ExperimentalCycles";
import Blob "mo:base/Blob";
import Hash "mo:base/Hash";

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
stable var ecdsaKeyName : Text = "dfx_test_key";    // ECDSA key name
stable var evmRpcCanisterId : Principal = principal "7hfb6-caaaa-aaaar-qadga-cai"; 
stable var env : DeploymentEnv = #Testnet; 


// Management canister for ECDSA
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

private func getHubPrincipal(e : DeploymentEnv) : Principal {
  switch e {
    case (#Mainnet) { principal "n6ii2-2yaaa-aaaaj-azvia-cai" };
    case (#Testnet) { principal "l5h5f-miaaa-aaaal-qjioq-cai" };
  }
}

actor {

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

  // ECDSA calls
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

  // Nonce Management
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

  // sendToEvmRpc
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

  // E) EIP-1559 structure
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

  // eip1559Call = generic to call evm contracts
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

  // baseswap contract calls
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

  /// A record describing the parameters for increaseLiquidity:
public type IncreaseLiquidityParams = {
  chainId : Nat;
  derivationPath : Blob;
  gasLimit : Nat;
  maxFeePerGas : Nat;
  maxPriorityFeePerGas : Nat;

  // the function arguments
  token0 : Text;          // e.g. "0xToken0"
  token1 : Text;          // e.g. "0xToken1"
  amount0Desired : Nat;
  amount1Desired : Nat;
  amount0Min : Nat;
  amount1Min : Nat;
  recipient : Text;       // e.g. "0xRecipient"
  deadline : Nat;
};

//send erc20 token
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
  if (!is_owner(caller)) { 
    return #err(#NotOwner); 
  };

  // 1) Determine chainId from `request.network`
  let chainId = switch (request.network) {
    case (#Ethereum(val)) {
      switch (val) {
        case null { 1 };         // default to Ethereum mainnet
        case (?cid) { cid };     // or user-specified chain ID
      }
    };
    case (#Base(val)) {
      switch (val) {
        case null { 8453 };      // default to Base mainnet
        case (?cid) { cid };
      }
    };
  };

  // 2) Build the EIP-1559 parameters
  let txParams : Eip1559Params = {
    to = request.to;
    value = request.value;
    // no extra data => purely sending ETH => "0x"
    data = "0x";
    gasLimit = request.gasLimit;
    maxFeePerGas = request.gasPrice;           // `gasPrice` is your maxFeePerGas
    maxPriorityFeePerGas = request.maxPriorityFeePerGas;
    chainId = chainId;
    derivationPath = request.tecdsaSha;
  };

  // 3) Reuse your eip1559Call(...) => signs + broadcasts the EIP-1559 transaction
  return await eip1559Call(txParams);
}

  public shared({caller}) func makeEthereumTrx(request : {
  canisterId : Principal;
  rpcs : EVMRPC.RpcServices;
  method : Text;       // e.g. "transfer(address,uint256)"
  args : [Nat8];       // raw ABI data or partial
  gasPrice : Nat;
  gasLimit : Nat;
  maxPriorityFeePerGas : Nat;
  contract : Text;     // e.g. "0xERC20Contract"
  network : Network;
  tecdsaSha : Blob;    // derivation path
  publicKey : [Nat8];
}) : async Result.Result<Text, TxError> {
  if (!is_owner(caller)) { 
    return #err(#NotOwner); 
  };

  // 1) Determine chainId from `request.network`
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

  // 2) If you want to automatically prepend the 4-byte method hash for `request.method`
  //    we can do something like:
  if (request.method.size() > 0) {
    let sha3 = SHA3.Keccak(256);
    sha3.update(Blob.toArray(Text.encodeUtf8(request.method)));
    let methodHash = Array.take<Nat8>(sha3.finalize(), 4);

    // combine methodHash + request.args
    let combinedBuf = Buffer.Buffer<Nat8>(0);
    combinedBuf.append(Buffer.fromArray<Nat8>(methodHash));
    combinedBuf.append(Buffer.fromArray<Nat8>(request.args));

    let finalData = Buffer.toArray<Nat8>(combinedBuf);

    // 3) Build EIP-1559 params
    let txParams : Eip1559Params = {
      to = request.contract;
      value = 0;      // no value transfer
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

  // bito bridge burn function (send base token, specict icp chain id)
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

  // Format ICP principal => [length, principalBytes...]
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
