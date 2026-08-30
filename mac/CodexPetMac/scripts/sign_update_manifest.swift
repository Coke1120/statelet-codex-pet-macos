#!/usr/bin/env swift

import CryptoKit
import Darwin
import Foundation

private let maximumManifestBytes = 16 * 1024
private let expectedKeys: Set<String> = [
    "asset_name",
    "asset_sha256",
    "asset_size",
    "build",
    "commit_sha",
    "ref",
    "repository",
    "repository_id",
    "schema_version",
    "version",
]

private enum SigningError: Error, CustomStringConvertible {
    case usage
    case invalidManifest(String)
    case invalidPrivateKey
    case invalidPublicKey
    case invalidSignature
    case invalidOutput
    case system(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: sign_update_manifest.swift sign MANIFEST SIGNATURE | verify MANIFEST SIGNATURE PUBLIC_KEY_B64 | public-key"
        case let .invalidManifest(reason):
            return "invalid update manifest: \(reason)"
        case .invalidPrivateKey:
            return "invalid Ed25519 private key"
        case .invalidPublicKey:
            return "invalid Ed25519 public key"
        case .invalidSignature:
            return "invalid Ed25519 signature"
        case .invalidOutput:
            return "invalid signature output path"
        case let .system(operation):
            return "\(operation) failed"
        }
    }
}

private func matches(_ value: String, _ pattern: String) -> Bool {
    value.range(of: pattern, options: .regularExpression) != nil
}

private func integer(_ value: Any?, named name: String) throws -> Int64 {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID()
    else {
        throw SigningError.invalidManifest("\(name) must be an integer")
    }
    let candidate = number.int64Value
    guard number.doubleValue == Double(candidate) else {
        throw SigningError.invalidManifest("\(name) must be an integer")
    }
    return candidate
}

private func string(_ value: Any?, named name: String) throws -> String {
    guard let result = value as? String else {
        throw SigningError.invalidManifest("\(name) must be a string")
    }
    return result
}

private func readRegularFile(_ path: String) throws -> Data {
    let descriptor = path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
    guard descriptor >= 0 else { throw SigningError.invalidManifest("file is unavailable") }
    defer { close(descriptor) }

    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_nlink == 1,
          metadata.st_size > 0,
          metadata.st_size <= maximumManifestBytes
    else {
        throw SigningError.invalidManifest("file must be a bounded regular file")
    }

    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    let data = handle.readDataToEndOfFile()
    guard data.count == Int(metadata.st_size), data.count <= maximumManifestBytes else {
        throw SigningError.invalidManifest("file changed while being read")
    }
    return data
}

private func validateCanonicalManifest(_ data: Data) throws {
    let object: Any
    do {
        object = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
        throw SigningError.invalidManifest("JSON could not be decoded")
    }
    guard let manifest = object as? [String: Any], Set(manifest.keys) == expectedKeys else {
        throw SigningError.invalidManifest("schema keys do not match manifest v1")
    }

    guard try integer(manifest["schema_version"], named: "schema_version") == 1 else {
        throw SigningError.invalidManifest("schema_version is unsupported")
    }
    guard try string(manifest["repository"], named: "repository") == "Coke1120/statelet-codex-pet-macos" else {
        throw SigningError.invalidManifest("repository is not authorized")
    }
    guard try integer(manifest["repository_id"], named: "repository_id") == 1_329_561_047 else {
        throw SigningError.invalidManifest("repository_id is not authorized")
    }

    let version = try string(manifest["version"], named: "version")
    guard matches(version, #"^[0-9]+\.[0-9]+\.[0-9]+$"#) else {
        throw SigningError.invalidManifest("version is not a stable semantic version")
    }
    guard try string(manifest["ref"], named: "ref") == "refs/tags/v\(version)" else {
        throw SigningError.invalidManifest("ref does not match version")
    }
    guard try integer(manifest["build"], named: "build") > 0 else {
        throw SigningError.invalidManifest("build must be positive")
    }

    let commit = try string(manifest["commit_sha"], named: "commit_sha")
    guard matches(commit, #"^[0-9a-f]{40}$"#) else {
        throw SigningError.invalidManifest("commit_sha is invalid")
    }
    let assetName = try string(manifest["asset_name"], named: "asset_name")
    guard assetName == "Statelet-macos-arm64.zip" || assetName == "Statelet-macos-x86_64.zip" else {
        throw SigningError.invalidManifest("asset_name is invalid")
    }
    guard try integer(manifest["asset_size"], named: "asset_size") > 0 else {
        throw SigningError.invalidManifest("asset_size must be positive")
    }
    let digest = try string(manifest["asset_sha256"], named: "asset_sha256")
    guard matches(digest, #"^[0-9a-f]{64}$"#) else {
        throw SigningError.invalidManifest("asset_sha256 is invalid")
    }

    let canonical: Data
    do {
        canonical = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    } catch {
        throw SigningError.invalidManifest("JSON could not be canonicalized")
    }
    guard canonical == data else {
        throw SigningError.invalidManifest("JSON is not canonical")
    }
}

private func readPrivateKey() throws -> Curve25519.Signing.PrivateKey {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard input.count <= 512,
          let encoded = String(data: input, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !encoded.isEmpty,
          !encoded.contains(where: { $0.isWhitespace }),
          let raw = Data(base64Encoded: encoded),
          raw.count == 32,
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else {
        throw SigningError.invalidPrivateKey
    }
    return key
}

private func readPublicKey(_ encoded: String) throws -> Curve25519.Signing.PublicKey {
    guard !encoded.isEmpty,
          !encoded.contains(where: { $0.isWhitespace }),
          let raw = Data(base64Encoded: encoded),
          raw.count == 32,
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    else {
        throw SigningError.invalidPublicKey
    }
    return key
}

private func readSignature(_ path: String) throws -> Data {
    let encoded = try readRegularFile(path)
    guard encoded.count <= 128,
          let text = String(data: encoded, encoding: .utf8),
          !text.isEmpty,
          !text.contains(where: { $0.isWhitespace }),
          let signature = Data(base64Encoded: text),
          signature.count == 64 else {
        throw SigningError.invalidSignature
    }
    return signature
}

private func writePrivateAtomically(_ data: Data, to path: String) throws {
    let outputURL = URL(fileURLWithPath: path)
    let parent = outputURL.deletingLastPathComponent()
    guard !outputURL.lastPathComponent.isEmpty else { throw SigningError.invalidOutput }

    var parentMetadata = stat()
    guard parent.path.withCString({ lstat($0, &parentMetadata) }) == 0,
          (parentMetadata.st_mode & S_IFMT) == S_IFDIR
    else {
        throw SigningError.invalidOutput
    }

    let temporaryURL = parent.appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp")
    let descriptor = temporaryURL.path.withCString {
        open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    }
    guard descriptor >= 0 else { throw SigningError.system("creating signature") }

    var shouldRemove = true
    defer {
        close(descriptor)
        if shouldRemove { unlink(temporaryURL.path) }
    }

    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let written = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
            guard written > 0 else { throw SigningError.system("writing signature") }
            offset += written
        }
    }
    guard fsync(descriptor) == 0, fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
        throw SigningError.system("securing signature")
    }
    guard rename(temporaryURL.path, outputURL.path) == 0 else {
        throw SigningError.system("publishing signature")
    }
    shouldRemove = false
}

private func run() throws {
    let arguments = CommandLine.arguments
    if arguments.count == 2, arguments[1] == "public-key" {
        let privateKey = try readPrivateKey()
        let encoded = privateKey.publicKey.rawRepresentation.base64EncodedString()
        FileHandle.standardOutput.write(Data(encoded.utf8))
        return
    }

    if arguments.count == 4, arguments[1] == "sign" {
        let manifest = try readRegularFile(arguments[2])
        try validateCanonicalManifest(manifest)
        let privateKey = try readPrivateKey()
        let signature = try privateKey.signature(for: manifest)
        guard privateKey.publicKey.isValidSignature(signature, for: manifest) else {
            throw SigningError.system("verifying signature")
        }
        try writePrivateAtomically(Data(signature.base64EncodedString().utf8), to: arguments[3])
        return
    }

    if arguments.count == 5, arguments[1] == "verify" {
        let manifest = try readRegularFile(arguments[2])
        try validateCanonicalManifest(manifest)
        let signature = try readSignature(arguments[3])
        let publicKey = try readPublicKey(arguments[4])
        guard publicKey.isValidSignature(signature, for: manifest) else {
            throw SigningError.invalidSignature
        }
        return
    }

    throw SigningError.usage
}

do {
    try run()
} catch let error as SigningError {
    FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
    if case .usage = error {
        exit(2)
    }
    exit(1)
} catch {
    FileHandle.standardError.write(Data("error: signing failed\n".utf8))
    exit(1)
}
