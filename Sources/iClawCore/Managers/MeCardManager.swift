import Foundation
import Contacts
#if canImport(AppKit)
import AppKit
#endif

@MainActor
public class MeCardManager {
    public static let shared = MeCardManager()

    private var _userName: String?
    private var _userEmail: String?
    private var _userPhone: String?
    private var hasFetched = false

    public var userName: String {
        ensureFetched()
        return _userName ?? NSFullUserName()
    }
    public var userEmail: String? {
        ensureFetched()
        return _userEmail
    }
    public var userPhone: String? {
        ensureFetched()
        return _userPhone
    }

    private init() {}

    private func ensureFetched() {
        guard !hasFetched else { return }
        hasFetched = true
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized else { return }
        fetchMeCard()
    }

    func fetchMeCardIfAuthorized() {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized else { return }
        fetchMeCard()
    }

    func requestAccessAndFetchMeCard() async {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)

        if status == .notDetermined {
            let _ = await PermissionManager.requestPermission(.contacts, toolName: "Contacts", reason: "to personalize your experience")
            #if canImport(AppKit)
            NSApp.activate(ignoringOtherApps: true)
            #endif
            let granted = (try? await store.requestAccess(for: .contacts)) ?? false
            if granted {
                fetchMeCard()
            }
        } else if status == .authorized {
            fetchMeCard()
        }
    }

    private func fetchMeCard() {
        let store = CNContactStore()
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]

        do {
            let me = try store.unifiedMeContactWithKeys(toFetch: keys)
            let name = "\(me.givenName) \(me.familyName)".trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                self._userName = name
            }
            self._userEmail = me.emailAddresses.first?.value as String?
            self._userPhone = me.phoneNumbers.first?.value.stringValue
        } catch {
            // Silently fail -- Me Card may not exist
        }
    }
}
