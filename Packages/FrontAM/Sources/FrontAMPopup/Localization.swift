import Foundation

func popupText(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: .module)
}
