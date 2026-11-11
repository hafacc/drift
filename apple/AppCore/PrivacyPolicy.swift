import SwiftUI

/// The privacy policy as shown in the apps; the site's page says the same.
struct PrivacyPolicyView: View {
  /// The policy on the web, for anyone who wants it outside the app.
  static let url = URL(string: "https://drift.hafa.cc/privacy")!

  #if os(iOS)
    private static let deviceKind = "iPhone"
  #else
    private static let deviceKind = "Mac"
  #endif

  private let sections: [(heading: String?, body: String)] = [
    (
      nil,
      "Drift doesn't collect or share any data about you. There are no accounts, ads, analytics, or tracking."
    ),
    (
      "Your air conditioner",
      "Drift talks to your air conditioner directly over your home Wi-Fi. Its settings and readings stay on your \(deviceKind)."
    ),
    (
      "Setup",
      "Newer air conditioners need a key before Drift can talk to them. During setup you sign in with your Midea account, and Drift asks Midea's cloud for that key, sending your Midea email and password and the air conditioner's ID. Your email and password go only to Midea, are never saved, and are cleared once setup ends. After setup Drift never contacts the cloud."
    ),
    (
      "On your \(deviceKind)",
      "The key is kept in the Keychain and is removed when you forget the air conditioner."
    ),
    ("Contact", "support@drift.hafa.cc"),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      ForEach(sections.indices, id: \.self) { index in
        let section = sections[index]
        VStack(alignment: .leading, spacing: 4) {
          if let heading = section.heading {
            Text(heading).font(.headline)
          }
          Text(section.body)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Link("View on the web", destination: Self.url)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
