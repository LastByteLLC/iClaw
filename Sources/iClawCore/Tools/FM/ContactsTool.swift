import Foundation
import Contacts

// MARK: - Extraction Args

public struct ContactsArgs: ToolArguments {
    public let action: String   // "search" or "create"
    public let name: String?
    public let phone: String?
    public let email: String?
}

// MARK: - ContactsTool (CoreTool)

/// Searches contacts and creates new ones. On permission denial for "create",
/// generates a .vcf vCard file with a preview widget and "Open in Contacts" button.
public struct ContactsTool: CoreTool, ExtractableCoreTool, Sendable {
    public let name = "Contacts"
    public let schema = "Search create contacts address book phone number email relationship person name information lookup"
    public let isInternal = false
    public let category = CategoryEnum.offline
    public let consentPolicy = ActionConsentPolicy.safe
    public let requiredPermission: PermissionManager.PermissionKind? = .contacts

    public init() {}

    public typealias Args = ContactsArgs
    public static let extractionSchema: String = loadExtractionSchema(
        named: "Contacts", fallback: #"{"action":"search|create","name":"string?","phone":"string?","email":"string?"}"#
    )

    public func execute(args: ContactsArgs, rawInput: String, entities: ExtractedEntities?) async throws -> ToolIO {
        try await executeAction(action: args.action, name: args.name, phone: args.phone, email: args.email)
    }

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        try await executeAction(action: "search", name: input, phone: nil, email: nil)
    }

    private func executeAction(action: String, name: String?, phone: String?, email: String?) async throws -> ToolIO {
        let store = CNContactStore()
        let hasAccess = await requestContactsAccess(store: store)

        if action == "create" {
            return try await createContact(store: store, hasAccess: hasAccess, name: name ?? "New Contact", phone: phone, email: email)
        }

        // Search (default)
        guard hasAccess else {
            return ToolIO(text: "Contacts access not authorized. Grant permission in System Settings > Privacy & Security > Contacts.", status: .error)
        }
        return try searchContacts(store: store, name: name ?? "")
    }

    // MARK: - Search

    private func searchContacts(store: CNContactStore, name: String) throws -> ToolIO {
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        let predicate = CNContact.predicateForContacts(matchingName: name)
        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)

        if contacts.isEmpty {
            return ToolIO(text: "No contacts found matching '\(name)'.", status: .ok, isVerifiedData: true)
        }

        let lines = contacts.prefix(5).map { contact in
            var parts = ["\(contact.givenName) \(contact.familyName)"]
            if let email = contact.emailAddresses.first?.value as String? { parts.append(email) }
            if let phone = contact.phoneNumbers.first?.value.stringValue { parts.append(phone) }
            return parts.joined(separator: " — ")
        }

        // Emit a `ContactPreviewWidget` for the top search result so the UI
        // renders the contact card, not just text. `isConfirmed: true` because
        // the contact already exists in the user's address book. Multi-result
        // searches surface only the first hit in the widget; the rest stay in
        // the text blob for the finalizer.
        let top = contacts[0]
        let topName = "\(top.givenName) \(top.familyName)".trimmingCharacters(in: .whitespaces)
        let topPhone = top.phoneNumbers.first?.value.stringValue
        let topEmail = top.emailAddresses.first?.value as String?
        let widgetData = ContactPreviewData(
            name: topName.isEmpty ? name : topName,
            phone: topPhone,
            email: topEmail,
            isConfirmed: true
        )
        return ToolIO(
            text: lines.joined(separator: "\n"),
            status: .ok,
            outputWidget: "ContactPreviewWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
    }

    // MARK: - Create

    private func createContact(store: CNContactStore, hasAccess: Bool, name: String, phone: String?, email: String?) async throws -> ToolIO {
        if hasAccess {
            // Try direct creation via Contacts framework
            let contact = CNMutableContact()
            let nameParts = name.split(separator: " ", maxSplits: 1)
            contact.givenName = String(nameParts.first ?? "")
            if nameParts.count > 1 { contact.familyName = String(nameParts.last ?? "") }
            if let p = phone { contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: p))] }
            if let e = email { contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: e as NSString)] }

            let saveRequest = CNSaveRequest()
            saveRequest.add(contact, toContainerWithIdentifier: nil)
            try store.execute(saveRequest)

            let widgetData = ContactPreviewData(name: name, phone: phone, email: email, isConfirmed: true)
            return ToolIO(
                text: "Contact '\(name)' added.",
                status: .ok,
                outputWidget: "ContactPreviewWidget",
                widgetData: widgetData,
                isVerifiedData: true
            )
        }

        // Permission denied → generate vCard fallback
        return buildVCardFallback(name: name, phone: phone, email: email)
    }

    private func buildVCardFallback(name: String, phone: String?, email: String?) -> ToolIO {
        let vcf = generateVCard(name: name, phone: phone, email: email)
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = name.replacingOccurrences(of: " ", with: "_") + ".vcf"
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try vcf.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            return ToolIO(text: "Failed to create contact file: \(error.localizedDescription)", status: .error)
        }

        let widgetData = ContactPreviewData(name: name, phone: phone, email: email, vcfFileURL: fileURL, isConfirmed: false)
        return ToolIO(
            text: "Contacts permission not granted. Tap 'Add to Contacts' to import the vCard.",
            status: .ok,
            outputWidget: "ContactPreviewWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
    }

    private func generateVCard(name: String, phone: String?, email: String?) -> String {
        let nameParts = name.split(separator: " ", maxSplits: 1)
        let first = String(nameParts.first ?? "")
        let last = nameParts.count > 1 ? String(nameParts.last ?? "") : ""

        var lines = [
            "BEGIN:VCARD",
            "VERSION:3.0",
            "FN:\(name)",
            "N:\(last);\(first);;;",
        ]
        if let p = phone { lines.append("TEL;TYPE=CELL:\(p)") }
        if let e = email { lines.append("EMAIL:\(e)") }
        lines.append("END:VCARD")
        return lines.joined(separator: "\r\n")
    }

    // MARK: - Permission

    private func requestContactsAccess(store: CNContactStore) async -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized { return true }
        if status == .notDetermined {
            let _ = await PermissionManager.requestPermission(.contacts, toolName: "Contacts", reason: "to look up contact information")
            do {
                return try await withThrowingTaskGroup(of: Bool.self) { group in
                    group.addTask { try await CNContactStore().requestAccess(for: .contacts) }
                    group.addTask { try await Task.sleep(nanoseconds: 5_000_000_000); throw CancellationError() }
                    let result = try await group.next() ?? false
                    group.cancelAll()
                    return result
                }
            } catch { return false }
        }
        return false
    }
}
