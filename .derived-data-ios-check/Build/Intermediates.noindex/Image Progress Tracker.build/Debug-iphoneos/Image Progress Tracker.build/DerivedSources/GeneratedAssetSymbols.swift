import Foundation
#if canImport(DeveloperToolsSupport)
import DeveloperToolsSupport
#endif

#if SWIFT_PACKAGE
private let resourceBundle = Foundation.Bundle.module
#else
private class ResourceBundleClass {}
private let resourceBundle = Foundation.Bundle(for: ResourceBundleClass.self)
#endif

// MARK: - Color Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ColorResource {

    /// The "LaunchScreenColor" asset catalog color resource.
    static let launchScreen = DeveloperToolsSupport.ColorResource(name: "LaunchScreenColor", bundle: resourceBundle)

}

// MARK: - Image Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ImageResource {

    /// The "LaunchScreenImage" asset catalog image resource.
    static let launchScreen = DeveloperToolsSupport.ImageResource(name: "LaunchScreenImage", bundle: resourceBundle)

    /// The "test1" asset catalog image resource.
    static let test1 = DeveloperToolsSupport.ImageResource(name: "test1", bundle: resourceBundle)

    /// The "test2" asset catalog image resource.
    static let test2 = DeveloperToolsSupport.ImageResource(name: "test2", bundle: resourceBundle)

    /// The "test3" asset catalog image resource.
    static let test3 = DeveloperToolsSupport.ImageResource(name: "test3", bundle: resourceBundle)

    /// The "test4" asset catalog image resource.
    static let test4 = DeveloperToolsSupport.ImageResource(name: "test4", bundle: resourceBundle)

    /// The "test5" asset catalog image resource.
    static let test5 = DeveloperToolsSupport.ImageResource(name: "test5", bundle: resourceBundle)

}

