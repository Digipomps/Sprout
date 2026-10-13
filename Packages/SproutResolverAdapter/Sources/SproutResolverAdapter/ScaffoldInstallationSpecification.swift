import Foundation

/// Signed alongside the image digest in executable catalog version 1.1.
/// No shell fragments, arbitrary Docker flags, host mounts or privileges.
public struct ScaffoldInstallationSpecification: Codable, Equatable, Sendable {
    public var format: String
    public var image: String
    public var container_platform: String
    public var service_profile: String?

    public init(format: String = "oci-image", image: String, container_platform: String = "linux/amd64", service_profile: String? = nil) {
        self.format = format
        self.image = image
        self.container_platform = container_platform
        self.service_profile = service_profile
    }
}
