import SwiftUI

struct CaptureView: View {
    @State private var viewModel: CaptureViewModel
    @FocusState private var editorFocused: Bool
    let unsyncedCount: Int
    let onShowList: () -> Void

    init(store: InklingStore, unsyncedCount: Int, onShowList: @escaping () -> Void) {
        _viewModel = State(initialValue: CaptureViewModel(store: store))
        self.unsyncedCount = unsyncedCount
        self.onShowList = onShowList
    }

    var body: some View {
        ZStack {
            InkwellPalette.parchment.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Spacer()

                InkwellView(isRecording: viewModel.isListening, inputLevel: viewModel.inputLevel)
                    .onTapGesture { viewModel.tapInkwell() }
                    .accessibilityLabel(viewModel.isListening ? "Stop and edit" : "Start capturing")
                    .accessibilityIdentifier("inkwell")

                promptOrTranscript
                    .padding(.top, 28)
                    .padding(.horizontal, 28)

                Spacer()

                footer
            }
            .padding(.bottom, 12)

            if viewModel.showConfirmation {
                confirmationToast
            }
        }
        .alert("Inkwell needs your voice", isPresented: $viewModel.authorizationDenied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Turn on Microphone and Speech Recognition access in Settings to capture by speaking.")
        }
    }

    private var header: some View {
        HStack {
            Text("inkwell")
                .font(.system(.subheadline, design: .serif))
                .foregroundStyle(InkwellPalette.ink.opacity(0.55))
                .tracking(2)
            Spacer()
            Button(action: onShowList) {
                HStack(spacing: 6) {
                    Image(systemName: "tray.full")
                    if unsyncedCount > 0 {
                        Text("\(unsyncedCount)")
                            .font(.caption.weight(.medium))
                            .accessibilityIdentifier("unsyncedCount")
                    }
                }
                .foregroundStyle(InkwellPalette.ink.opacity(0.6))
            }
            .accessibilityIdentifier("showList")
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var promptOrTranscript: some View {
        switch viewModel.mode {
        case .idle:
            Text("Tap the well to begin")
                .font(.system(.body, design: .serif))
                .foregroundStyle(InkwellPalette.ink.opacity(0.4))
                .frame(maxWidth: .infinity, alignment: .center)

        case .listening:
            Text(viewModel.displayedText.isEmpty ? "Listening…" : viewModel.displayedText)
                .font(.system(.title3, design: .serif))
                .foregroundStyle(viewModel.displayedText.isEmpty ? InkwellPalette.ink.opacity(0.35) : InkwellPalette.ink)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .top)
                .multilineTextAlignment(.leading)
                .contentShape(Rectangle())
                .onTapGesture { viewModel.beginEditing() }
                .accessibilityIdentifier("transcript")

        case .editing:
            VStack(alignment: .trailing, spacing: 8) {
                TextEditor(text: committedTextBinding)
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(InkwellPalette.ink)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120, maxHeight: 220)
                    .focused($editorFocused)
                    .onAppear { editorFocused = true }
                    .accessibilityIdentifier("transcriptEditor")
                    .toolbar {
                        // The footer's Done button sits behind the keyboard
                        // while editing - keep it reachable without forcing
                        // a keyboard dismissal first.
                        ToolbarItemGroup(placement: .keyboard) {
                            Button("Discard") {
                                editorFocused = false
                                viewModel.discard()
                            }
                            .foregroundStyle(InkwellPalette.ink.opacity(0.6))
                            Spacer()
                            Button("Done") {
                                editorFocused = false
                                viewModel.done()
                            }
                            .fontWeight(.semibold)
                            .accessibilityIdentifier("keyboardDone")
                        }
                    }

                Button {
                    editorFocused = false
                    viewModel.resumeDictation()
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.subheadline)
                        .foregroundStyle(InkwellPalette.parchment)
                        .padding(10)
                        .background(Circle().fill(InkwellPalette.amber))
                }
                .accessibilityLabel("Resume dictation")
            }
        }
    }

    private var committedTextBinding: Binding<String> {
        Binding(get: { viewModel.committedText }, set: { viewModel.updateCommittedText($0) })
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if viewModel.hasContent {
                Button("Discard") {
                    editorFocused = false
                    viewModel.discard()
                }
                .font(.system(.body, design: .serif))
                .foregroundStyle(InkwellPalette.ink.opacity(0.5))

                Spacer()

                Button("Done") {
                    editorFocused = false
                    viewModel.done()
                }
                .font(.system(.body, design: .serif, weight: .semibold))
                .foregroundStyle(InkwellPalette.parchment)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background(Capsule().fill(InkwellPalette.ink))
                .accessibilityIdentifier("done")
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 44)
        .animation(.easeInOut(duration: 0.2), value: viewModel.hasContent)
    }

    private var confirmationToast: some View {
        VStack {
            Spacer()
            Text("Got it. I'll get back to you.")
                .font(.system(.subheadline, design: .serif))
                .foregroundStyle(InkwellPalette.parchment)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Capsule().fill(InkwellPalette.ink))
                .padding(.bottom, 100)
                .accessibilityIdentifier("confirmationToast")
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.showConfirmation)
    }
}

#Preview {
    CaptureView(store: InklingStore(), unsyncedCount: 3, onShowList: {})
}
