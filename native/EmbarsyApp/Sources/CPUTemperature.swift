import Foundation

/// Reads CPU die temperature (°C) on Apple Silicon via the private IOKit HID
/// thermal-sensor API — the same mechanism Stats / macmon use. No sudo, no
/// entitlements; these are private symbols, so everything is loaded defensively
/// via dlsym and returns nil if anything is missing (e.g. a future OS change).
enum CPUTemperature {
    private static let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

    private typealias CreateFn       = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn  = @convention(c) (AnyObject, CFDictionary) -> Void
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyEventFn    = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatFn     = @convention(c) (AnyObject, Int32) -> Double
    private typealias CopyPropFn     = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?

    private static func sym<T>(_ name: String, _ type: T.Type) -> T? {
        guard let lib, let p = dlsym(lib, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    /// One shared client, matched to the thermal-sensor usage page.
    private static let client: AnyObject? = {
        guard let create = sym("IOHIDEventSystemClientCreate", CreateFn.self),
              let setMatch = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self),
              let c = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }
        setMatch(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        return c
    }()

    /// Average CPU die temperature in °C, or nil when unavailable.
    static func read() -> Double? {
        guard let client,
              let copySvcs = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
              let copyEvt  = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self),
              let getFloat = sym("IOHIDEventGetFloatValue", GetFloatFn.self),
              let copyProp = sym("IOHIDServiceClientCopyProperty", CopyPropFn.self),
              let servicesRef = copySvcs(client)?.takeRetainedValue()
        else { return nil }

        let services = servicesRef as [AnyObject]
        let kTemperature: Int64 = 15
        let field = Int32(kTemperature << 16)

        var temps: [Double] = []
        for svc in services {
            guard let nameRef = copyProp(svc, "Product" as CFString)?.takeRetainedValue(),
                  let name = nameRef as? String else { continue }
            let n = name.lowercased()
            // CPU die sensors (Apple Silicon: "PMU tdie*"); skip battery/NAND/GPU/etc.
            guard n.contains("tdie") || n.hasPrefix("cpu") || n.contains("pacc") || n.contains("eacc") else { continue }
            guard let evRef = copyEvt(svc, kTemperature, 0, 0)?.takeRetainedValue() else { continue }
            let t = getFloat(evRef, field)
            if t > 0, t < 130 { temps.append(t) }   // drop invalid readings (e.g. -9200)
        }
        guard !temps.isEmpty else { return nil }
        return temps.reduce(0, +) / Double(temps.count)
    }
}
