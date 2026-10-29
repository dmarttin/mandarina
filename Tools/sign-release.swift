// Signs the release digest for the auto-updater.
//
//   MANDARINA_UPDATE_KEY=<base64 raw 32-byte seed> \
//     swift Tools/sign-release.swift <digest-file> > Mandarina-<version>.dmg.sig
//
// The digest file holds the hex SHA-256 of the DMG with no trailing newline.
// CryptoKit is used so the signature matches what the app verifies, and so CI
// does not depend on which openssl the runner ships.
import CryptoKit
import Foundation

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: sign-release.swift <digest-file>\n".utf8))
    exit(2)
}

guard let encoded = ProcessInfo.processInfo.environment["MANDARINA_UPDATE_KEY"],
      let seed = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
      seed.count == 32 else {
    FileHandle.standardError.write(Data("MANDARINA_UPDATE_KEY must be a base64 32-byte Ed25519 seed\n".utf8))
    exit(2)
}

let digest = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
let signature = try key.signature(for: Data(digest.utf8))

// Print the public key too, so the workflow can be checked against the app.
let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
FileHandle.standardError.write(Data("public key: \(publicKey)\n".utf8))

print(signature.base64EncodedString())
