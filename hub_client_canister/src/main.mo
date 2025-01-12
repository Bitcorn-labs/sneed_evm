import Hub "hub_client_canister/hub.did";
import Debug "mo:base/Debug";

// 1) Environment type for bridging (Mainnet vs. Testnet)
public type DeploymentEnv = {
  #Mainnet;
  #Testnet;
};

/// Return the Hub canister principal for each environment
func getHubCanisterId(env : DeploymentEnv) : principal {
  switch (env) {
    case (#Mainnet) { principal "n6ii2-2yaaa-aaaaj-azvia-cai" };  // mainnet
    case (#Testnet) { principal "l5h5f-miaaa-aaaal-qjioq-cai" };  // testnet
  }
};

/// Return the chain ID recognized by the Hub
func getTargetChainId(env : DeploymentEnv) : Text {
  switch (env) {
    case (#Mainnet) { "base" };
    case (#Testnet) { "base_sepolia" };
  }
};

// 2) Minimal ICRC-1 interface snippet
//    We assume the token canister has `icrc1_transfer(...)`.
module ICRC1 {
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
    icrc1_transfer : (TransferArgs) -> (TransferResult);
    // ... possibly other methods: icrc1_balance_of, etc.
  };
}

// 3) The main actor
actor {

  stable var env : DeploymentEnv = #Testnet;

  public shared({caller}) func setDeploymentEnv(newEnv : DeploymentEnv) : async () {
    env := newEnv;
  };

  // Return an actor reference to the real Hub canister
  private func hubActor() : Hub.service {
    let pid = getHubCanisterId(env);
    return actor(pid) : Hub.service;
  };

  //
  // A) Bridge ICRC tokens from IC to Base chain using the Hub's `bridge(...)`
  //
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

  // Additional Hub calls if you wish
  public shared(msg) func addChains(chains : [Hub.AddChainArgs]) : async Hub.Result {
    return await hubActor().add_chains(chains);
  };

  //
  // B) New: validate_send_icrc1_tokens(...) 
  //    A generic function to check if a send is feasible (balance, subaccount, etc.)
  //    In practice, you might do more logic: check local state, check blacklists, etc.
  //
  public shared(query) func validate_send_icrc1_tokens(
    tokenCanister : principal,
    from : Text,
    to : Text,
    amount : Nat
  ) : async Bool {
    // This function is a "stub" for your custom checks. For example:
    // 1) We might call "icrc1_balance_of" to see if `from` has enough balance.
    // 2) We might check if "to" is not blacklisted, if any local rules are satisfied, etc.
    Debug.print("validate_send_icrc1_tokens => from=" # from # ", to=" # to # ", amount=" # Nat.toText(amount));
    
    // For demonstration, we just return `true`. Replace with real checks.
    return true;
  };

  //
  // C) New: send_icrc1_tokens(...) 
  //    Actually calls the ICRC-1 token canister's `icrc1_transfer` to move tokens.
  //
  public shared(msg) func send_icrc1_tokens(
    tokenCanister : principal,
    from : Text,
    to : Text,
    amount : Nat
  ) : async ICRC1.TransferResult {
    // 1) Validate before sending
    let canSend = await validate_send_icrc1_tokens(tokenCanister, from, to, amount);
    if (!canSend) {
      return #err(#GenericError({ 
        message = "Validation failed, cannot send", 
        error_code = 200 
      }));
    };

    // 2) Build the ICRC-1 actor
    let icrc1Actor = actor(tokenCanister) : ICRC1.ICRC1Service;

    // 3) Construct a minimal TransferArgs
    //    "from_subaccount" is optional, you may pass an actual subaccount if needed
    //    "to" is a "blob" representing the address (like an Account identifier).
    //    We'll do a simple approach: from and to are textual => decode them if needed.
    let tArgs : ICRC1.TransferArgs = {
      from_subaccount = null;
      to = textToBlob(to); // Convert textual "to" into a blob account
      fee = null; 
      created_at_time = null;
      memo = null;
      amount = amount;
    };

    // 4) Call icrc1_transfer
    let result = await icrc1Actor.icrc1_transfer(tArgs);
    Debug.print("ICRC1 transfer result => " # debug_show(result));
    return result;
  };

  //
  // Utility to convert textual "account" => blob if your standard needs it.
  // Or if your token canister can handle textual addresses, adapt accordingly.
  //
  private func textToBlob(acc : Text) : Blob {
    // Example: If your ICRC-1 can accept textual addresses, you might skip this step.
    // Or if you store an 32-byte "principal + subaccount," you'd parse it.
    // We'll do a naive approach: encode as UTF-8
    return Text.encodeUtf8(acc);
  };

  //
  // D) Example read method: getHubAdmin
  //
  public shared(msg) func getHubAdmin() : async principal {
    return await hubActor().get_admin();
  };
}
