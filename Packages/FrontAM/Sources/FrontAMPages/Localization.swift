import Foundation

@usableFromInline
func pageText(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: .module)
}
