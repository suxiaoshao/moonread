import SwiftUI

struct AboutView: View {
    @Environment(\.theme) private var theme
    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    BrandSeal(size: 80)
                    Text("月读").font(.title2.bold())
                    Text(verbatim: "Moonread · \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")") .font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                }.frame(maxWidth: .infinity).padding(.vertical, 24)
            }.listRowBackground(Color.clear)
            Section("数据与隐私") {
                Text("小说保存在我的书架或你添加的目录；我的书架可接入应用固定的 iCloud 文件目录。阅读数据可选择通过 iCloud 同步，显示与阅读偏好保存在此设备。")
                Link("隐私政策", destination: AppLinks.privacy()).accessibilityIdentifier("privacyPolicyLink")
                Link("帮助与支持", destination: AppLinks.support()).accessibilityIdentifier("helpSupportLink")
                if let contact = AppLinks.contact {
                    Link(destination: contact) {
                        VStack(alignment: .leading) {
                            Text("联系开发者")
                            Text(verbatim: AppLinks.supportEmail).font(.caption)
                        }
                    }.accessibilityIdentifier("contactDeveloperLink")
                }
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            Section("主要开源组件") {
                NavigationLink("第三方许可") { ThirdPartyLicensesView() }
                    .accessibilityIdentifier("thirdPartyLicenses")
                Link("UniFFI", destination: URL(string: "https://github.com/mozilla/uniffi-rs")!)
                Link("SQLite / rusqlite", destination: URL(string: "https://github.com/rusqlite/rusqlite")!)
                Link("Serde", destination: URL(string: "https://github.com/serde-rs/serde")!)
                Link("encoding_rs", destination: URL(string: "https://github.com/hsivonen/encoding_rs")!)
                Link("regex", destination: URL(string: "https://github.com/rust-lang/regex")!)
                Link("SHA-2", destination: URL(string: "https://github.com/RustCrypto/hashes")!)
                Link("UUID", destination: URL(string: "https://github.com/uuid-rs/uuid")!)
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
        }.themedPage().navigationTitle("关于月读").navigationBarTitleDisplayMode(.inline)
    }
}
