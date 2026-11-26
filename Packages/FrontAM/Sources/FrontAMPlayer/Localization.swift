import Foundation

func playerText(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: .module)
}
