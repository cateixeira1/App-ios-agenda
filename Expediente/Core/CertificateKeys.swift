import CryptoKit
import Foundation
import Security

/// Certificado A1 aberto (arquivo .pfx/.p12): assina XML (NFS-e), CMS (PDF) e faz a conexão TLS mútua com o
/// Sistema Nacional. A chave privada fica só na memória enquanto o certificado está aberto.
final class OpenCertificate: XmlSigningIdentity {
    let identity: SecIdentity
    let certificate: SecCertificate
    let privateKey: SecKey
    let info: X509Info
    /// Outros certificados da cadeia que vieram no arquivo.
    let chain: [SecCertificate]

    var certificateDER: Data { info.der }

    init(identity: SecIdentity, chain: [SecCertificate]) throws {
        self.identity = identity
        var cert: SecCertificate?
        var key: SecKey?
        guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert,
              SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key else {
            throw CertificateError.invalid
        }
        certificate = cert
        privateKey = key
        let der = SecCertificateCopyData(cert) as Data
        info = try X509Info.parse(der, sha1: { Data(Insecure.SHA1.hash(data: $0)) })
        let own = der
        self.chain = chain.filter { (SecCertificateCopyData($0) as Data) != own }
    }

    func sign(_ data: Data, algorithm: SecKeyAlgorithm) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(privateKey, algorithm, data as CFData, &error) as Data? else {
            throw CertificateError.signFailed
        }
        return sig
    }

    func signRSASHA1(_ data: Data) throws -> Data { try sign(data, algorithm: .rsaSignatureMessagePKCS1v15SHA1) }

    func signRSASHA256(_ data: Data) throws -> Data { try sign(data, algorithm: .rsaSignatureMessagePKCS1v15SHA256) }

    /// Assinatura CMS (PAdES) do resumo SHA-256 dos bytes do PDF.
    func cms(digest: Data) throws -> Data {
        try CMSSigner.signedData(digest: digest, certificate: info, chain: chain.map { SecCertificateCopyData($0) as Data },
                                 certificateHash: Data(SHA256.hash(data: info.der)), sign: signRSASHA256)
    }
}

enum CertificateError: LocalizedError, Equatable {
    case wrongPassword
    case invalid
    case notRSA
    case expired(String)
    case signFailed
    case needsA1
    case missing

    var errorDescription: String? {
        switch self {
        case .wrongPassword: return "Senha incorreta ou arquivo de certificado inválido."
        case .invalid: return "O arquivo não tem um certificado com chave privada."
        case .notRSA: return "O certificado não tem chave RSA para assinar."
        case .expired(let d): return "O certificado venceu em \(d)."
        case .signFailed: return "Não foi possível assinar com o certificado."
        case .needsA1: return "No iPhone só dá para assinar com certificado A1 (arquivo .pfx ou .p12). O A3 (token ou cartão) funciona na versão para Windows."
        case .missing: return "Adicione um certificado digital A1 em Ajustes › Assinatura digital, notas e WhatsApp."
        }
    }
}

enum CertificateKeys {
    /// Abre o .pfx com a senha.
    static func open(pfx: Data, password: String) throws -> OpenCertificate {
        var items: CFArray?
        let status = SecPKCS12Import(pfx as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        guard status == errSecSuccess, let list = items as? [[String: Any]], let first = list.first,
              let idRef = first[kSecImportItemIdentity as String] else {
            throw status == errSecAuthFailed || status == errSecPkcs12VerifyFailure ? CertificateError.wrongPassword : CertificateError.invalid
        }
        let identity = idRef as! SecIdentity
        let chain = (first[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
        let open = try OpenCertificate(identity: identity, chain: chain)
        guard open.info.hasRSAKey else { throw CertificateError.notRSA }
        return open
    }

    // MARK: - Senha guardada (opcional)

    private static func account(_ id: UUID) -> String { "certificado-senha-\(id.uuidString)" }

    /// Guarda a senha do certificado no Keychain deste iPhone (não vai para backups nem para outros aparelhos).
    static func savePassword(_ password: String, for id: UUID) { Keychain.set(Data(password.utf8), account: account(id)) }

    static func savedPassword(for id: UUID) -> String? {
        Keychain.get(account: account(id)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func forgetPassword(for id: UUID) { Keychain.delete(account: account(id)) }

    /// Abre o certificado guardado no app (A1), com a senha dada ou a guardada.
    @MainActor
    static func open(_ entry: CertificateEntry, store: Store, password: String?) throws -> OpenCertificate {
        guard entry.canSignOnThisDevice, let att = entry.pfxAttachmentID else { throw CertificateError.needsA1 }
        if entry.isExpired() { throw CertificateError.expired(Formatters.shortDate.string(from: entry.notAfter)) }
        guard let pwd = password ?? savedPassword(for: entry.id) else { throw CertificateError.wrongPassword }
        let pfx = try store.readAttachment(att)
        return try open(pfx: pfx, password: pwd)
    }
}

/// Conexão com o Sistema Nacional da NFS-e: TLS mútuo com o certificado do prestador.
final class NfseURLSessionTransport: NSObject, NfseTransport, URLSessionDelegate {
    private let certificate: OpenCertificate
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.httpAdditionalHeaders = ["Accept": "application/json", "User-Agent": "Expediente-iOS"]
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    init(certificate: OpenCertificate) { self.certificate = certificate }

    func send(method: String, url: URL, json: Data?) async throws -> NfseHTTPResponse {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let json {
            req.httpBody = json
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        return NfseHTTPResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            completionHandler(.useCredential, URLCredential(identity: certificate.identity, certificates: certificate.chain,
                                                            persistence: .forSession))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// A sessão guarda o delegado; chame ao terminar para liberar a conexão (e o certificado).
    func finish() { session.finishTasksAndInvalidate() }
}
