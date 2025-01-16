module {
  public type Result<T, E> = {
    #ok : T;
    #err : E;
  };

  public type Network = {
    #Ethereum : ?Nat;
    #Base : ?Nat;
  };

  public type RemoteNFTPointer = {
    tokenId : Nat;
    contract : Text;
    network : Network;
  };
}