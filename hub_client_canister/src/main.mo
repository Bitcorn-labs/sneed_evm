import Hub "hub_client_canister/hub.did";  // The .did that reflects the n6ii2-2yaaa-aaaaj-azvia-cai canister
import Debug "mo:base/Debug";
import Principal "mo:base/Principal";
import Text "mo:base/Text";

// 1) Environment type
public type DeploymentEnv = { #Mainnet; #Testnet };

// 2) Map env => Hub canister ID
func getHubCanisterId(env : DeploymentEnv) : principal {
  switch (env) {
    case (#Mainnet) { principal "n6ii2-2yaaa-aaaaj-azvia-cai" };   // mainnet
    case (#Testnet) { principal "l5h5f-miaaa-aaaal-qjioq-cai" };   // testnet
  }
};

// 3) Map env => target chain ID
func getTargetChainId(env : DeploymentEnv) : Text {
  switch (env) {
    case (#Mainnet) { "base" };
    case (#Testnet) { "base_sepolia" };
  }
};

// 4) If you do ICRC-1 calls
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

  // 5) A stable environment var (Mainnet|Testnet)
  stable var env : DeploymentEnv = #Testnet;

  // 6) Example blacklist
  stable var blacklistedAddresses : [Text] = ["poopoo", "peepee"];

  // 7) Set environment
  public shared({caller}) func setDeploymentEnv(newEnv : DeploymentEnv) : async () {
    // Optional: check owner if needed
    env := newEnv;
  };

  // 8) Return an actor reference to the Hub canister
  private func hubActor() : Hub.service {
    let pid = getHubCanisterId(env);
    return actor(pid) : Hub.service;
  };

  // 9) Bridge ICRC token to Base (mainnet or testnet)
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

  // 10) Example methods re-exported from the Hub
  public shared(msg) func add_cached_events(events : [Hub.CachedRelayerEvent]) : async Hub.Result {
    return await hubActor().add_cached_events(events);
  };

  public shared(msg) func add_chains(chains : [Hub.AddChainArgs]) : async Hub.Result {
    return await hubActor().add_chains(chains);
  };

  // ... etc. We keep them the same as your code ...
  public shared(msg) func pause() : async Hub.Result {
    // calls the Hub canister’s `pause()` method
    return await hubActor().pause();
  };

  public shared(msg) func resume() : async Hub.Result {
    return await hubActor().resume();
  };

  // 11) Example new methods for "burn(...)" or "owner()" if your .did has them
  //
  // If your .did includes something like:
  // service : { burn : (BurnArgs) -> (Result); owner : () -> (principal) query; ... }
  // we can wrap them:

  // Example: if your DID has "burn(args: BurnArgs) : Result"
  // public shared(msg) func burn(args : Hub.BurnArgs) : async Hub.Result {
  //   return await hubActor().burn(args);
  // };

  // If it has "owner() : principal query;"
  // public shared(query) func getBridgeOwner() : async principal {
  //   return await hubActor().owner();
  // };

  // 12) ICRC-1 validation logic
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

  // 13) Actually send ICRC tokens
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

  // 14) A text->blob helper
  private func textToBlob(acc : Text) : Blob {
    return Text.encodeUtf8(acc);
  };

  // 15) Example `debug_show`
  private func debug_show<T>(x : T) : text {
    return Debug.printable(x);
  };

  // 16) A new or improved ownership check
  // If you want to keep "sneed-gov-here" logic, do so here
  private func is_canister_owner(principal : Principal) : Bool {
    // e.g. stable var owner, or some advanced logic
    if (principal == owner) { return true };
    // or check if Principal.isController(principal)
    false
  };
}
