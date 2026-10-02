import Foundation

/// The reader's light/dark choice. `system` follows the device appearance; `light` and
/// `dark` pin the reader regardless of the time of day.
public enum ReaderAppearanceMode: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    /// Unknown stored values (from a newer client) fall back to following the system.
    public init(storedValue: String) {
        self = Self(rawValue: storedValue) ?? .system
    }

    public func isDark(systemIsDark: Bool) -> Bool {
        switch self {
            case .system: systemIsDark
            case .light: false
            case .dark: true
        }
    }
}

/// Stepped choices for the simplified Customize Reader menu. The underlying settings stay
/// continuous so values set on another device or in an older build remain valid; a value
/// between presets simply shows no preset selected.
public enum ReaderTypography {
    public static let fontSizeSteps: [Double] = [
        12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 32, 36, 40, 44, 48, 56,
    ]

    /// The next step above `size`, or nil at the largest step.
    public static func larger(than size: Double) -> Double? {
        fontSizeSteps.first { $0 > size + 0.001 }
    }

    /// The next step below `size`, or nil at the smallest step.
    public static func smaller(than size: Double) -> Double? {
        fontSizeSteps.last { $0 < size - 0.001 }
    }

    /// Size relative to the default, for display ("100%").
    public static func percentOfDefault(_ size: Double) -> Int {
        Int((size / kDefaultFontSize * 100).rounded())
    }

    public enum LineSpacing: String, CaseIterable, Identifiable, Sendable {
        case compact
        case normal
        case relaxed

        public var id: String { rawValue }

        public var value: Double {
            switch self {
                case .compact: 1.2
                case .normal: kDefaultLineSpacing
                case .relaxed: 1.8
            }
        }

        public static func matching(_ value: Double) -> Self? {
            allCases.first { abs($0.value - value) < 0.001 }
        }
    }

    /// One margin choice sets both the side and the top/bottom margins (percentages).
    public enum Margins: String, CaseIterable, Identifiable, Sendable {
        case narrow
        case normal
        case wide

        public var id: String { rawValue }

        public var leftRight: Double {
            switch self {
                case .narrow: 0
                case .normal: kDefaultMarginLeftRightIOS
                case .wide: 8
            }
        }

        public var topBottom: Double {
            switch self {
                case .narrow: 4
                case .normal: kDefaultMarginTopBottom
                case .wide: 12
            }
        }

        public static func matching(leftRight: Double, topBottom: Double) -> Self? {
            allCases.first {
                abs($0.leftRight - leftRight) < 0.001 && abs($0.topBottom - topBottom) < 0.001
            }
        }
    }
}
