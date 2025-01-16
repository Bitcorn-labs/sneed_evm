import Debug "mo:base/Debug";
import Error "mo:base/Error";
import Principal "mo:base/Principal";
//import StableBTreeMap "mo:stableheapbtreemap/BTree";
import EVM "./EVM";
import EVMRPC "./EVMRPC";
import ABI "./ABI";
import Hub "./Hub";
import Buffer "mo:base/Buffer";
import Cycles "mo:base/ExperimentalCycles";
import Blob "mo:base/Blob";
import Hash "mo:base/Hash";
import Text "mo:base/Text";
import Result "mo:base/Result";
import Array "mo:base/Array";
import SHA3 "mo:sha3";
import Nat8 "mo:base/Nat8";
import Nat64 "mo:base/Nat64";
import Hex "./Hex";
import Iter "mo:base/Iter";
import StableTrieMap "mo:stable-trie/Map";
// Data structure for concurrency-safe nonce management

// Additional or optional imports
//import ICRC7 "mo:icrc7-mo/ICRC7";
//import ICRC3 "mo:icrc3-mo/ICRC3";
//import ICRC37 "mo:icrc37-mo/ICRC37";
//import Star "mo:star/Star";
//import LibSecp256k1 "mo:libsecp256k1/LibSecp256k1";
//import RLPRelaxed "mo:rlprelaxed/RlpRelaxed";
//import EVMTxs "mo:evm-txs/EvmTxs";
//import ClassPlus "mo:class-plus/ClassPlus";
//import TimerTool "mo:timer-tool/TimerTool";

// EVM encoding

//import EVM "mo:evm-txs/Transaction";
//import ABI "./ABI";
//import Hex "mo:encoding/Hex";
//import Binary "mo:encoding/Binary";
import Types "./Types";

////////////////////////////////////////////////////
// Actor Definition
////////////////////////////////////////////////////
actor {

////////////////////////////////////////////////////
// Stable Vars
////////////////////////////////////////////////////
// Owner principal
stable var owner : Principal = Principal.fromText("aaaaa-aa");
// BTreeMap for (derivationPath -> nextNonce)
//stable let nonceMap = StableBTreeMap.init<Blob, Nat>(?1, Blob.compare);
/*stable*/ var nonceMap = StableTrieMap.Map({
    pointer_size = 2;
    aridity = 2;
    root_aridity = null;
    key_size = 2;
    value_size = 1;
}); //StableTrieMap.init<Blob, Nat>();
// ECDSA key name
stable var ecdsaKeyName : Text = "Key_1";
// EVM RPC canister ID
stable var evmRpcCanisterId : Principal = Principal.fromText("7hfb6-caaaa-aaaar-qadga-cai");
// Env setting
stable var env : EVMRPC.DeploymentEnv = #Testnet;

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

  //---------------------------------------------
  // Admin & Env Functions
  //---------------------------------------------
  public shared({caller}) func setOwner(newOwner : Principal) : async () {
    if (not is_owner(caller)) {
      Debug.print("Unauthorized attempt to set owner.");
      return;
    };
    owner := newOwner;
  };

  public shared({caller}) func setEnv(newEnv : EVMRPC.DeploymentEnv) : async () {
    if (not is_owner(caller)) {
      Debug.print("Unauthorized attempt to set environment.");
      return;
    };
    env := newEnv;
  };

  public query func getEnv() : async EVMRPC.DeploymentEnv {
    env
  };

  public query func getOwner() : async Principal {
    owner
  };

  //---------------------------------------------
  // ECDSA PubKey & Signing
  //---------------------------------------------
  private func signWithEcdsa(
    msgHash : Blob,
    derivationPath : [Blob]
  ) : async Result.Result<Blob, EVMRPC.TxError> {
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
  };

  private func getEcdsaPublicKey(
    derivationPath : [Blob]
  ) : async Result.Result<Blob, EVMRPC.TxError> {
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
  };

  /// getEvmAddress : Derive EVM address from secp256k1 pubkey
  public shared func getEvmAddress() : async Text {
    let pkResult = await getEcdsaPublicKey([]);
    switch (pkResult) {
      case (#err(e)) {
        let msg = switch(e) {
          case (#GenericError(text)) { text };
          case (#InsufficientFunds) { "Insufficient funds" };
          case (#InvalidSignature) { "Invalid signature" };
          case (#NonceTooHigh) { "Nonce too high" };
          case (#NonceTooLow) { "Nonce too low" };
          case (#NotOwner) { "Not owner" };
          case (#RpcError(text)) { text };
        };
        "ERROR_ECDSA_PUBKEY: " # msg
      };
      case (#ok(pubKey)) {
        if (pubKey.size() < 65) {
          "ERROR: unexpected pubKey size"
        } else {
          let raw = Array.tabulate<Nat8>(64, func(i) { 
            Blob.toArray(pubKey)[i + 1]  // skip 0x04
          });
          let sha3 = SHA3.Keccak(256);
          sha3.update(raw);
          let hash = sha3.finalize();
          let addrBytes = Array.subArray(hash, hash.size() - 20, 20);
          "0x" # Hex.encode(addrBytes)
        };
      };
    };
  };

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
  ) : async Result.Result<Text, EVMRPC.TxError> {
    if (not is_owner(caller)) { return #err(#NotOwner); };

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
                };
              };
            };
          };
        };
      };
    };
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

  private func natToBlob(n : Nat) : Blob {
    let bytes = Buffer.Buffer<Nat8>(8);
    var num = n;
    while (num > 0) {
      bytes.add(Nat8.fromNat(num % 256));
      num /= 256;
    };
    Blob.fromArray(Buffer.toArray(bytes))
  };

  private func blobToNat(b : Blob) : Nat {
    var num = 0;
    let bytes = Blob.toArray(b);
    for (i in Iter.range(0, bytes.size() - 1)) {
      num := num * 256 + Nat8.toNat(bytes[i]);
    };
    num
  };

  /// getNextNonce : reads/increments stable BTreeMap for concurrency safety
  private func getNextNonce(path : Blob) : Nat {
    let existing = nonceMap.get(path);
    switch (existing) {
        case null {
            nonceMap.put(path, natToBlob(1));
            0
        };
        case (?current) {
            let currentNat = blobToNat(current);
            let next = currentNat + 1;
            nonceMap.put(path, natToBlob(next));
            currentNat
        };
    };
  };

  /// sendToEvmRpc : sends a raw hex transaction to EVM RPC
  private func sendToEvmRpc(rawTx : Text) : async Result.Result<Text, EVMRPC.TxError> {
    let evmActor = actor(Principal.toText(evmRpcCanisterId)) : EVMRPC.Service;
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

  //---------------------------------------------
  // Mint NFT (Example)
  //---------------------------------------------
  public type MintParams = {
    pointer : EVMRPC.RemoteNFTPointer;
    to : Text;
    uri : Text;
    gasLimit : Nat;
    maxFeePerGas : Nat;
    maxPriorityFeePerGas : Nat;
    derivationPath : Blob;
  };

  public shared({caller}) func mintNft(
    p : MintParams
  ) : async Result.Result<Text, EVMRPC.TxError> {
    if (not is_owner(caller)) { return #err(#NotOwner); };

    let chainId = switch (p.pointer.network) {
      case (#Ethereum(null)) { 1 };
      case (#Ethereum(?val)) { val };
      case (#Base(null)) { 8453 };
      case (#Base(?val)) { val };
    };

    let methodSig = "mint_icrc99(uint256,address,string)";
    let callData = ABI.encodeFunctionCall(methodSig, [
      ABI.Value.uint256(p.pointer.tokenId),
      ABI.Value.address(p.to),
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

    await eip1559Call(txParams)
  };

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
    args : [[Nat8]];
  };

  public shared({caller}) func callBaseProxyContract(
    p : BaseCallParams
  ) : async Result.Result<Text, EVMRPC.TxError> {
    if (not is_owner(caller)) { return #err(#NotOwner); };

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

    await eip1559Call(txParams)
  };

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
  ) : async Result.Result<Text, EVMRPC.TxError> {
    if (not is_owner(caller)) { return #err(#NotOwner); };

    let methodSig = "approve(address,uint256)";
    let callData = ABI.encodeFunctionCall(methodSig, [
      ABI.Value.address(spender),
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

    await eip1559Call(txParams)
  };

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
  ) : async Result.Result<Text, EVMRPC.TxError> {
    if (not is_owner(caller)) { return #err(#NotOwner); };

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
      ABI.Value.address(p.recipient),
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

    await eip1559Call(txParams)
  };

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
  ) : async Result.Result<Text, EVMRPC.TxError> {
    if (not is_owner(caller)) { return #err(#NotOwner); };

    let methodSig = "transfer(address,uint256)";
    let callData = ABI.encodeFunctionCall(methodSig, [
      ABI.Value.address(p.to),
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

    await eip1559Call(txParams)
  };

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
    network : EVMRPC.Network;
    tecdsaSha : Blob;
    publicKey : [Nat8];
  }) : async Result.Result<Text, EVMRPC.TxError> {
    if (not is_owner(caller)) { return #err(#NotOwner); };

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
      data = [];  // Empty byte array instead of "0x"
      gasLimit = request.gasLimit;
      maxFeePerGas = request.gasPrice;
      maxPriorityFeePerGas = request.maxPriorityFeePerGas;
      chainId = chainId;
      derivationPath = request.tecdsaSha;
    };

    await eip1559Call(txParams)
  };

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
    network : EVMRPC.Network;
    tecdsaSha : Blob;    
    publicKey : [Nat8];
  }) : async Result.Result<Text, EVMRPC.TxError> {
    if (not is_owner(caller)) { return #err(#NotOwner); };

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
        data = finalData;
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
  };

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
  ) : async Result.Result<Text, EVMRPC.TxError> {
    if (not is_owner(caller)) {
      return #err(#NotOwner);
    };

    let helper_contract = "0xDB4270fd1fa025A9403539fA8696092A6451E7FC";
    let methodSig = "burn(bytes,address,uint256,bytes)";
    let chainAddress = formatICPAddressFuc(icpAddress);

    let callData = ABI.encodeFunctionCall(methodSig, [
      ABI.Value.bytes(toChainBytes),
      ABI.Value.address(tokenAddress),
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

    await eip1559Call(txParams);
  };

  // Utility for formatting an ICP principal as [len, principalBytes...]
  private func formatICPAddressFuc(address : Text) : [Nat8] {
    let p = Principal.fromText(address);
    let arr = Principal.toBlob(p);
    let length = Blob.toArray(arr).size();

    var newArr = Array.init<Nat8>(length + 1, 0);
    newArr[0] := Nat8.fromNat(length);
    
    let blobArr = Blob.toArray(arr);
    for (i in Iter.range(0, length - 1)) {
        newArr[i + 1] := blobArr[i];
    };

    Array.freeze(newArr)
  };
};
