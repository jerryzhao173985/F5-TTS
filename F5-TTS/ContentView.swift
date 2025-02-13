import SwiftUI
import F5TTS
import AVFoundation
import Speech
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = F5TTSViewModel()
    @StateObject private var audioHistoryManager = AudioHistoryManager()
    
    // State for file importers
    @State private var showingTextFileImporter = false
    @State private var showingReferenceAudioPicker = false
    
    @State private var isRecording = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    
    // For the "Show full text" sheet using context menu.
    @State private var selectedAudioHistoryItem: AudioHistoryItem?
    @State private var isShowingFullTextSheet = false
    
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
                    
                    // TextEditor for user prompt input
                    TextEditor(text: $viewModel.inputText)
                        .focused($inputTextFieldIsFocused)
                        .padding()
                        .border(Color.gray, width: 1)
                        .frame(height: 150)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                        )
                        .toolbar {
                            ToolbarItemGroup(placement: .keyboard) {
                                Spacer()
                                Button("Done") {
                                    inputTextFieldIsFocused = false
                                }
                            }
                        }
                        .padding(.horizontal)
                    
                    // Row with "Upload Text File" and "Start/Stop Recording" buttons
                    HStack(spacing: 20) {
                        // Upload Text File Button
                        Button {
                            showingTextFileImporter = true
                        } label: {
                            Label("Upload Text File", systemImage: "doc.text")
                        }
                        .fileImporter(
                            isPresented: $showingTextFileImporter,
                            allowedContentTypes: [UTType.plainText],
                            allowsMultipleSelection: false
                        ) { result in
                            switch result {
                            case .success(let urls):
                                guard let url = urls.first else { return }
                                if url.startAccessingSecurityScopedResource() {
                                    defer { url.stopAccessingSecurityScopedResource() }
                                    do {
                                        let text = try String(contentsOf: url, encoding: .utf8)
                                        viewModel.inputText = text
                                    } catch {
                                        alertMessage = "Error loading text file: \(error.localizedDescription)"
                                        showAlert = true
                                    }
                                } else {
                                    alertMessage = "Permission denied for file."
                                    showAlert = true
                                }
                                
                            case .failure(let error):
                                alertMessage = "Error importing text file: \(error.localizedDescription)"
                                showAlert = true
                            }
                        }
                        
                        // Start/Stop Recording Button for the main prompt
                        Button(action: {
                            if isRecording {
                                viewModel.stopRecording()
                                isRecording = false
                            } else {
                                viewModel.startRecording { success, message in
                                    if success {
                                        isRecording = true
                                    } else {
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
                    
                    // Row with "Upload Reference" and "Record Your Own Voice" buttons
                    HStack {
                        // Upload Reference Button (renamed from "Upload Reference Audio File")
                        Button {
                            showingReferenceAudioPicker = true
                        } label: {
                            Label("Upload Reference", systemImage: "waveform")
                        }
                        .fileImporter(
                            isPresented: $showingReferenceAudioPicker,
                            allowedContentTypes: [UTType.wav],
                            allowsMultipleSelection: false
                        ) { result in
                            switch result {
                            case .success(let urls):
                                guard let url = urls.first else { return }
                                if url.startAccessingSecurityScopedResource() {
                                    if let localURL = viewModel.copyImportedFileToDocuments(from: url) {
                                        viewModel.transcribeAudioFile(url: localURL) { transcription in
                                            viewModel.referenceAudioText = transcription
                                            viewModel.validateAndConvertReferenceAudio(url: localURL) { result in
                                                DispatchQueue.main.async {
                                                    switch result {
                                                    case .success(let convertedURL):
                                                        viewModel.referenceAudioURL = convertedURL
                                                        print("Reference audio validated and converted: \(convertedURL.path)")
                                                    case .failure(let error):
                                                        print("Error processing reference audio: \(error.localizedDescription)")
                                                        // Optionally show an alert.
                                                    }
                                                }
                                            }
                                        }
                                    } else {
                                        alertMessage = "Could not copy reference audio file to app directory."
                                        showAlert = true
                                    }
                                    url.stopAccessingSecurityScopedResource()
                                } else {
                                    alertMessage = "Permission denied for file."
                                    showAlert = true
                                }
                            case .failure(let error):
                                alertMessage = "Error importing reference audio: \(error.localizedDescription)"
                                showAlert = true
                            }
                        }
                        
                        
                        
                        // Record Your Own Voice Button for reference audio
                        Button(action: {
                            if viewModel.isReferenceRecording {
                                // Stop the reference recording
                                viewModel.stopReferenceRecording { success, message in
                                    alertMessage = message
                                    showAlert = true
                                }
                            } else {
                                // Start the reference recording
                                viewModel.startReferenceRecording { success, message in
                                    if !success {
                                        alertMessage = message
                                        showAlert = true
                                    }
                                }
                            }
                        }) {
                            Label(
                                viewModel.isReferenceRecording ?
                                    "Stop Recording Your Own Voice" :
                                    "Record Your Own Voice",
                                systemImage: viewModel.isReferenceRecording ? "stop.circle" : "mic.circle"
                            )
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    
                    // "Generate Speech" button placed on its own row
                    Button {
                        viewModel.generateSpeech()
                    } label: {
                        HStack {
                            Image(systemName: "play.circle")
                            Text("Generate Speech")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(viewModel.inputText.isEmpty || viewModel.isGenerating)
                    .padding(.horizontal)
                    
                    // Show a progress view below the "Generate Speech" button while generating
                    if viewModel.isGenerating {
                        ProgressView(value: viewModel.generationProgress, total: 1.0) {
                            // You can either show a custom label or nothing.
                            Text("Generating Speech... \(Int(viewModel.generationProgress * 100))%")
                                .font(.headline)
                        }
                        .padding()
                        // Allow touches to pass through if you want users to still interact with other UI elements.
                        .allowsHitTesting(false)
                    }
                    
                    // Audio History List
                    List {
                        ForEach(viewModel.audioHistory) { item in
                            HStack {
                                Text(item.title)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                                Image(systemName: audioHistoryManager.currentlyPlayingId == item.id ?
                                      "stop.circle.fill" : "play.circle.fill")
                            }
                            .contentShape(Rectangle()) // Entire row tappable.
                            .onTapGesture {
                                // Tapping a row always plays/stops the audio, even if speech is being generated.
                                if audioHistoryManager.currentlyPlayingId == item.id {
                                    audioHistoryManager.stopCurrentAudio()
                                } else {
                                    audioHistoryManager.playAudio(fileName: item.audioFileName, itemId: item.id)
                                }
                            }
                            // Left-swipe deletion.
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    viewModel.deleteAudioHistory(item: item)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            // Context Menu with Preview.
                            .contextMenu {
                                // Quick action: Copy full text.
                                Button {
                                    UIPasteboard.general.string = item.title
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                // Quick action: Show full text.
                                Button {
                                    // Instead of directly setting a string,
                                    // assign the selected item so the sheet can show its content.
                                    DispatchQueue.main.async {
                                        selectedAudioHistoryItem = item
                                        isShowingFullTextSheet = true
                                    }
                                } label: {
                                    Label("Show", systemImage: "eye")
                                }
                                // Quick action: Delete.
                                Button(role: .destructive) {
                                    viewModel.deleteAudioHistory(item: item)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            } preview: {
                                // Force a fixed-size preview that shows the full text.
                                VStack(alignment: .leading) {
                                    ScrollView {
                                        Text(item.title)
                                            .font(.body)
                                            .multilineTextAlignment(.leading)
                                            .padding()
                                    }
                                }
                                .frame(width: 350, height: 300)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color(.systemBackground))
                                        .shadow(radius: 4)
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 600)

                }
            }
            .navigationTitle("F5 TTS App")
            .alert(isPresented: $showAlert) {
                Alert(
                    title: Text("Notice"),
                    message: Text(alertMessage),
                    dismissButton: .default(Text("OK"))
                )
            }
        } // NavigationView
        .onAppear {
            viewModel.initializeF5TTS()
            viewModel.requestPermissions()
        }
        .onDisappear {
            audioHistoryManager.stopCurrentAudio()
        }
        // Sheet for showing full text in a scrollable view.
        .sheet(isPresented: $isShowingFullTextSheet) {
            NavigationView {
                ScrollView {
                    Text(selectedAudioHistoryItem?.title ?? "")
                        .padding()
                        .font(.body)
                        .multilineTextAlignment(.leading)
                }
                .navigationTitle("Full Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            isShowingFullTextSheet = false
                            selectedAudioHistoryItem = nil
                        }
                    }
                }
            }
        }
    }
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
        // First, stop any current playback.
        stopCurrentAudio()
        
        // Before starting playback, reconfigure the audio session for playback.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("Failed to reconfigure audio session for playback: \(error)")
        }
        
        let fileURL = getDocumentsDirectory().appendingPathComponent(fileName)
        print("Attempting to play audio from: \(fileURL)")
        
        do {
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
            
            if player.prepareToPlay(), player.play() {
                print("Audio started playing")
                currentlyPlayingId = itemId
            } else {
                print("Failed to start audio playback")
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
