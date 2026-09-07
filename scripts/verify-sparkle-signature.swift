#!/usr/bin/env swift
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 4 else {
    fputs("usage: verify-sparkle-signature.swift <archive> <signature> <public-key>\n", stderr)
    exit(64)
}

let archiveURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let signature = Data(base64Encoded: CommandLine.arguments[2]) else {
    fputs("Sparkle signature is not valid base64.\n", stderr)
    exit(65)
}
guard let publicKeyData = Data(base64Encoded: CommandLine.arguments[3]) else {
    fputs("Sparkle public key is not valid base64.\n", stderr)
    exit(65)
}

do {
    let archive = try Data(contentsOf: archiveURL)
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    guard publicKey.isValidSignature(signature, for: archive) else {
        fputs("Sparkle signature does not match the public key embedded in Semper.\n", stderr)
        exit(1)
    }
} catch {
    fputs("Sparkle signature verification failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}

print("Sparkle signature matches the public key embedded in Semper.")
