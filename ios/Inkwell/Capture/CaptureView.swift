import SwiftUI

struct CaptureView: View {
    @State private var viewModel: CaptureViewModel
    @FocusState private var editorFocused: Bool
    let unsyncedCount: Int
    let onShowList: () -> Void

    private static let transcriptBottomID = "transcriptBottom"

    init(store: InklingStore, unsyncedCount: Int, onShowList: @escaping () -> Void) {
        _viewModel = State(initialValue: CaptureViewModel(store: store))
        self.unsyncedCount = unsyncedCount
        self.onShowList = onShowList
    }

    /// Full size at rest; shrunk once engaged so the transcript - the thing
    /// that actually needs the room - gets most of what the well gives up.
    private var inkwellScale: CGFloat {
        viewModel.mode == .idle ? 1 : 0.5
    }

    var body: some View {
        ZStack {
            InkwellPalette.parchment.ignoresSafeArea()

            // The column is taller than what's left once the keyboard takes
            // half the screen, and taller than a small phone even without
            // one. Laid out directly, it hands its full height back to the
            // ZStack, and the root then centres that overflow - which is what
            // pushed the wordmark and tray icon out of the safe area and onto
            // the status bar. Overlaying it on a view that keeps the size it
            // was offered decouples the two: the header stays pinned below
            // the status bar, the footer stays above the keyboard, and the
            // transcript in between absorbs whatever room is left.
            Color.clear.overlay(alignment: .top) {
                VStack(spacing: 0) {
                    header

                    // Bounded to whatever room is actually left, then
                    // scrollable within that - the well shrinking while
                    // engaged buys back most of it, but rambling for a while
                    // (the whole point of this screen) can still out-grow
                    // any fixed height, on any device. Without this, the
                    // words the owner just said scroll off the bottom of the
                    // screen with no way to see them - unacceptable for a
                    // tool whose entire job is not losing what he says.
                    GeometryReader { proxy in
                        ScrollViewReader { scrollProxy in
                            ScrollView {
                                VStack(spacing: 0) {
                                    Spacer(minLength: 8)

                                    InkwellView(isRecording: viewModel.isListening, inputLevel: viewModel.inputLevel)
                                        .scaleEffect(inkwellScale)
                                        .frame(width: InkwellView.containerSize * inkwellScale, height: InkwellView.containerSize * inkwellScale)
                                        .animation(.easeInOut(duration: 0.25), value: inkwellScale)
                                        .onTapGesture { viewModel.tapInkwell() }
                                        .accessibilityLabel(viewModel.isListening ? "Stop and edit" : "Start capturing")
                                        .accessibilityIdentifier("inkwell")

                                    promptOrTranscript
                                        .padding(.top, 28)
                                        .padding(.horizontal, 28)
                                        .id(Self.transcriptBottomID)

                                    Spacer(minLength: 8)
                                }
                                .frame(minHeight: proxy.size.height)
                            }
                            .onChange(of: viewModel.displayedText) {
                                guard viewModel.isListening else { return }
                                withAnimation(.easeOut(duration: 0.15)) {
                                    scrollProxy.scrollTo(Self.transcriptBottomID, anchor: .bottom)
                                }
                            }
                            // Resuming dictation onto a long already-committed
                            // draft doesn't change displayedText's value by
                            // itself (engine.transcript starts fresh at ""),
                            // so the onChange above never fires - without
                            // this, the view sits wherever it last scrolled
                            // to (mid-editor) instead of showing where new
                            // words are about to appear.
                            .onChange(of: viewModel.mode) {
                                guard viewModel.isListening else { return }
                                scrollProxy.scrollTo(Self.transcriptBottomID, anchor: .bottom)
                            }
                        }
                    }

                    footer
                }
                .padding(.bottom, 12)
            }
            .alert("That one didn't save", isPresented: $viewModel.saveFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your words are still here. Tap Done again in a moment.")
            }
            .alert(
                recognitionFailureAlertTitle,
                isPresented: $viewModel.showRecognitionFailureAlert
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(recognitionFailureAlertMessage)
            }

            if viewModel.showConfirmation {
                confirmationToast
            }

            if viewModel.showEmptyDoneHint {
                emptyDoneHint
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
                        // Discard and Done within thumb reach of the keys,
                        // rather than making the owner reach past the
                        // keyboard for the footer's pair - which stands down
                        // while these are showing.
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

    /// No audio at all is a more specific, more actionable fact than a
    /// generic recognition failure - the owner can check mic access or the
    /// simulator's audio input instead of just trying again and hoping.
    private var recognitionFailureAlertTitle: String {
        if viewModel.noAudioDetected { return "No sound reached the microphone" }
        return viewModel.recognitionFailedWithWordsHeard ? "Dictation stopped" : "Didn't catch that"
    }

    private var recognitionFailureAlertMessage: String {
        if viewModel.noAudioDetected {
            return "Check mic access for this simulator/device, then try again."
        }
        return viewModel.recognitionFailedWithWordsHeard
            ? "Your words are here - type the rest, or try the well again."
            : "Speech recognition didn't come through. Type it in instead, or try the well again."
    }

    /// The keyboard accessory carries its own Discard and Done while the
    /// editor holds focus. Now that the column is bounded and the footer
    /// survives above the keyboard rather than hiding behind it, showing both
    /// puts two identical control sets a few points apart.
    private var isEditingWithKeyboard: Bool {
        viewModel.mode == .editing && editorFocused
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if viewModel.hasContent && !isEditingWithKeyboard {
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
        .animation(.easeInOut(duration: 0.2), value: editorFocused)
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

    private var emptyDoneHint: some View {
        VStack {
            Spacer()
            Text("Nothing to save - tap Discard to leave without keeping the recording.")
                .font(.system(.subheadline, design: .serif))
                .foregroundStyle(InkwellPalette.parchment)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 22).fill(InkwellPalette.ink))
                .padding(.horizontal, 24)
                .padding(.bottom, 100)
                .accessibilityIdentifier("emptyDoneHint")
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.showEmptyDoneHint)
    }
}

#Preview {
    CaptureView(store: InklingStore(), unsyncedCount: 3, onShowList: {})
}
