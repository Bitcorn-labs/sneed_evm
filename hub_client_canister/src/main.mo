import Hub "hub_client_canister/hub.did"; 
import Debug "mo:base/Debug";
import Principal "mo:base/Principal";
import Text "mo:base/Text";

//ICRC-1 calls
module ICRC1 {
  public type BalanceOfArgs = { owner : blob; subaccount : ?blob };
  public type TransferArgs = {
    from_subaccount : ?blob;
    to : blob;
    fee : ?nat;
    created_at_time : ?nat64;
    memo : ?blob;
    amount : nat;
  };
  public type TransferError = variant {
    BadFee : record { expected_fee : nat };
    BadBurn : record { min_burn_amount : nat };
    InsufficientFunds : record { balance : nat };
    TooOld;
    CreatedInFuture : record { ledger_time : nat64 };
    Duplicate : record { duplicate_of : nat64 };
    TemporarilyUnavailable;
    GenericError : record { message : text; error_code : nat };
  };
  public type TransferResult = variant { Ok : nat; Err : TransferError };
  public type ICRC1Service = actor {
    icrc1_balance_of : (BalanceOfArgs) -> (nat) query;
    icrc1_transfer : (TransferArgs) -> (TransferResult);
  };
}

actor {

public type DeploymentEnv = { #Mainnet; #Testnet };

func getHubCanisterId(env : DeploymentEnv) : principal {
  switch (env) {
    case (#Mainnet) { principal "n6ii2-2yaaa-aaaaj-azvia-cai" };   // mainnet
    case (#Testnet) { principal "l5h5f-miaaa-aaaal-qjioq-cai" };   // testnet
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
    let pid = getHubCanisterId(env);
    return actor(pid) : Hub.service;
  };

  // Bridge ICRC token to Base (mainnet or testnet)
  public shared(msg) func bridgeICRCToken(
    tokenPid : principal,
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

  // ICRC-1 validation logic
  public shared(query) func validate_send_icrc1_tokens(
    tokenCanister : principal,
    from : Text,
    to : Text,
    amount : Nat
  ) : async Bool {
    if (blacklistedAddresses.contains(to)) {
      Debug.print("Address blacklisted => " # to);
      return false;
    };
    if (from == to) {
      Debug.print("Cannot send to self => " # from);
      return false;
    };
    // check balances
    let icrc1Actor = actor(tokenCanister) : ICRC1.ICRC1Service;
    let fromBlob = textToBlob(from);
    let bal = await icrc1Actor.icrc1_balance_of({owner = fromBlob; subaccount = null});
    Debug.print("Balance of " # from # " => " # Nat.toText(bal));
    if (bal < amount) {
      Debug.print("Not enough balance => " # Nat.toText(bal) # " < " # Nat.toText(amount));
      return false;
    };
    true;
  };

  // Send ICRC tokens
  public shared(msg) func send_icrc1_tokens(
    tokenCanister : principal,
    from : Text,
    to : Text,
    amount : Nat,
    fee : ?Nat
  ) : async ICRC1.TransferResult {
    Debug.print("Attempting to send ICRC from=" # from # " to=" # to # " amt=" # Nat.toText(amount));
    let canSend = await validate_send_icrc1_tokens(tokenCanister, from, to, amount);
    if (!canSend) {
      return #err(#GenericError({
        message = "Validation failed, cannot send",
        error_code = 200
      }));
    };

    let icrc1Actor = actor(tokenCanister) : ICRC1.ICRC1Service;

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
  private func debug_show<T>(x : T) : text {
    return Debug.printable(x);
  };

  private func is_owner(principal : Principal) : Bool { 
  if (Principal.isController(principal)) { return true; };
  if (Principal.fromText("sneed-gov-here") == principal) { return true; };
  return false;
  };

}
