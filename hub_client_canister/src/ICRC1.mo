
module ICRC1 {
  public type BalanceOfArgs = { owner : Blob; subaccount : ?Blob };
  
  public type TransferArgs = {
    from_subaccount : ?Blob;
    to : Blob;
    fee : ?Nat;
    created_at_time : ?Nat64;
    memo : ?Blob;
    amount : Nat;
  };
  public type TransferError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat64 };
    #TemporarilyUnavailable;
    #GenericError : { message : Text; error_code : Nat };
  };
  public type TransferResult = { #Ok : Nat; #Err : TransferError };
  public type ICRC1Service = actor {
    icrc1_balance_of : (BalanceOfArgs) -> async (Nat);
    icrc1_transfer : (TransferArgs) -> async (TransferResult);
  };
};

