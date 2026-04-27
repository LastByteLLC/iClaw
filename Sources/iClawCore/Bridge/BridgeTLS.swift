#if os(macOS)
import CommonCrypto
import Foundation
import Network
import Security
import os

/// Creates and caches a self-signed TLS identity for the BrowserBridge localhost channel.
/// The identity (P-256 key + self-signed cert) is stored in the Keychain on first run
/// and reused across launches. Both the app and Safari extension use the same well-known
/// port with this TLS layer, avoiding plaintext localhost communication.
enum BridgeTLS {

    private static let label = "com.geticlaw.iClaw.bridge"
    private static let log = Logger(subsystem: "com.geticlaw.iClaw", category: "bridge-tls")

    // MARK: - NWProtocolTLS Parameters

    /// TLS parameters for the **server** (BrowserBridge listener).
    /// Uses the self-signed identity from the Keychain.
    static func serverParameters() -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()

        if let identity = loadOrCreateIdentity() {
            sec_protocol_options_set_local_identity(
                tlsOptions.securityProtocolOptions,
                sec_identity_create(identity)!
            )
        } else {
            log.error("Failed to create TLS identity — falling back to plaintext")
            return .tcp
        }

        // Allow self-signed (no CA verification needed for localhost)
        sec_protocol_options_set_peer_authentication_required(
            tlsOptions.securityProtocolOptions,
            false
        )

        let params = NWParameters(tls: tlsOptions)
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        return params
    }

    /// TLS parameters for **clients** (Safari extension, native host).
    /// Validates the server certificate against the locally stored self-signed identity
    /// rather than trusting any certificate unconditionally.
    static func clientOptions() -> NWProtocolTLS.Options {
        let tlsOptions = NWProtocolTLS.Options()

        // Pin against our stored self-signed certificate's public key hash.
        // If the identity hasn't been created yet, fall back to trusting any cert
        // on localhost (first-launch race).
        let pinnedHash = loadCertificatePublicKeyHash()

        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { metadata, trust, completion in
                guard let pinnedHash else {
                    // No stored cert yet — trust on first use
                    completion(true)
                    return
                }
                // Extract the server's leaf certificate and compare public key hashes
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                if #available(macOS 15.0, iOS 18.0, *) {
                    guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                          let serverCert = chain.first else {
                        completion(false)
                        return
                    }
                    completion(publicKeyHash(of: serverCert) == pinnedHash)
                } else {
                    guard SecTrustGetCertificateCount(secTrust) > 0,
                          let serverCert = SecTrustGetCertificateAtIndex(secTrust, 0) else {
                        completion(false)
                        return
                    }
                    completion(publicKeyHash(of: serverCert) == pinnedHash)
                }
            },
            .global(qos: .userInitiated)
        )

        return tlsOptions
    }

    /// SHA-256 hash of the stored self-signed certificate's public key data.
    private static func loadCertificatePublicKeyHash() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let ref = result else { return nil }
        let cert = (ref as! SecCertificate)
        return publicKeyHash(of: cert)
    }

    /// Compute SHA-256 of a certificate's SubjectPublicKeyInfo (SPKI) data.
    private static func publicKeyHash(of cert: SecCertificate) -> Data? {
        guard let publicKey = SecCertificateCopyKey(cert),
              let pubKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            return nil
        }
        var hash = [UInt8](repeating: 0, count: 32)
        _ = pubKeyData.withUnsafeBytes { bytes in
            CC_SHA256(bytes.baseAddress, CC_LONG(pubKeyData.count), &hash)
        }
        return Data(hash)
    }

    // MARK: - Identity Management

    /// Load existing identity from Keychain, or create a new self-signed one.
    private static func loadOrCreateIdentity() -> SecIdentity? {
        if let existing = loadIdentity() {
            return existing
        }
        return createAndStoreIdentity()
    }

    /// Load a previously stored identity from the Keychain.
    private static func loadIdentity() -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let ref = result else { return nil }
        // CFTypeRef from kSecReturnRef with kSecClassIdentity is always SecIdentity
        return (ref as! SecIdentity)
    }

    /// Generate a new P-256 key pair, create a self-signed certificate, and store in Keychain.
    private static func createAndStoreIdentity() -> SecIdentity? {
        // Generate key pair
        let keyParams: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrLabel as String: label,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrLabel as String: label,
            ],
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyParams as CFDictionary, &error) else {
            log.error("Failed to generate key: \(error!.takeRetainedValue())")
            return nil
        }

        // Create self-signed certificate using Security framework
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            log.error("Failed to extract public key")
            return nil
        }

        guard let cert = createSelfSignedCert(publicKey: publicKey, privateKey: privateKey) else {
            log.error("Failed to create self-signed certificate")
            return nil
        }

        // Store certificate in Keychain
        let certAddQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: label,
        ]
        let certStatus = SecItemAdd(certAddQuery as CFDictionary, nil)
        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
            log.error("Failed to store certificate: \(certStatus)")
            return nil
        }

        // Now load the identity (key + cert pair matched by Keychain)
        return loadIdentity()
    }

    /// Create a minimal self-signed X.509 certificate using the Security framework.
    /// Valid for 10 years, CN=iClaw Bridge.
    private static func createSelfSignedCert(publicKey: SecKey, privateKey: SecKey) -> SecCertificate? {
        // Use SecCertificateCreateWithData with a DER-encoded cert built manually
        // is complex — instead, use the higher-level SecIdentityCreateWithCertificate
        // approach via a PKCS12 round-trip.

        // Build a minimal ASN.1 DER self-signed certificate
        guard let certData = buildSelfSignedCertDER(publicKey: publicKey, privateKey: privateKey) else {
            return nil
        }
        return SecCertificateCreateWithData(nil, certData as CFData)
    }

    /// Build a DER-encoded self-signed X.509v1 certificate.
    /// Uses P-256 key with SHA-256 ECDSA signature.
    private static func buildSelfSignedCertDER(publicKey: SecKey, privateKey: SecKey) -> Data? {
        // Extract raw public key bytes
        var pubKeyError: Unmanaged<CFError>?
        guard let pubKeyData = SecKeyCopyExternalRepresentation(publicKey, &pubKeyError) as Data? else {
            return nil
        }

        // Serial number
        let serial: [UInt8] = [0x02, 0x01, 0x01] // INTEGER 1

        // Issuer/Subject: CN=iClaw Bridge
        let cn = "iClaw Bridge"
        let cnBytes = [UInt8](cn.utf8)
        // UTF8String tag + length + content
        let cnValue: [UInt8] = [0x0C, UInt8(cnBytes.count)] + cnBytes
        // AttributeTypeAndValue: OID 2.5.4.3 (CN) + value
        let cnOID: [UInt8] = [0x06, 0x03, 0x55, 0x04, 0x03]
        let atv = asn1Sequence(cnOID + cnValue)
        let rdn = asn1Set(atv)
        let name = asn1Sequence(rdn)

        // Validity: not before = now, not after = now + 10 years
        let now = Date()
        let tenYears = Calendar.current.date(byAdding: .year, value: 10, to: now)!
        let validity = asn1Sequence(asn1UTCTime(now) + asn1UTCTime(tenYears))

        // SubjectPublicKeyInfo for P-256
        // Algorithm: ecPublicKey (1.2.840.10045.2.1) + prime256v1 (1.2.840.10045.3.1.7)
        let ecPubKeyOID: [UInt8] = [0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
        let prime256v1OID: [UInt8] = [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
        let algorithm = asn1Sequence(ecPubKeyOID + prime256v1OID)
        // BIT STRING wrapping the public key
        let pubKeyBits = asn1BitString([UInt8](pubKeyData))
        let spki = asn1Sequence(algorithm + pubKeyBits)

        // Signature algorithm: ecdsa-with-SHA256 (1.2.840.10045.4.3.2)
        let sigAlgOID: [UInt8] = [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]
        let sigAlg = asn1Sequence(sigAlgOID)

        // TBSCertificate
        let tbs = asn1Sequence(serial + sigAlg + name + validity + name + spki)
        let tbsData = Data(tbs)

        // Sign TBSCertificate
        var signError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            tbsData as CFData,
            &signError
        ) as Data? else {
            return nil
        }

        // Full certificate: TBSCertificate + signatureAlgorithm + signatureValue
        let cert = asn1Sequence(tbs + sigAlg + asn1BitString([UInt8](signature)))
        return Data(cert)
    }

    // MARK: - ASN.1 Helpers

    private static func asn1Length(_ length: Int) -> [UInt8] {
        if length < 128 {
            return [UInt8(length)]
        } else if length < 256 {
            return [0x81, UInt8(length)]
        } else {
            return [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
        }
    }

    private static func asn1Sequence(_ content: [UInt8]) -> [UInt8] {
        [0x30] + asn1Length(content.count) + content
    }

    private static func asn1Set(_ content: [UInt8]) -> [UInt8] {
        [0x31] + asn1Length(content.count) + content
    }

    private static func asn1BitString(_ content: [UInt8]) -> [UInt8] {
        // Prepend 0x00 for "no unused bits"
        let inner = [UInt8(0x00)] + content
        return [0x03] + asn1Length(inner.count) + inner
    }

    private static func asn1UTCTime(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let str = formatter.string(from: date) + "Z"
        let bytes = [UInt8](str.utf8)
        return [0x17, UInt8(bytes.count)] + bytes
    }
}
#endif
