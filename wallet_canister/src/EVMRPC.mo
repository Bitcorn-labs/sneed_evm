////////////////////////////////////////////////////
// EVM RPC Module
////////////////////////////////////////////////////
module EVMRPC {
  public type RpcServices = {};

  public type EthSendRawTransactionResult = {
    #Ok : ?Text;
    #NonceTooLow;
    #NonceTooHigh;
    #InsufficientFunds;
    #Other : Text;
  };

  public type Service = actor {
    eth_sendRawTransaction : (
      RpcServices,
      ?{
        responseSizeEstimate : ?Nat64;
        responseConsensus : ?{ #Equality; #SuperMajority; #Absolute };
      },
      Text
    ) -> async {
      #Consistent : {
        #Ok : EthSendRawTransactionResult;
        #Err : Text;
      };
      #Inconsistent : Text;
    };
  };


////////////////////////////////////////////////////
// Errors / Results
////////////////////////////////////////////////////
  public type TxError = {
    #NotOwner;
    #InvalidSignature;
    #NonceTooLow;
    #NonceTooHigh;
    #InsufficientFunds;
    #RpcError : Text;
    #GenericError : Text;
  };

  public module Result {
    public type Result<OkType, ErrType> = {
      #ok : OkType;
      #err : ErrType;
    };
  };

  ////////////////////////////////////////////////////
  // Environment & Network
  ////////////////////////////////////////////////////
  public type DeploymentEnv = {
    #Mainnet;
    #Testnet;
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
};
