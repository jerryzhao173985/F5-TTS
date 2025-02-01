import SwiftUI
import F5TTS
import AVFoundation
import Speech
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = F5TTSViewModel()
    @StateObject private var audioHistoryManager = AudioHistoryManager()
    
    @State private var isPlayingAudio: Bool = false
    @State private var audioToPlay: URL?
    @State private var audioToDisplay: String = ""
    
    @State private var showingFileImporter = false
    @State private var isRecording = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    
    @FocusState private var inputTextFieldIsFocused: Bool

    var body: some View {
        NavigationView {
            ZStack {
                // Background overlay for keyboard dismissal
                Color.clear
                    .contentShape(Rectangle())  // Make the entire area tappable
                    .onTapGesture {
                        inputTextFieldIsFocused = false
                    }
                VStack(spacing: 20) {
                    
                    TextEditor(text: $viewModel.inputText)
                        .focused($inputTextFieldIsFocused)
                        .padding()
                        .border(Color.gray, width: 1)
                        .frame(height: 150)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                        )
                        .padding(.horizontal)
                    // Add toolbar with Done button
                        .toolbar {
                            ToolbarItemGroup(placement: .keyboard) {
                                Spacer()
                                Button("Done") {
                                    inputTextFieldIsFocused = false
                                }
                            }
                        }
                    
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
                        } // End of fileImporter
                        
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
                        } // End of Button
                    } // End of HStack
                    .padding(.horizontal)
                    
                    HStack(spacing: 20) {
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
                    }
                    
                    // Audio History List
                    List(viewModel.audioHistory) { item in
                        Button(action: {
                            if audioHistoryManager.currentlyPlayingId == item.id {
                                audioHistoryManager.stopCurrentAudio()
                            } else {
                                audioHistoryManager.playAudio(fileName: item.audioFileName, itemId: item.id)
                            }
                        }) {
                            HStack {
                                Text(item.title)
                                Spacer()
                                Image(systemName: audioHistoryManager.currentlyPlayingId == item.id ?
                                      "stop.circle.fill" : "play.circle.fill")
                            }
                        }
                    }
                    .frame(maxHeight: 600) // Limit height to make it scrollable
                    
                    //                Spacer()
                } // End of VStack
            } // End of ZStack
            .navigationTitle("F5 TTS App")
            .alert(isPresented: $showAlert) {
                Alert(
                    title: Text("Notice"),
                    message: Text(alertMessage),
                    dismissButton: .default(Text("OK"))
                )
            }
        } // End of NavigationView
        .onAppear {
            viewModel.initializeF5TTS()
            viewModel.requestPermissions()
        }
        .onDisappear {
            audioHistoryManager.stopCurrentAudio()
        }
    } // End of body
}

class AudioHistoryManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var currentlyPlayingId: UUID?
    private var audioPlayer: AVAudioPlayer?
    
    override init() {
        super.init()
        setupAudioSession()
    }
    
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    func playAudio(fileName: String, itemId: UUID) {
        // Stop current audio if playing
        stopCurrentAudio()
        
        let fileURL = getDocumentsDirectory().appendingPathComponent(fileName)
        print("Attempting to play audio from: \(fileURL)")
        
        do {
            // Verify file exists
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                print("Audio file doesn't exist at path: \(fileURL.path)")
                return
            }
            
            audioPlayer = try AVAudioPlayer(contentsOf: fileURL)
            audioPlayer?.delegate = self
            
            guard let player = audioPlayer else {
                print("Failed to create audio player")
                return
            }
            
            if player.prepareToPlay() {
                print("Audio prepared successfully")
                if player.play() {
                    print("Audio started playing")
                    currentlyPlayingId = itemId
                } else {
                    print("Failed to start audio playback")
                }
            } else {
                print("Failed to prepare audio")
            }
        } catch {
            print("Error playing audio: \(error.localizedDescription)")
            currentlyPlayingId = nil
        }
    }
    
    func stopCurrentAudio() {
        print("Stopping current audio")
        audioPlayer?.stop()
        currentlyPlayingId = nil
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        print("Audio finished playing, success: \(flag)")
        DispatchQueue.main.async {
            self.currentlyPlayingId = nil
        }
    }
}

extension UIApplication {
    func endEditing() {
        self.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
