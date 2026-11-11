import SwiftUI

/// First-run setup: the Midea account, the Set Up button, and how setup is going.
struct SetupView: View {
  @Environment(DeviceStore.self) private var store
  @Environment(\.scenePhase) private var scenePhase
  @ScaledMetric private var labelWidth: CGFloat = 88
  @State private var showingPrivacy = false

  var body: some View {
    @Bindable var store = store
    NavigationStack {
      Form {
        Section {
          HStack {
            Text("Email")
              .frame(width: labelWidth, alignment: .leading)
            TextField("Email", text: $store.cloudAccount.email, prompt: Text("you@example.com"))
              .textContentType(.username)
              .keyboardType(.emailAddress)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
          }
          HStack {
            Text("Password")
              .frame(width: labelWidth, alignment: .leading)
            SecureField("Password", text: $store.cloudAccount.password, prompt: Text("Required"))
              .textContentType(.password)
              .onSubmit { store.setup() }
          }
        } header: {
          VStack(alignment: .leading, spacing: 20) {
            Text(
              "Drift finds your air conditioner on this Wi-Fi network, then signs in to your Midea account once to get its key."
            )
            .font(.subheadline)
            .foregroundStyle(.primary)
            .textCase(nil)
            Text("Midea Account")
          }
        } footer: {
          Text(
            "Use the account the AC was added to in the MSmartHome app. Your email and password go only to Midea and aren't saved."
          )
        }
        .disabled(store.setupPhase.isRunning)

        Section {
          Button {
            store.setup()
          } label: {
            Text("Set Up")
              .fontWeight(.semibold)
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(!canStart)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())

          if case .running(let step) = store.setupPhase {
            progressLine(step.message)
              .listRowBackground(Color.clear)
          }
        }

        if let failure = store.setupPhase.failure {
          Section {
            failureCard(failure)
          }
        }
      }
      .navigationTitle("Set Up Drift")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Privacy") { showingPrivacy = true }
        }
      }
      .sheet(isPresented: $showingPrivacy) { PrivacySheet() }
    }
    .onAppear { store.resumeSetup() }
    .onDisappear { store.pauseSetup() }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .background: store.pauseSetup()
      case .active: store.resumeSetup()
      default: break
      }
    }
  }

  /// Whether Set Up can start: the account is filled in and nothing is running or waiting.
  private var canStart: Bool {
    switch store.setupPhase {
    case .idle, .failed: store.cloudAccount.isComplete
    case .running, .waiting: false
    }
  }

  private func progressLine(_ message: String) -> some View {
    HStack(spacing: 10) {
      ProgressView()
      Text(message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }

  /// What failed, what to do about it, and the countdown to the next try.
  private func failureCard(_ failure: SetupFailure) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 4) {
        Text(failure.message)
          .font(.subheadline)
          .fontWeight(.semibold)
        if !failure.hint.isEmpty {
          Text(failure.hint)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        if case .waiting(_, let retryDate, let step) = store.setupPhase {
          TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = Int(retryDate.timeIntervalSince(context.date).rounded(.up))
            Text(step.retryMessage(in: seconds))
              .font(.footnote)
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
        }
      }
    }
    .padding(.vertical, 4)
  }
}

#Preview {
  SetupView()
    .environment(DeviceStore())
}
