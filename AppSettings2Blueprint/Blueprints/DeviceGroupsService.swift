import Foundation

nonisolated enum DeviceType: String, Codable, Hashable, Sendable {
    case computer = "COMPUTER"
    case mobile = "MOBILE"
    case unknown

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DeviceType(rawValue: raw) ?? .unknown
    }

    var displayName: String {
        switch self {
        case .computer: "Computers"
        case .mobile: "Mobile devices"
        case .unknown: "Unknown"
        }
    }
}

nonisolated enum GroupType: String, Codable, Hashable, Sendable {
    case smart = "SMART"
    case staticGroup = "STATIC"
    case unknown

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = GroupType(rawValue: raw) ?? .unknown
    }

    var displayName: String {
        switch self {
        case .smart: "Smart"
        case .staticGroup: "Static"
        case .unknown: "Unknown"
        }
    }
}

/// A Jamf platform device group (`DeviceGroupListReadRepresentationV1`).
nonisolated struct PlatformGroup: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var description: String?
    var deviceType: DeviceType
    var groupType: GroupType
    var memberCount: Int
}

/// `GET /device-groups/v1/device-groups` (permission `device-groups:read`), for scope.
nonisolated struct DeviceGroupsService: Sendable {
    private struct Page: Decodable {
        var totalCount: Int?
        var hasNext: Bool?
        var results: [PlatformGroup]
    }

    let client: PlatformAPIClient
    var pageSize = 100
    /// Hard stop so a misbehaving server can't loop forever.
    var maxPages = 1_000

    /// Every device group, sorted by name, following all pages.
    func listAll() async throws -> [PlatformGroup] {
        var groups: [PlatformGroup] = []
        var page = 0
        while page < maxPages {
            try Task.checkCancellation()
            let response = try await client.send(
                method: "GET",
                path: "/device-groups/v1/device-groups",
                query: [
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "page-size", value: String(pageSize)),
                    URLQueryItem(name: "sort", value: "name"),
                ]
            )
            let decoded: Page
            do {
                decoded = try JSONDecoder().decode(Page.self, from: response.data)
            } catch {
                throw APIError.invalidResponse("The device group list could not be read: \(error.localizedDescription)")
            }
            groups += decoded.results
            if decoded.results.isEmpty { break }
            if let hasNext = decoded.hasNext {
                if !hasNext { break }
            } else if let total = decoded.totalCount, groups.count >= total {
                break
            }
            page += 1
        }
        return groups
    }
}
