import Foundation
import F5TTS
import MLX
import Vocos
import AVFoundation
import Speech
import SwiftUI
import UniformTypeIdentifiers

// First, modify AudioHistoryItem to store relative paths instead of URLs
struct AudioHistoryItem: Identifiable, Codable {
    var id: UUID = UUID()
    var title: String
    var audioFileName: String  // Store filename instead of URL
    
    enum CodingKeys: String, CodingKey {
        case id, title, audioFileName
    }
}
    
class F5TTSViewModel: ObservableObject {
    @Published var inputText: String = ""
    @Published var isGenerating: Bool = false
    @Published var generatedAudioURL: URL?
    @Published var audioHistory: [AudioHistoryItem] = []
    
    // New properties for reference audio and recording state
    @Published var referenceAudioURL: URL?
    @Published var referenceAudioText: String?
    @Published var isReferenceRecording: Bool = false
    
    // New property to hold progress (0.0 to 1.0)
    @Published var generationProgress: Double = 0.0
    
    // Private properties for managing reference audio recording
    private var referenceAudioRecorder: AVAudioRecorder?
    private var referenceRecordingURL: URL?
    
    private var isTapInstalled = false
    private var outputPath: URL
    private var f5tts: F5TTS?
    private var audioEngine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    private var isRecordingInProgress = false
    
    private func getUniqueFileName() -> String {
        return "audio_\(UUID().uuidString).wav"
    }

    init() {
        // Create a unique file path for each audio generation
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        outputPath = documentsPath.appendingPathComponent("generatedAudio_\(UUID().uuidString).wav")
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        loadAudioHistory() // Load previous audios on startup
    }

    func requestPermissions() {
        // Request speech recognition authorization
        SFSpeechRecognizer.requestAuthorization { _ in }
        
        // Request microphone authorization
        AVAudioSession.sharedInstance().requestRecordPermission { _ in }
    }

    func initializeF5TTS() {
        Task {
            do {
                print("Loading F5-TTS model...")
                self.f5tts = try await F5TTS.fromPretrained(repoId: "lucasnewman/f5-tts-mlx") { progress in
                    print("Progress: \(progress.fractionCompleted * 100)%")
                }
            } catch {
                print("Failed to initialize F5TTS: \(error.localizedDescription)")
            }
        }
    }

    func handleFileImport(url: URL, completion: @escaping (Bool, String) -> Void) {
        // Request access to the iCloud file
        guard url.startAccessingSecurityScopedResource() else {
            completion(false, "Cannot access the file.")
            return
        }

        defer {
            url.stopAccessingSecurityScopedResource()  // Make sure to stop accessing the file after using it
        }

        do {
            let audioData = try Data(contentsOf: url)  // Read the file data
            DispatchQueue.main.async {
                self.inputText = String(data: audioData, encoding: .utf8) ?? ""
                completion(true, "File imported successfully")
            }
        } catch {
            completion(false, "Failed to read file: \(error.localizedDescription)")
        }
    }
    
    func startRecording(completion: @escaping (Bool, String) -> Void) {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            completion(false, "Speech recognition is not available")
            return
        }

        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    self.setupAudioSession { success in
                        if success {
                            self.startSpeechRecognition(completion: completion)
                        } else {
                            completion(false, "Failed to setup audio session")
                        }
                    }
                case .denied:
                    completion(false, "Speech recognition permission denied")
                case .restricted:
                    completion(false, "Speech recognition is restricted")
                case .notDetermined:
                    completion(false, "Speech recognition not determined")
                @unknown default:
                    completion(false, "Unknown authorization status")
                }
            }
        }
    }

    private func setupAudioSession(completion: @escaping (Bool) -> Void) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            completion(true)
        } catch {
            print("Failed to setup audio session: \(error)")
            completion(false)
        }
    }
    
    private func startSpeechRecognition(completion: @escaping (Bool, String) -> Void) {
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            completion(false, "Unable to create recognition request")
            return
        }

        recognitionRequest.shouldReportPartialResults = true

        do {
            let inputNode = audioEngine.inputNode
            
            // Remove existing tap if any
            if isTapInstalled {
                inputNode.removeTap(onBus: 0)
                isTapInstalled = false
            }

            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                self.recognitionRequest?.append(buffer)
            }
            isTapInstalled = true

            audioEngine.prepare()
            try audioEngine.start()

            recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self = self else { return }
                
                if let error = error {
                    print("Recognition error: \(error)")
                    completion(false, "Recognition error: \(error.localizedDescription)")
                    return
                }
                
                if let result = result {
                    DispatchQueue.main.async {
                        // Update inputText gradually with the latest transcription
                        let newTranscription = result.bestTranscription.formattedString
                        self.inputText = newTranscription
                    }
                }
            }

            completion(true, "Recording started successfully")
        } catch {
            completion(false, "Failed to start recording: \(error.localizedDescription)")
        }
    }
    
    func stopRecording() {
        audioEngine.stop()
        // Optionally clear or preserve the input text based on your desired flow.
        if !isRecordingInProgress {
            // inputText = "" // Uncomment if you want to reset text
        }
        isRecordingInProgress.toggle()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
    }
    
    // MARK: - Reference Audio Recording Methods

    /// Starts recording the user's voice for reference audio using AVAudioRecorder.
    func startReferenceRecording(completion: @escaping (Bool, String) -> Void) {
        // Set up and activate the audio session for recording.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            completion(false, "Could not set up audio session for reference recording: \(error.localizedDescription)")
            return
        }
        
        // Create a unique file URL in the documents directory.
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsPath.appendingPathComponent("referenceRecording_\(UUID().uuidString).wav")
        referenceRecordingURL = fileURL

        // Define the recording settings.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 24000,       // Use 24kHz instead of 44100
            AVNumberOfChannelsKey: 1,     // Mono
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        
        do {
            referenceAudioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            referenceAudioRecorder?.record()
            isReferenceRecording = true
            print("Started reference recording at \(fileURL.path)")
            completion(true, "Reference recording started successfully")
        } catch {
            completion(false, "Failed to start reference recording: \(error.localizedDescription)")
        }
    }

    /// Stops the reference audio recording and transcribes the recorded audio.
    func stopReferenceRecording(completion: @escaping (Bool, String) -> Void) {
        guard let recorder = referenceAudioRecorder, isReferenceRecording else {
            completion(false, "No reference recording in progress")
            return
        }
        recorder.stop()
        isReferenceRecording = false

        guard let fileURL = referenceRecordingURL else {
            completion(false, "Reference recording file URL not found")
            return
        }

        print("Stopped reference recording, file saved at \(fileURL.path)")

        // First, validate and convert the recorded audio.
        self.validateAndConvertReferenceAudio(url: fileURL) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let convertedURL):
                    // Update the reference audio URL to the converted file.
                    self.referenceAudioURL = convertedURL
                    // Now transcribe the converted audio.
                    self.transcribeAudioFile(url: convertedURL) { transcription in
                        DispatchQueue.main.async {
                            if transcription.isEmpty {
                                completion(false, "No speech detected in your recording. Please try again.")
                            } else {
                                self.referenceAudioText = transcription
                                completion(true, "Your own voice will be used to generate speech for the text you provided.")
                            }
                        }
                    }
                case .failure(let error):
                    completion(false, error.localizedDescription)
                }
            }
        }
    }
    
    
    // Modified generateSpeech to accept the reference audio parameters.
    func generateSpeech() {
        guard let f5tts = self.f5tts else {
            print("F5TTS not initialized.")
            return
        }
        
        // Reset progress and mark as generating.
        DispatchQueue.main.async {
            self.generationProgress = 0.0
            self.isGenerating = true
        }
        
        Task {
            do {
                let startTime = Date()
                let generatedAudio: MLXArray
                
                if let refURL = referenceAudioURL,
                   let refText = referenceAudioText,
                   !refText.isEmpty {
                    // Since our reference audio is now stored locally in Documents, use it directly.
                    generatedAudio = try await f5tts.generate(
                        text: self.inputText,
                        referenceAudioURL: refURL,
                        referenceAudioText: refText,
                        progressHandler: { progress in
                            DispatchQueue.main.async {
                                self.generationProgress = progress
                            }
                        }
                    )
                } else {
                    generatedAudio = try await f5tts.generate(text: self.inputText, progressHandler: { progress in
                        DispatchQueue.main.async {
                            self.generationProgress = progress
                        }
                    })
                }
                
                let elapsedTime = Date().timeIntervalSince(startTime)
                print("Generated \(Double(generatedAudio.shape[0]) / Double(F5TTS.sampleRate)) seconds of audio in \(elapsedTime) seconds.")
                
                try AudioUtilities.saveAudioFile(url: outputPath, samples: generatedAudio)
                print("Saved audio to: \(outputPath)")
                
                DispatchQueue.main.async {
                    self.saveAudioToHistory()
                    self.generatedAudioURL = self.outputPath
                    self.isGenerating = false
                }
            } catch {
                print("Error generating speech: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isGenerating = false
                }
            }
        }
    }


    // Save audio to history
    func saveAudioToHistory() {
        let fileName = getUniqueFileName()
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationURL = documentsPath.appendingPathComponent(fileName)
        
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: outputPath, to: destinationURL)
            
            let historyItem = AudioHistoryItem(title: inputText, audioFileName: fileName)
            audioHistory.append(historyItem)
            saveAudioHistory()
        } catch {
            print("Failed to save audio file: \(error)")
        }
    }
    
    // Update loading to verify files exist
    func loadAudioHistory() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let historyFileURL = documentsPath.appendingPathComponent("audioHistory.json")
        
        if let data = try? Data(contentsOf: historyFileURL),
           let savedHistory = try? JSONDecoder().decode([AudioHistoryItem].self, from: data) {
            
            audioHistory = savedHistory.filter { item in
                let audioURL = documentsPath.appendingPathComponent(item.audioFileName)
                return FileManager.default.fileExists(atPath: audioURL.path)
            }
        }
    }

    // Save audio history to disk
    func saveAudioHistory() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let historyFileURL = documentsPath.appendingPathComponent("audioHistory.json")

        if let data = try? JSONEncoder().encode(audioHistory) {
            try? data.write(to: historyFileURL)
        }
    }
    
    func deleteAudioHistory(item: AudioHistoryItem) {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsPath.appendingPathComponent(item.audioFileName)
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            print("Error deleting file: \(error)")
        }
        
        if let index = audioHistory.firstIndex(where: { $0.id == item.id }) {
            audioHistory.remove(at: index)
            saveAudioHistory()
        }
    }

    
    // Simplified transcription function
    func transcribeAudioFile(url: URL, completion: @escaping (String) -> Void) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            print("Speech recognizer not available")
            completion("")
            return
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        recognizer.recognitionTask(with: request) { result, error in
            if let error = error {
                print("Error transcribing audio: \(error.localizedDescription)")
                completion("")
                return
            }
            if let result = result, result.isFinal {
                let transcription = result.bestTranscription.formattedString
                completion(transcription)
            }
        }
    }
    
}

/// Preprocessing the Input Text
// In your view model (or wherever you set up the text input), add a helper to “clean” the text before saving or using it:
// Then use cleanedInputText when calling your speech generation function and when saving the history item.
extension F5TTSViewModel {
    var cleanedInputText: String {
        // Trim leading/trailing whitespace and newlines.
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Replace multiple newlines with a single newline.
        let regex = try? NSRegularExpression(pattern: "\n+", options: [])
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        let cleaned = regex?.stringByReplacingMatches(in: trimmed, options: [], range: range, withTemplate: "\n") ?? trimmed
        return cleaned
    }
}
