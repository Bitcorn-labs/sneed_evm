import Buffer "mo:base/Buffer";
import Nat64 "mo:base/Nat64";
import Text "mo:base/Text";
import Hex "./Hex";
import Array "mo:base/Array";
import Nat8 "mo:base/Nat8";
import Types "./Types";

module {
  type Result<T,E> = Types.Result<T,E>;

  public type Transaction1559 = {
    chainId : Nat64;
    nonce : Nat64;
    maxPriorityFeePerGas : Nat64;
    maxFeePerGas : Nat64;
    gasLimit : Nat64;
    to : Text;
    value : Nat;
    data : Text;
    accessList : [Text];
    v : Text;
    r : Text;
    s : Text;
  };

  public module Transaction1559 {
    public func getMessageToSign(tx : Transaction1559) : Result<[Nat8], Text> {
      let buf = Buffer.Buffer<Nat8>(100);
      
      // Add chainId
      addUint64(buf, tx.chainId);
      
      // Add nonce
      addUint64(buf, tx.nonce);
      
      // Add maxPriorityFeePerGas
      addUint64(buf, tx.maxPriorityFeePerGas);
      
      // Add maxFeePerGas
      addUint64(buf, tx.maxFeePerGas);
      
      // Add gasLimit
      addUint64(buf, tx.gasLimit);
      
      // Add to address
      switch (hexToBytes(tx.to)) {
        case (#ok(bytes)) { addBytes(buf, bytes) };
        case (#err(e)) { return #err("Invalid to address: " # e) };
      };
      
      // Add value
      addUint256(buf, tx.value);
      
      // Add data
      switch (hexToBytes(tx.data)) {
        case (#ok(bytes)) { addBytes(buf, bytes) };
        case (#err(e)) { return #err("Invalid data: " # e) };
      };
      
      #ok(Buffer.toArray(buf))
    };

    public func signAndSerialize(
      tx : Transaction1559, 
      signature : [Nat8],
      publicKey : [Nat8],
      chainId : ?Nat64
    ) : Result<(Text, [Nat8]), Text> {
      let buf = Buffer.Buffer<Nat8>(100);
      
      // Add type byte (0x02 for EIP-1559)
      buf.add(0x02);
      
      // Add chainId
      addUint64(buf, tx.chainId);
      
      // Add remaining fields...
      addUint64(buf, tx.nonce);
      addUint64(buf, tx.maxPriorityFeePerGas);
      addUint64(buf, tx.maxFeePerGas);
      addUint64(buf, tx.gasLimit);
      
      switch (hexToBytes(tx.to)) {
        case (#ok(bytes)) { addBytes(buf, bytes) };
        case (#err(e)) { return #err("Invalid to address: " # e) };
      };
      
      addUint256(buf, tx.value);
      
      switch (hexToBytes(tx.data)) {
        case (#ok(bytes)) { addBytes(buf, bytes) };
        case (#err(e)) { return #err("Invalid data: " # e) };
      };
      
      // Add signature
      addBytes(buf, signature);
      
      let serialized = Buffer.toArray(buf);
      #ok(("0x" # bytesToHex(serialized), serialized))
    };

    private func addUint64(buf : Buffer.Buffer<Nat8>, n : Nat64) {
      let bytes = Array.tabulate<Nat8>(8, func(i) {
        Nat8.fromNat(Nat64.toNat(n >> Nat64.fromNat(8 * (7 - i))))
      });
      addBytes(buf, bytes);
    };

    private func addUint256(buf : Buffer.Buffer<Nat8>, n : Nat) {
      let bytes = Array.tabulate<Nat8>(32, func(i) {
        let shift = 8 * (31 - i);
        if (shift >= 256) { 
          Nat8.fromNat(0)
        } else {
          let shifted = n / (2 ** shift);
          Nat8.fromNat(shifted % 256)
        }
      });
      addBytes(buf, bytes);
    };

    private func addBytes(buf : Buffer.Buffer<Nat8>, bytes : [Nat8]) {
      for (b in bytes.vals()) { buf.add(b) };
    };

    private func hexToBytes(hex : Text) : Result<[Nat8], Text> {
      if (Text.size(hex) < 2 or not Text.startsWith(hex, #text("0x"))) {
        return #err("Invalid hex string");
      };
      let hex_str = Text.trimStart(hex, #text("0x"));
      Hex.decode(hex_str)
    };

    private func bytesToHex(bytes : [Nat8]) : Text {
      let hex_chars = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'];
      let buf = Buffer.Buffer<Char>(bytes.size() * 2);
      for (b in bytes.vals()) {
        let high = Nat8.toNat(b >> 4);
        let low = Nat8.toNat(b & 0x0F);
        buf.add(hex_chars[high]);
        buf.add(hex_chars[low]);
      };
      Text.fromIter(buf.vals())
    };
  };
} 