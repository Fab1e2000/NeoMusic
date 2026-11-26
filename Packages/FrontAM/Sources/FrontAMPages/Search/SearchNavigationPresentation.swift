import FrontAMNavigation
import SwiftUI

public extension SearchPageModel {
    var navigationPresentation: FrontAMSearchPresentation {
        FrontAMSearchPresentation(query: Binding(get: { self.query }, set: { self.input($0) }),
            prompt: searchPrompt,
            isSearching: { self.isSearching }, isSubmitted: { self.submitted },
            onPresent: { self.isSearching = true }, onDismiss: cancel, onSubmit: { self.submit() }, onResumeEditing: resumeEditing)
    }
}

extension View {
    public func librarySearchPage(_ model: SearchPageModel) -> some View {
        frontAMSearchPage(model.navigationPresentation, submitted: model.submitted)
    }
}

