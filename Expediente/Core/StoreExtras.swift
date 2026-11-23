import Foundation

/// Operações de perfil, tags, retornos, anexos, certificados e NFS-e.
extension Store {
    // MARK: - Perfil e tags

    func saveProfessional(_ p: Professional) {
        update { $0.professional = p }
    }

    /// Escolhe a área de atuação: troca as tags que ainda não foram usadas pelas sugeridas para a área e
    /// ajusta o nome de quem é atendido e a duração padrão. Tags já usadas na agenda ficam.
    func applyBusinessArea(_ area: BusinessArea, term: ClientTerm? = nil) {
        update { db in
            db.settings.businessArea = area
            db.settings.clientTerm = term ?? area.suggestedTerm
            db.settings.defaultDurationMinutes = area.defaultDuration
            let used = Set(db.appointments.compactMap(\.tagID))
            db.tags.removeAll { !used.contains($0.id) }
            for preset in area.presetTags where !db.tags.contains(where: { NameMatcher.normalize($0.name) == NameMatcher.normalize(preset.name) }) {
                var t = preset
                t.id = UUID()
                db.tags.append(t)
            }
            db.settings.firstSessionTagID = nil
            db.settings.returnTagID = nil
        }
    }

    // MARK: - Retorno

    @discardableResult
    func scheduleReturn(from a: Appointment, start: Date, durationMinutes: Int) -> Appointment {
        let r = ReturnPlanner.make(from: a, start: start, durationMinutes: durationMinutes, db: db)
        update { $0.appointments.append(r) }
        return r
    }

    // MARK: - Anexos

    func readAttachment(_ id: UUID) throws -> Data { try vault.readAttachment(id: id, key: key) }

    func writeAttachment(_ data: Data) throws -> UUID {
        let id = UUID()
        try vault.writeAttachment(data, id: id, key: key)
        return id
    }

    func deleteAttachmentSafe(_ id: UUID?) {
        if let id { vault.deleteAttachment(id: id) }
    }

    // MARK: - Certificados

    func certificate(_ id: UUID?) -> CertificateEntry? {
        guard let id else { return nil }
        return db.certificates.first { $0.id == id }
    }

    /// Certificado padrão que assina neste aparelho (A1), ou o A1 válido mais novo.
    func defaultCertificate() -> CertificateEntry? {
        let usable = db.certificates.filter(\.canSignOnThisDevice)
        return usable.first(where: \.isDefault) ?? usable.max { $0.notAfter < $1.notAfter }
    }

    @discardableResult
    func addCertificate(_ entry: CertificateEntry, pfx: Data) throws -> CertificateEntry {
        var e = entry
        e.pfxAttachmentID = try writeAttachment(pfx)
        update { db in
            if let old = db.certificates.first(where: { $0.thumbprint == e.thumbprint && $0.kind == e.kind }) {
                db.certificates.removeAll { $0.id == old.id }
                if old.pfxAttachmentID != e.pfxAttachmentID, let oid = old.pfxAttachmentID { self.vault.deleteAttachment(id: oid) }
                e.isDefault = e.isDefault || old.isDefault
            }
            if db.certificates.isEmpty { e.isDefault = true }
            if e.isDefault { for i in db.certificates.indices { db.certificates[i].isDefault = false } }
            db.certificates.append(e)
        }
        try saveNow()
        audit(.certificateAdded, "\(e.holderName) · \(e.kindLabel) · válido até \(Formatters.shortDate.string(from: e.notAfter))")
        return e
    }

    func setDefaultCertificate(_ id: UUID) {
        update { db in for i in db.certificates.indices { db.certificates[i].isDefault = db.certificates[i].id == id } }
    }

    func removeCertificate(_ id: UUID) {
        guard let e = certificate(id) else { return }
        deleteAttachmentSafe(e.pfxAttachmentID)
        update { db in
            db.certificates.removeAll { $0.id == id }
            if !db.certificates.isEmpty && !db.certificates.contains(where: \.isDefault) { db.certificates[0].isDefault = true }
            if db.fiscal.certificateID == id { db.fiscal.certificateID = nil }
        }
        try? saveNow()
        audit(.certificateRemoved, e.holderName)
    }

    // MARK: - Cabeçalho e rodapé dos documentos

    /// Troca (ou remove, com `image` nil) a imagem do cabeçalho ou do rodapé.
    func setDocumentImage(header: Bool, image: Data?, name: String) throws {
        let band = header ? db.settings.documentLayout.header : db.settings.documentLayout.footer
        deleteAttachmentSafe(band.imageID)
        let id = try image.map { try writeAttachment($0) }
        update { db in
            if header {
                db.settings.documentLayout.header.imageID = id
                db.settings.documentLayout.header.imageName = image == nil ? "" : name
            } else {
                db.settings.documentLayout.footer.imageID = id
                db.settings.documentLayout.footer.imageName = image == nil ? "" : name
            }
        }
        try saveNow()
    }

    func documentImage(_ band: DocumentBand) -> Data? {
        guard let id = band.imageID else { return nil }
        return try? readAttachment(id)
    }

    // MARK: - NFS-e

    /// Atualiza a NFS-e do atendimento e grava na hora (antes e depois de falar com o Sistema Nacional).
    func updateNfse(_ appointmentID: UUID, _ change: (inout NfseInfo) -> Void) {
        update { db in
            guard let i = db.appointments.firstIndex(where: { $0.id == appointmentID }), var n = db.appointments[i].nfse else { return }
            change(&n)
            db.appointments[i].nfse = n
            // Só a nota de produção conta como nota fiscal do atendimento (a de homologação é teste).
            if n.state == .issued && n.environment == .production {
                db.appointments[i].invoiceNumber = n.number
                db.appointments[i].invoiceIssuedAt = n.issuedAt
            }
        }
        try? saveNow()
    }

    /// Tira do atendimento a nota de teste (homologação), guardando no histórico, para emitir a de produção.
    func archiveTestNfse(_ appointmentID: UUID) {
        update { db in
            guard let i = db.appointments.firstIndex(where: { $0.id == appointmentID }),
                  let old = db.appointments[i].nfse, old.environment == .homologation else { return }
            db.appointments[i].nfseHistory = (db.appointments[i].nfseHistory ?? []) + [old]
            db.appointments[i].nfse = nil
        }
        try? saveNow()
    }

    private func dpsCounterKey() -> String {
        let f = db.fiscal
        return "\(f.environment == .production ? 1 : 2)-\(NfseDps.normalizeSeries(f.dpsSeries))"
    }

    private func nextDps() -> Int64 { max(1, db.fiscal.nextDpsNumber[dpsCounterKey()] ?? 1) }

    func peekDpsID(inscription: String) -> String {
        let f = db.fiscal
        return NfseDps.identifier(municipality: f.municipalityCode, inscription: inscription, series: f.dpsSeries, number: nextDps())
    }

    func skipDpsNumber() {
        let key = dpsCounterKey()
        let next = nextDps() + 1
        update { $0.fiscal.nextDpsNumber[key] = next }
        try? saveNow()
    }

    /// Reserva a identificação da DPS do atendimento. Uma nova tentativa usa sempre a mesma (nunca gera nota em dobro).
    func reserveDps(_ appointmentID: UUID, inscription: String) throws -> NfseInfo {
        guard let a = appointment(appointmentID) else { throw NfseError.message("Atendimento não encontrado.") }
        if let existing = a.nfse, existing.state != .cancelled { return existing }
        let f = db.fiscal
        let key = dpsCounterKey()
        let number = nextDps()
        let series = NfseDps.normalizeSeries(f.dpsSeries)
        var info = NfseInfo()
        info.series = series
        info.dpsNumber = number
        info.environment = f.environment
        info.dpsId = NfseDps.identifier(municipality: f.municipalityCode, inscription: inscription, series: series, number: number)
        info.firstAttemptAt = now()
        info.state = .unknown
        update { db in
            db.fiscal.nextDpsNumber[key] = number + 1
            guard let i = db.appointments.firstIndex(where: { $0.id == appointmentID }) else { return }
            if let old = db.appointments[i].nfse, old.state == .cancelled {
                db.appointments[i].nfseHistory = (db.appointments[i].nfseHistory ?? []) + [old]
            }
            db.appointments[i].nfse = info
        }
        try saveNow()
        return info
    }
}
