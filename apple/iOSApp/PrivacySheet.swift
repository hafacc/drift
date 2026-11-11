import SwiftUI

/// The privacy policy in a sheet with a Done button.
struct PrivacySheet: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        PrivacyPolicyView()
          .padding()
      }
      .navigationTitle("Privacy")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }
}
