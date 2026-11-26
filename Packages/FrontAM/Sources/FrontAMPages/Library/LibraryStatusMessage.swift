import FrontAMCore
import SwiftUI

public struct LibraryStatusMessage: View {
    public let message: String
    public var title = pageText("资料库状态")
    public var isError = false
    @State private var showsDetails = false

    private var summary: String { message.components(separatedBy: .newlines).first ?? message }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(summary, systemImage: isError ? "exclamationmark.circle" : "info.circle")
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .accessibilityLabel(message)
            Button(pageText("查看详情"), systemImage: "chevron.right") { showsDetails = true }
                .font(.footnote)
                .accessibilityLabel(pageText("查看\(title)详情"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .sheet(isPresented: $showsDetails) {
            NavigationStack {
                ScrollView {
                    Text(message).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(pageText("关闭"), systemImage: "xmark", role: .close) { showsDetails = false }
                    }
                }
            }
        }
    }

    public init(message: String,
                title: String = pageText("资料库状态"),
                isError: Bool = false) {
        self.message = message
        self.title = title
        self.isError = isError
    }
}
