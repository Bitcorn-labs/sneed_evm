import Text "mo:base/Text";
import Iter "mo:base/Iter";
import Nat8 "mo:base/Nat8";
import Array "mo:base/Array";
import Buffer "mo:base/Buffer";

module {
  private let hex_chars = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'];

  public func encode(bytes : [Nat8]) : Text {
    let buf = Buffer.Buffer<Char>(bytes.size() * 2);
    for (b in bytes.vals()) {
      buf.add(hex_chars[Nat8.toNat(b >> 4)]);
      buf.add(hex_chars[Nat8.toNat(b & 0x0F)]);
    };
    Text.fromIter(buf.vals())
  };

  public func decode(text : Text) : { #ok : [Nat8]; #err : Text } {
    let chars = Text.toIter(text);
    let bytes = Array.init<Nat8>(text.size() / 2, 0);
    var i = 0;
    
    label decode for (c1 in chars) {
      switch(chars.next()) {
        case (?c2) {
          switch (decodeHexPair(c1, c2)) {
            case (#ok(byte)) { bytes[i] := byte; i += 1; };
            case (#err(msg)) { return #err(msg); };
          };
        };
        case null { return #err("Invalid hex string length"); };
      };
    };
    
    #ok(Array.freeze(bytes))
  };

  private func decodeHexPair(c1 : Char, c2 : Char) : { #ok : Nat8; #err : Text } {
    switch (hexCharToNat(c1), hexCharToNat(c2)) {
      case (?n1, ?n2) { #ok(Nat8.fromNat(n1 * 16 + n2)) };
      case (_, _) { #err("Invalid hex character") };
    }
  };

  private func hexCharToNat(c : Char) : ?Nat {
    for (i in Iter.range(0, 15)) {
      if (hex_chars[i] == c) { return ?i };
    };
    null
  };
}