import Hub "hub_client_canister/hub.did";
import Debug "mo:base/Debug";

public type DeploymentEnv = {
  #Mainnet;
  #Testnet;
};

// Return the canister ID for the existing bridge on mainnet/testnet
func getHubCanisterId(env : DeploymentEnv) : principal {
  switch (env) {
    case (#Mainnet) { principal "n6ii2-2yaaa-aaaaj-azvia-cai" };
    case (#Testnet) { principal "l5h5f-miaaa-aaaal-qjioq-cai" };
  }
};

func getTargetChainId(env : DeploymentEnv) : Text {
  switch (env) {
    case (#Mainnet) { "base" };
    case (#Testnet) { "base_sepolia" };
  }
};

actor {

  stable var env : DeploymentEnv = #Testnet;

  public shared({caller}) func setDeploymentEnv(newEnv : DeploymentEnv) : async () {
    env := newEnv;
  };

  private func hubActor() : Hub.service {
    let pid = getHubCanisterId(env);
    return actor(pid) : Hub.service;
  };

  //
  // 1) Bridge ICRC tokens from IC to Base chain
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

  // Additional calls to the hub if you want, e.g. add_chains, get_admin, etc.
  public shared(msg) func addChains(chains : [Hub.AddChainArgs]) : async Hub.Result {
    return await hubActor().add_chains(chains);
  };

  public shared(msg) func getHubAdmin() : async principal {
    return await hubActor().get_admin();
  };
}
