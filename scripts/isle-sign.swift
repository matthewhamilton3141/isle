// isle-sign — Ed25519 keygen / sign / verify for Isle's updater.
//
// Uses CryptoKit's *raw* 32-byte key representation, the exact format
// `Updater.verifySignature` expects (`Curve25519.Signing.PublicKey`/
// `PrivateKey(rawRepresentation:)`), so signatures made here verify in-app.
//
// Usage:
//   swift isle-sign.swift keygen                       # prints PRIVATE / PUBLIC (base64)
//   swift isle-sign.swift sign   <privB64> <file>      # prints base64 signature
//   swift isle-sign.swift verify <pubB64> <sigB64> <file>   # exits 0 if valid

import Foundation
import CryptoKit

func die(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 2 else { die("usage: keygen | sign <priv> <file> | verify <pub> <sig> <file>") }

switch args[1] {
case "keygen":
    let key = Curve25519.Signing.PrivateKey()
    print("PRIVATE " + key.rawRepresentation.base64EncodedString())
    print("PUBLIC " + key.publicKey.rawRepresentation.base64EncodedString())

case "sign":
    guard args.count == 4,
          let priv = Data(base64Encoded: args[2]) else { die("usage: sign <privB64> <file>") }
    let key: Curve25519.Signing.PrivateKey
    do { key = try Curve25519.Signing.PrivateKey(rawRepresentation: priv) }
    catch { die("bad private key: \(error)") }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[3])) else { die("cannot read \(args[3])") }
    guard let sig = try? key.signature(for: data) else { die("signing failed") }
    print(sig.base64EncodedString())

case "verify":
    guard args.count == 5,
          let pub = Data(base64Encoded: args[2]),
          let sig = Data(base64Encoded: args[3]) else { die("usage: verify <pubB64> <sigB64> <file>") }
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub) else { die("bad public key") }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[4])) else { die("cannot read \(args[4])") }
    if key.isValidSignature(sig, for: data) {
        print("OK")
    } else {
        die("INVALID signature")
    }

default:
    die("unknown command: \(args[1])")
}
