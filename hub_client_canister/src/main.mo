import Hub "hub_client_canister/hub.did";
import Debug "mo:base/Debug";

public type DeploymentEnv = {
  #Mainnet;
  #Testnet;
};

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

module ICRC1 {
  public type BalanceOfArgs = {
    owner : blob;
    subaccount : ?blob;
  };

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

  stable var env : DeploymentEnv = #Testnet;

  stable var blacklistedAddresses : [Text] = ["poopoo", "peepee"];

  public shared({caller}) func setDeploymentEnv(newEnv : DeploymentEnv) : async () {
    env := newEnv;
  };

  private func hubActor() : Hub.service {
    let pid = getHubCanisterId(env);
    return actor(pid) : Hub.service;
  };

  public shared(msg) func bridgeICRCToken(
    tokenPid : principal,
    fromTxId : ?Text,
    recipientEvmAddress : Text,
    fromAddress : ?Text,
    amount : Nat
  ) : async Hub.Result_1 {

    let chainId = getTargetChainId(env);
    Debug.print(
      "Bridging tokens => chain=" # chainId
      # ", recipient=" # recipientEvmAddress
      # ", amount=" # Nat.toText(amount)
    );

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

  public shared(msg) func add_cached_events(events : [Hub.CachedRelayerEvent]) : async Hub.Result {
    return await hubActor().add_cached_events(events);
  };

  public shared(msg) func add_chains(chains : [Hub.AddChainArgs]) : async Hub.Result {
    return await hubActor().add_chains(chains);
  };

  public shared(msg) func add_token_chain(args : Hub.AddTokenChainArgs) : async Hub.Result {
    return await hubActor().add_token_chain(args);
  };

  public shared(msg) func add_tokens(tokens : [Hub.AddTokenArgs]) : async Hub.Result {
    return await hubActor().add_tokens(tokens);
  };

  public shared(msg) func claimed(args : Hub.ClaimedArg) : async Hub.Result_2 {
    return await hubActor().claimed(args);
  };

  public shared(msg) func delete_cached_event(eventId : Text) : async Hub.Result {
    return await hubActor().delete_cached_event(eventId);
  };

  public shared(query) func get_admin() : async principal {
    return await hubActor().get_admin();
  };

  public shared(msg) func get_assets_by_chain_id(chainId : Text) : async Hub.Result_3 {
    return await hubActor().get_assets_by_chain_id(chainId);
  };

  public shared(msg) func get_assets_by_token_pid(tokenPid : principal) : async Hub.Result_3 {
    return await hubActor().get_assets_by_token_pid(tokenPid);
  };

  public shared(query) func get_chain(chainId : Text) : async ?Hub.SupportedChain {
    return await hubActor().get_chain(chainId);
  };

  public shared(query) func get_histories(args : Hub.GetHistoryRequest) : async Hub.GetHistoryResponse {
    return await hubActor().get_histories(args);
  };

  public shared(query) func get_minter_address_of_chain(chainId : Text) : async ?Text {
    return await hubActor().get_minter_address_of_chain(chainId);
  };

  public shared(query) func get_protocol_fee_percentage() : async ?Nat16 {
    return await hubActor().get_protocol_fee_percentage();
  };

  public shared(query) func get_support_chains() : async [Hub.SupportedChain] {
    return await hubActor().get_support_chains();
  };

  public shared(query) func get_support_tokens() : async [Hub.SupportedToken] {
    return await hubActor().get_support_tokens();
  };

  public shared(msg) func pause() : async Hub.Result {
    return await hubActor().pause();
  };

  public shared(msg) func resume() : async Hub.Result {
    return await hubActor().resume();
  };

  public shared(msg) func set_protocol_fee_percentage(fee : Nat16) : async Hub.Result {
    return await hubActor().set_protocol_fee_percentage(fee);
  };

  public shared(query) func sync_histories(args : Hub.SyncHistoryRequest) : async Hub.SyncHistoryResponse {
    return await hubActor().sync_histories(args);
  };

  public shared(msg) func update_chain(args : Hub.AddChainArgs) : async Hub.Result {
    return await hubActor().update_chain(args);
  };

  public shared(msg) func update_token(args : Hub.AddTokenArgs) : async Hub.Result {
    return await hubActor().update_token(args);
  };

  public shared(msg) func update_token_chain_address(args : Hub.AddTokenChainArgs) : async Hub.Result {
    return await hubActor().update_token_chain_address(args);
  };

  public shared(query) func validate_send_icrc1_tokens(
    tokenCanister : principal,
    from : Text,
    to : Text,
    amount : Nat
  ) : async Bool {
    // 1) blacklisted check
    if (blacklistedAddresses.contains(to)) {
      Debug.print("Address blacklisted => " # to);
      return false;
    };
    // 2) disallow from == to
    if (from == to) {
      Debug.print("Cannot send to self => " # from);
      return false;
    };
    // 3) check balance
    let icrc1Actor = actor(tokenCanister) : ICRC1.ICRC1Service;
    let fromBlob = textToBlob(from);
    let bal = await icrc1Actor.icrc1_balance_of({owner = fromBlob; subaccount = null});
    Debug.print("Balance of " # from # " => " # Nat.toText(bal));
    if (bal < amount) {
      Debug.print("Not enough balance => " # Nat.toText(bal) # " < " # Nat.toText(amount));
      return false;
    };
    return true;
  };

  public shared(msg) func send_icrc1_tokens(
    tokenCanister : principal,
    from : Text,
    to : Text,
    amount : Nat,
    fee : ?Nat
  ) : async ICRC1.TransferResult {

    Debug.assert(is_owner(msg.caller));
    let canSend = await validate_send_icrc1_tokens(tokenCanister, from, to, amount);
    if (!canSend) {
      return #err(#GenericError({
        message = "Validation failed, cannot send",
        error_code = 200
      }));
    };

    let icrc1Actor = actor(tokenCanister) : ICRC1.ICRC1Service;

    let tArgs : ICRC1.TransferArgs = {
      from_subaccount = subAcc;
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

  private func textToBlob(acc : Text) : Blob {
    return Text.encodeUtf8(acc);
  };

  private func is_owner(principal : Principal) : Bool { 
  if (Principal.isController(principal)) { return true; };
  if (Principal.fromText("sneed-gov-here") == principal) { return true; };
  return false;
  };

  // A debug helper
  private func debug_show<T>(x : T) : text {
    return Debug.printable(x);
  };
}
