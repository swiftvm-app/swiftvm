#!/usr/bin/env swift
// Makes the key that updates of the app are signed with. Run it once, for the project's whole life:
// an app only takes updates that are signed with the key it was built for.
//   swift scripts/generate-sparkle-key.swift
import CryptoKit
import Foundation

let privateKey = Curve25519.Signing.PrivateKey()

print("SPARKLE_PRIVATE_KEY=\(privateKey.rawRepresentation.base64EncodedString())")
print("")
print("Public key: \(privateKey.publicKey.rawRepresentation.base64EncodedString())")
print("")
print("Add the private key to the repository's secrets as SPARKLE_PRIVATE_KEY, and keep a copy somewhere safe:")
print("without it no update can be signed, and the apps that are out there take no other key.")
print("The public key is worked out from it at build time and doesn't need to be kept.")
