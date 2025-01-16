module {
  public type BridgeArgs = {
    token : Principal;
    from_tx_id : ?Text;
    recipient : Text;
    target_chain_id : Text;
    from_address : ?Text;
    amount : Nat;
  };
  public type BridgeResponse = { history_id : Nat64 };
  public type HubError = { #PermissionDenied };
  public type Result_1 = { #Ok : BridgeResponse; #Err : HubError };
  public type service = actor {
    bridge : (BridgeArgs) -> async Result_1;
  };
} 