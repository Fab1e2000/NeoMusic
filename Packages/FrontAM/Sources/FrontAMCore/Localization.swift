import Foundation

func coreText(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: .module)
}
