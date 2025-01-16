import Buffer "mo:base/Buffer";
import Hex "./Hex";
import Text "mo:base/Text";
import Nat "mo:base/Nat";
import Iter "mo:base/Iter";
import Nat8 "mo:base/Nat8";
import Blob "mo:base/Blob";

module {
  public module Value {
    public func uint256(n : Nat) : [Nat8] {
      let buf = Buffer.Buffer<Nat8>(32);
      var val = n;
      for (i in range(0, 31)) {
        buf.add(Nat8.fromNat(val % 256));
        val := val / 256;
      };
      Buffer.toArray(buf)
    };

    public func address(addr : Text) : [Nat8] {
      switch (Hex.decode(Text.trimStart(addr, #text("0x")))) {
        case (#ok(bytes)) { bytes };
        case (#err(_)) { [] };
      }
    };

    public func string(s : Text) : [Nat8] {
      Blob.toArray(Text.encodeUtf8(s))
    };

    public func bytes(b : [Nat8]) : [Nat8] { b };
  };

  public func encodeFunctionCall(signature : Text, args : [[Nat8]]) : [Nat8] {
    let methodId = Text.encodeUtf8(signature);
    let buf = Buffer.Buffer<Nat8>(4 + args.size() * 32);
    
    // Add method ID (first 4 bytes of signature)
    for (b in Blob.toArray(methodId).vals()) { buf.add(b) };
    
    // Add args
    for (arg in args.vals()) {
      for (b in arg.vals()) { buf.add(b) };
    };
    
    Buffer.toArray(buf)
  };

  private func range(start : Nat, end : Nat) : Iter.Iter<Nat> {
    var i = start;
    object {
      public func next() : ?Nat {
        if (i > end) { null }
        else {
          let current = i;
          i += 1;
          ?current
        }
      }
    }
  };
} 