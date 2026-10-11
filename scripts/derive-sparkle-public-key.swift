#!/usr/bin/env swift
// Prints the public half of the key that updates are signed with, which goes into the app.
//   swift scripts/derive-sparkle-public-key.swift <private key>
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    fail("Usage: swift scripts/derive-sparkle-public-key.swift <private key>")
}
var encoded = CommandLine.arguments[1].trimmingCharacters(in: .whitespacesAndNewlines)
while encoded.count % 4 != 0 {
    encoded += "="
}
guard let key = Data(base64Encoded: encoded) else {
    fail("The private key isn't Base64.")
}

switch key.count {
case 32:
    // The seed alone, as scripts/generate-sparkle-key.swift prints it.
    guard let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: key) else {
        fail("The private key isn't one for signing.")
    }
    print(privateKey.publicKey.rawRepresentation.base64EncodedString())
case 96:
    // The form Sparkle's own generate_keys exports: the public key is its last 32 bytes.
    print(key.suffix(32).base64EncodedString())
default:
    fail("The private key is \(key.count) bytes long. It should be 32, or 96 as Sparkle's generate_keys exports it.")
}
