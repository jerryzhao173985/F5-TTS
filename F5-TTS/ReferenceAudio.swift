import Foundation
import F5TTS
import MLX
import Vocos
import AVFoundation
import Speech
import SwiftUI
import UniformTypeIdentifiers

enum ReferenceAudioError: Error, LocalizedError {
    case tooShort
    case conversionError(String)
    case trimError(String)
    
    var errorDescription: String? {
        switch self {
        case .tooShort:
            return "Reference audio is too short. It must be at least 5 seconds long."
        case .conversionError(let msg):
            return "Conversion error: \(msg)"
        case .trimError(let msg):
            return "Trim error: \(msg)"
        }
    }
}

func getUniqueLocalReferenceURL() -> URL {
    let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return documentsDirectory.appendingPathComponent("refAudio_\(UUID().uuidString).wav")
}


extension F5TTSViewModel {
    
    /// Validates that the given reference audio file meets the requirements.
    /// If the audio is longer than 10 seconds, it is trimmed to 10 seconds.
    /// If its format is not mono/24kHz/16-bit, it is converted.
    func validateAndConvertReferenceAudio(url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        let asset = AVAsset(url: url)
        let duration = asset.duration.seconds
        
        // Reject if too short.
        if duration < 5 {
            completion(.failure(ReferenceAudioError.tooShort))
            return
        }
        
        // If longer than 10 seconds, trim it.
        if duration > 10 {
            let trimmedURL = getUniqueLocalReferenceURL()
            trimAudioFile(sourceURL: url, outputURL: trimmedURL, trimDuration: 10) { result in
                switch result {
                case .success(let trimmedURL):
                    self.convertIfNeeded(sourceURL: trimmedURL, completion: completion)
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        } else {
            // Otherwise, check for format conversion.
            self.convertIfNeeded(sourceURL: url, completion: completion)
        }
    }
    
    
    /// Checks whether the source audio is already in the desired format.
    /// If not, converts it.
    private func convertIfNeeded(sourceURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        do {
            let audioFile = try AVAudioFile(forReading: sourceURL)
            let format = audioFile.processingFormat
            // If already 24kHz and mono, assume it’s 16-bit.
            if format.sampleRate == 24000 && format.channelCount == 1 {
                completion(.success(sourceURL))
            } else {
                let convertedURL = getUniqueLocalReferenceURL()
                let desiredSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 24000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false
                ]
                guard let desiredFormat = AVAudioFormat(settings: desiredSettings) else {
                    completion(.failure(ReferenceAudioError.conversionError("Unable to create desired format")))
                    return
                }
                self.convertAudioFile(sourceURL: sourceURL, destinationURL: convertedURL, outputFormat: desiredFormat) { success, error in
                    if success {
                        completion(.success(convertedURL))
                    } else {
                        completion(.failure(error ?? ReferenceAudioError.conversionError("Unknown error")))
                    }
                }
            }
        } catch {
            completion(.failure(error))
        }
    }
    
    
    /// Converts the source audio file to the provided output format.
    private func convertAudioFile(sourceURL: URL,
                                  destinationURL: URL,
                                  outputFormat: AVAudioFormat,
                                  completion: @escaping (Bool, Error?) -> Void) {
        do {
            let inputFile = try AVAudioFile(forReading: sourceURL)
            let outputFile = try AVAudioFile(forWriting: destinationURL, settings: outputFormat.settings)
            guard let converter = AVAudioConverter(from: inputFile.processingFormat, to: outputFormat) else {
                completion(false, ReferenceAudioError.conversionError("Could not create audio converter"))
                return
            }
            let bufferCapacity: AVAudioFrameCount = 1024
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFile.processingFormat, frameCapacity: bufferCapacity) else {
                completion(false, ReferenceAudioError.conversionError("Could not create input buffer"))
                return
            }
            while true {
                try inputFile.read(into: inputBuffer)
                if inputBuffer.frameLength == 0 { break }
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: bufferCapacity) else {
                    completion(false, ReferenceAudioError.conversionError("Could not create output buffer"))
                    return
                }
                var error: NSError?
                let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                    if inputBuffer.frameLength == 0 {
                        outStatus.pointee = .noDataNow
                        return nil
                    } else {
                        outStatus.pointee = .haveData
                        return inputBuffer
                    }
                }
                let status: AVAudioConverterOutputStatus = converter.convert(to: outputBuffer,
                                                                               error: &error,
                                                                               withInputFrom: inputBlock)
                if status == .error || error != nil {
                    completion(false, error)
                    return
                }
                try outputFile.write(from: outputBuffer)
            }
            completion(true, nil)
        } catch {
            completion(false, error)
        }
    }

    
    func copyImportedFileToDocuments(from url: URL) -> URL? {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // You can use the same file name or generate a new unique name.
        let destinationURL = documentsURL.appendingPathComponent(url.lastPathComponent)
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: url, to: destinationURL)
            return destinationURL
        } catch {
            print("Error copying file: \(error)")
            return nil
        }
    }

    
    /// Trims the audio file to the specified duration (in seconds).
    private func trimAudioFile(sourceURL: URL, outputURL: URL, trimDuration: Double, completion: @escaping (Result<URL, Error>) -> Void) {
        let asset = AVAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            completion(.failure(ReferenceAudioError.trimError("Could not create export session")))
            return
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .wav
        let startTime = CMTime.zero
        let durationCM = CMTimeMakeWithSeconds(trimDuration, preferredTimescale: asset.duration.timescale)
        exportSession.timeRange = CMTimeRange(start: startTime, duration: durationCM)
        exportSession.exportAsynchronously {
            switch exportSession.status {
            case .completed:
                completion(.success(outputURL))
            case .failed, .cancelled:
                completion(.failure(exportSession.error ?? ReferenceAudioError.trimError("Export failed")))
            default:
                break
            }
        }
    }

}



