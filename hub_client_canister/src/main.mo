import Hub "./hub";
import Debug "mo:base/Debug";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Nat "mo:base/Nat";
import Array "mo:base/Array";
import ICRC1 "ICRC1";

//ICRC-1 calls
actor {

  public type DeploymentEnv = { #Mainnet; #Testnet };

  func getHubCanisterId(env : DeploymentEnv) : Principal {
    switch (env) {
      case (#Mainnet) { Principal.fromText("n6ii2-2yaaa-aaaaj-azvia-cai")};   // mainnet
      case (#Testnet) { Principal.fromText("l5h5f-miaaa-aaaal-qjioq-cai")};   // testnet
    }
  };

  func getTargetChainId(env : DeploymentEnv) : Text {
    switch (env) {
      case (#Mainnet) { "base" };
      case (#Testnet) { "base_sepolia" };
    }
  };

  // stable environment var (Mainnet|Testnet)
  stable var env : DeploymentEnv = #Testnet;

  // blacklist
  stable var blacklistedAddresses : [Text] = ["poopoo", "peepee"];

  // Set environment
  public shared({caller}) func setDeploymentEnv(newEnv : DeploymentEnv) : async () {
    // Optional: check owner
    env := newEnv;
  };

  // Return an actor reference to the Hub canister
  private func hubActor() : Hub.service {
    let pid = Principal.toText(getHubCanisterId(env));
    return actor(pid) : Hub.service;
  };

  // Bridge ICRC token to Base (mainnet or testnet)
  public shared(msg) func bridgeICRCToken(
    tokenPid : Principal,
    fromTxId : ?Text,
    recipientEvmAddress : Text,
    fromAddress : ?Text,
    amount : Nat
  ) : async Hub.Result_1 {
    let chainId = getTargetChainId(env);
    Debug.print("Bridging tokens => chain=" # chainId
      # ", recipient=" # recipientEvmAddress
      # ", amount=" # Nat.toText(amount));

    let bridgeArgs : Hub.BridgeArgs = {
      token = tokenPid;
      from_tx_id = fromTxId;
      recipient = recipientEvmAddress;
      target_chain_id = chainId;
      from_address = fromAddress;
      amount = amount;
    };

    return await hubActor().bridge(bridgeArgs);
  };

  // Check if address is blacklisted
  private func isBlacklisted(addr : Text) : Bool {
    for (blacklisted in blacklistedAddresses.vals()) {
      if (blacklisted == addr) return true;
    };
    false
  };

  // ICRC-1 validation logic
  public query func validate_send_icrc1_tokens(
    tokenCanister : Principal,
    from : Text,
    to : Text,
    amount : Nat,
    fee : ?Nat
  ) : async Bool {
    let blacklisted = Array.find<Text>(blacklistedAddresses, func(x) { x == to });
    switch (blacklisted) {
      case (?_) {
        Debug.print("Address blacklisted => " # to);
        return false;
      };
      case null {};
    };
    if (from == to) {
      Debug.print("Cannot send to self => " # from);
      return false;
    };
    // check balances
    // No real need to check balances since the icrc1_transfer will just fail
    // if no sufficient balance exists.
    /*let icrc1Actor = actor(tokenCanister) : ICRC1.ICRC1Service;
    let fromBlob = textToBlob(from);
    let bal = await icrc1Actor.icrc1_balance_of({owner = fromBlob; subaccount = null});
    Debug.print("Balance of " # from # " => " # Nat.toText(bal));
    if (bal < amount) {
      Debug.print("Not enough balance => " # Nat.toText(bal) # " < " # Nat.toText(amount));
      return false;
    };*/
    true;
  };

  // Send ICRC tokens
  public shared(msg) func send_icrc1_tokens(
    tokenCanister : Principal,
    from : Text,
    to : Text,
    amount : Nat,
    fee : ?Nat
  ) : async ICRC1.TransferResult {
    Debug.print("Attempting to send ICRC from=" # from # " to=" # to # " amt=" # Nat.toText(amount));
    let canSend = await validate_send_icrc1_tokens(tokenCanister, from, to, amount, fee);
    if (not canSend) {
      return #Err(#GenericError({
        message = "Validation failed, cannot send";
        error_code = 200;
      }));
    };

    let icrc1Actor = actor(Principal.toText(tokenCanister)) : ICRC1.ICRC1Service;

    let tArgs : ICRC1.TransferArgs = {
      from_subaccount = null;   // or some subaccount if needed
      to = textToBlob(to);
      fee = fee;
      created_at_time = null;
      memo = null;
      amount = amount;
    };

    let result = await icrc1Actor.icrc1_transfer(tArgs);
    Debug.print("ICRC1 transfer result => " # debug_show(result));
    return result;
  };

  // A text->blob helper
  private func textToBlob(acc : Text) : Blob {
    return Text.encodeUtf8(acc);
  };

  // `debug_show`
  //private func debug_show<T>(x : T) : text {
  //  return Debug.printable(x);
  //};

  private func is_owner(principal : Principal) : Bool { 
  if (Principal.isController(principal)) { return true; };
  if (Principal.fromText("sneed-gov-here") == principal) { return true; };
  return false;
  };

}
