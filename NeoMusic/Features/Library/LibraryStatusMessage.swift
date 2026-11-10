import SwiftUI

struct LibraryStatusMessage: View {
    let message: String
    var title = "资料库状态"
    var isError = false
    @State private var showsDetails = false

    private var summary: String { message.components(separatedBy: .newlines).first ?? message }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(summary, systemImage: isError ? "exclamationmark.circle" : "info.circle")
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .accessibilityLabel(message)
            Button("查看详情", systemImage: "chevron.right") { showsDetails = true }
                .font(.footnote)
                .accessibilityLabel("查看\(title)详情")
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
                        Button("关闭", systemImage: "xmark", role: .close) { showsDetails = false }
                    }
                }
            }
        }
    }
}
