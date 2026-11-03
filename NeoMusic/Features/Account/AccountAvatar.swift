import SwiftUI

struct AccountAvatar: View {
    let account: NeteaseAccount
    let size: CGFloat

    var body: some View {
        Group {
            if let data = account.avatarData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Circle()
                    .fill(LinearGradient(colors: [Color(red: 0.67, green: 0.77, blue: 0.90),
                                                 Color(red: 0.47, green: 0.51, blue: 0.73)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay {
                        Text("NM")
                            .font(.system(size: size * 0.447, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}

struct AccountButton: View {
    @Environment(NeteaseAccount.self) private var account
    var size: CGFloat = 36
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            AccountAvatar(account: account, size: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("账户")
        .accessibilityIdentifier("account.open")
        .sheet(isPresented: $isPresented) { AccountPage(account: account) }
    }
}

struct AccountToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) { AccountButton() }
    }
}
