import SwiftUI
import UIKit

struct MobileContentView: View {
    @ObservedObject var coordinator: DictationCoordinator

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    hero
                    statusCard
                    modelCard
                    if coordinator.isSessionActive { sessionCard }
					if !coordinator.history.isEmpty { historyCard }
                    setupCard
                    privacyCard
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Scribe")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var hero: some View {
        VStack(spacing: 16) {
            Button {
                Task {
                    switch coordinator.state {
                    case .recording:
                        await coordinator.stopAndTranscribe()
                    default:
                        await coordinator.startRecording()
                    }
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(heroColor.gradient)
                        .frame(width: 124, height: 124)
                        .shadow(color: heroColor.opacity(0.28), radius: 24, y: 12)

                    Image(systemName: heroSymbol)
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, isActive: coordinator.state == .recording)
                }
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityLabel(heroTitle)

            Text(heroTitle)
                .font(.title2.bold())
            Text(heroSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 16)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: statusSymbol)
                    .font(.title3)
                    .foregroundStyle(statusColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.headline)
                    Text(statusDetail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if isBusy { ProgressView() }
            }

            if case .recording = coordinator.state {
                GeometryReader { proxy in
                    Capsule()
                        .fill(.quaternary)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Color.red.gradient)
                                .frame(width: max(8, proxy.size.width * coordinator.audioLevel))
                        }
                }
                .frame(height: 8)

                Button("Cancel", role: .destructive) { coordinator.cancelRecording() }
                    .font(.subheadline.weight(.semibold))
            }

            if case .failed = coordinator.state {
                Button(coordinator.canRetryFailedTranscription ? "Retry saved recording" : "Try again") {
					Task {
						if coordinator.canRetryFailedTranscription {
							await coordinator.retryLastTranscription()
						} else {
							await coordinator.startRecording()
						}
					}
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var sessionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Flow session active", systemImage: "mic.badge.plus")
                    .font(.headline)
                    .foregroundStyle(.green)
                Spacer()
                Button("End", role: .destructive) { coordinator.endFlowSession() }
                    .font(.subheadline.weight(.semibold))
            }
            Text("The mic stays ready so the keyboard can dictate in any app without opening Scribe. The session ends 15 minutes after your last dictation.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let expiry = coordinator.sessionExpiresAt {
                Text("Ends at \(expiry, style: .time) unless you keep dictating")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(coordinator.activeModelName)
                        .font(.headline)
                    Text(coordinator.modelInstallationMessage.isEmpty
                         ? "Private, on-device transcription"
                         : coordinator.modelInstallationMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let progress = coordinator.modelInstallationProgress {
                ProgressView(value: progress)
                    .tint(.indigo)
                Text("Keep Scribe open while the private on-device model installs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if coordinator.refinementReadiness == .ready {
                Divider()
                Toggle(isOn: $coordinator.usesOnDeviceRefinement) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Polish with Apple Intelligence")
                            .font(.subheadline.weight(.medium))
                        Text("Adds punctuation and sentence breaks on device. Scribe keeps its own result if the model changes any of your words.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.indigo)
            }
        }
        .task { await coordinator.refreshRefinementReadiness() }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Use Scribe in every app", systemImage: "keyboard")
                .font(.headline)

            setupRow(1, "Add Scribe Keyboard", "Settings → General → Keyboard → Keyboards")
            setupRow(2, "Allow Full Access", "Required only for private app-to-keyboard handoff")
            setupRow(3, "Tap Dictate", "The first tap opens Scribe to start a session; after that, dictate anywhere without leaving your app")

            Button("Open Scribe Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .buttonStyle(.bordered)
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

	private var historyCard: some View {
		VStack(alignment: .leading, spacing: 14) {
			Label("Recent dictations", systemImage: "clock.arrow.circlepath")
				.font(.headline)

			ForEach(Array(coordinator.history.prefix(3).enumerated()), id: \.element.id) { index, item in
				Button {
					UIPasteboard.general.string = item.text
				} label: {
					HStack(alignment: .top, spacing: 12) {
						VStack(alignment: .leading, spacing: 4) {
							Text(item.text)
								.font(.subheadline)
								.foregroundStyle(.primary)
								.lineLimit(2)
							Text(item.createdAt, style: .relative)
								.font(.caption)
								.foregroundStyle(.secondary)
						}
						Spacer()
						Image(systemName: "doc.on.doc")
							.foregroundStyle(.secondary)
					}
				}
				.buttonStyle(.plain)

				if index < min(3, coordinator.history.count) - 1 {
					Divider()
				}
			}
		}
		.padding(18)
		.background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
	}

    private var privacyCard: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text("Private by design").font(.headline)
                Text("Audio and transcripts stay on this iPhone. The model downloads once, then runs offline.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.green)
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func setupRow(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var isBusy: Bool {
        coordinator.state == .preparing || coordinator.state == .transcribing
    }

    private var heroColor: Color {
        switch coordinator.state {
        case .recording: .red
        case .completed: .green
        case .failed: .orange
        default: .indigo
        }
    }

    private var heroSymbol: String {
        switch coordinator.state {
        case .recording: "stop.fill"
        case .completed: "checkmark"
        case .failed: "arrow.clockwise"
        default: "mic.fill"
        }
    }

    private var heroTitle: String {
        switch coordinator.state {
        case .preparing: "Preparing Scribe"
        case .ready: "Tap to dictate"
        case .recording: "Recording is on"
        case .transcribing: "Polishing your words"
        case .completed: "Ready in the keyboard"
        case .failed: "Scribe needs attention"
        }
    }

    private var heroSubtitle: String {
        switch coordinator.state {
        case .preparing: "Downloading or loading the private on-device model"
        case .ready: "Or open the Scribe keyboard from any text field"
        case .recording: "Swipe right along the bottom edge to return—recording continues"
        case .transcribing: "You can swipe back to the app where you were typing"
        case .completed: "Swipe back; your words will be inserted at the cursor"
        case let .failed(message): message
        }
    }

    private var statusSymbol: String {
        switch coordinator.state {
        case .preparing, .transcribing: "sparkles"
        case .ready: "checkmark.circle.fill"
        case .recording: "waveform"
        case .completed: "keyboard.badge.ellipsis"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch coordinator.state {
        case .failed: .orange
        case .recording: .red
        case .completed, .ready: .green
        default: .indigo
        }
    }

    private var statusTitle: String { heroTitle }
    private var statusDetail: String { heroSubtitle }
}
