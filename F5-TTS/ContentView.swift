import SwiftUI
import F5TTS
import AVFoundation
import Speech
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = F5TTSViewModel()
    @State private var showingFileImporter = false
    @State private var isRecording = false
    @State private var showAlert = false
    @State private var alertMessage = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                TextEditor(text: $viewModel.inputText)
                    .padding()
                    .border(Color.gray, width: 1)
                    .frame(height: 150)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                    )
                    .padding(.horizontal)
                    .gesture(
                        TapGesture().onEnded {
                            UIApplication.shared.endEditing() // This dismisses the keyboard
                        }
                    )

                HStack(spacing: 20) {
                    Button(action: {
                        showingFileImporter = true
                    }) {
                        HStack {
                            Image(systemName: "doc.text")
                            Text("Upload Text File")
                        }
                    }
                    .fileImporter(
                        isPresented: $showingFileImporter,
                        allowedContentTypes: [UTType.plainText],
                        allowsMultipleSelection: false
                    ) { result in
                        switch result {
                        case .success(let urls):
                            guard let selectedFile = urls.first else { return }
                            viewModel.handleFileImport(url: selectedFile) { success, message in
                                if !success {
                                    alertMessage = message
                                    showAlert = true
                                }
                            }
                        case .failure(let error):
                            alertMessage = "Error importing file: \(error.localizedDescription)"
                            showAlert = true
                        }
                    }

                    Button(action: {
                        if isRecording {
                            viewModel.stopRecording()
                            isRecording = false
                        } else {
                            viewModel.startRecording { success, message in
                                if success {
                                    isRecording = true
                                }
                                else {
                                    alertMessage = message
                                    showAlert = true
                                }
                            }
                        }
                    }) {
                        HStack {
                            Image(systemName: isRecording ? "stop.circle" : "mic.circle")
                            Text(isRecording ? "Stop Recording" : "Start Recording")
                        }
                    }
                }
                .padding(.horizontal)

                Button(action: {
                    viewModel.generateSpeech()
                }) {
                    HStack {
                        Image(systemName: "play.circle")
                        Text("Generate Speech")
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)  // Rounded corners for better look
                    .padding(.horizontal)
                    .shadow(radius: 5)  // Add shadow for interactivity
                }
                
                .disabled(viewModel.inputText.isEmpty || viewModel.isGenerating)

                if viewModel.isGenerating {
                    ProgressView("Generating Speech...")
                        .padding()
                }

                if let audioURL = viewModel.generatedAudioURL {
                    AudioPlayerView(audioURL: audioURL)
                        .padding()
                }

                Spacer()
            }
            .navigationTitle("F5 TTS App")
            .alert(isPresented: $showAlert) {
                Alert(
                    title: Text("Notice"),
                    message: Text(alertMessage),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        .onAppear {
            viewModel.initializeF5TTS()
            viewModel.requestPermissions()
        }
    }
}

struct AudioPlayerView: View {
    let audioURL: URL
    @StateObject private var audioManager = AudioManager()

    var body: some View {
        VStack {
            Button(action: {
                if audioManager.isPlaying {
                    audioManager.stopAudio()
                } else {
                    audioManager.playAudio(from: audioURL)
                }
            }) {
                HStack {
                    Image(systemName: audioManager.isPlaying ? "stop.circle.fill" : "play.circle.fill")
                        .font(.largeTitle)
                    Text(audioManager.isPlaying ? "Stop Audio" : "Play Audio")
                        .font(.title2)
                }
            }
        }
    }
}

class AudioManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    private var audioPlayer: AVAudioPlayer?
    @Published var isPlaying = false

    func playAudio(from url: URL) {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            isPlaying = true
        } catch {
            print("Error playing audio: \(error.localizedDescription)")
        }
    }

    func stopAudio() {
        audioPlayer?.stop()
        isPlaying = false
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
        }
    }
}

extension UIApplication {
    func endEditing() {
        self.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
