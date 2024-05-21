import SwiftUI
import AVFoundation
import UIKit

struct ContentView: View {
    @StateObject private var cameraViewModel = CameraViewModel()
    @State private var capturedImage: UIImage?
    @State private var dealerPrediction: String = ""
    @State private var playerPrediction: String = ""

    var body: some View {
        VStack {
            Spacer()

            CameraView(cameraViewModel: cameraViewModel)
                .aspectRatio(contentMode: .fill)
                .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height / 2)
                .clipped()

            if let image = capturedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: UIScreen.main.bounds.height / 4)
                    .cornerRadius(10)
            }

            VStack {
                Text("Dealer: \(extractCardsAndScore(from: dealerPrediction))")
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(10)

                Text("Player: \(extractCardsAndScore(from: playerPrediction))")
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(10)

                Button(action: {
                    cameraViewModel.startHand()
                    dealerPrediction = ""
                    playerPrediction = ""
                }) {
                    Text("Start Hand")
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.green)
                        .cornerRadius(10)
                }
            }
            .padding()

            Spacer()
        }
        .onAppear {
            cameraViewModel.setupCamera()
        }
        .onReceive(cameraViewModel.$dealerPrediction) { prediction in
            dealerPrediction = prediction
        }
        .onReceive(cameraViewModel.$playerPrediction) { prediction in
            playerPrediction = prediction
        }
    }

    private func extractCardsAndScore(from prediction: String) -> String {
        let components = prediction.components(separatedBy: ", ")
        let cards = components.filter { !$0.contains("Score") }
        let score = components.first(where: { $0.contains("Score") }) ?? ""
        return cards.joined(separator: ", ") + " " + score
    }
}

class CameraViewModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    @Published var detections: [Detection] = []
    @Published var capturedImage: UIImage?
    @Published var dealerPrediction: String = ""
    @Published var playerPrediction: String = ""

    public let captureSession = AVCaptureSession()
    private let apiKey = "YNCEcmErmSLoMCzXkiPp"
    private let modelId = "playing-cards-ow27d/4"
    private let photoOutput = AVCapturePhotoOutput()
    private var timer: Timer?
    private var dealerDetections: [[String]] = []
    private var playerDetections: [[String]] = []

    func setupCamera() {
        guard let captureDevice = AVCaptureDevice.default(for: .video) else { return }
        guard let input = try? AVCaptureDeviceInput(device: captureDevice) else { return }

        captureSession.addInput(input)

        photoOutput.setPreparedPhotoSettingsArray([AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])], completionHandler: nil)
        captureSession.addOutput(photoOutput)

        captureSession.startRunning()
    }

    func startHand() {
        dealerDetections.removeAll()
        playerDetections.removeAll()
        dealerPrediction = ""
        playerPrediction = ""

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            self.capturePhoto()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            self.timer?.invalidate()
            self.timer = nil
            self.determinePredictions()
        }
    }

    func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let imageData = photo.fileDataRepresentation() else { return }
        uploadImage(imageData: imageData)
    }

    private func preprocessImage(_ image: UIImage) -> UIImage {
        let resizedImage = resizeImage(image, targetSize: CGSize(width: 720, height: 720))
        return resizedImage
    }

    private func resizeImage(_ image: UIImage, targetSize: CGSize) -> UIImage {
        let size = image.size
        let widthRatio = targetSize.width / size.width
        let heightRatio = targetSize.height / size.height

        var newSize: CGSize
        if widthRatio > heightRatio {
            newSize = CGSize(width: size.width * heightRatio, height: size.height * heightRatio)
        } else {
            newSize = CGSize(width: size.width * widthRatio, height: size.height * widthRatio)
        }

        let rect = CGRect(origin: .zero, size: newSize)

        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: rect)
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return newImage!
    }

    private func uploadImage(imageData: Data) {
        guard let image = UIImage(data: imageData) else { return }
        let croppedImage = cropImageToSquare(image)
        let savedImage: () = saveImage(croppedImage, withName: "720pimage.jpeg");
        guard let croppedImageData = croppedImage.jpegData(compressionQuality: 0.99) else { return }

        let fileContent = croppedImageData.base64EncodedString()
        let postData = fileContent.data(using: .utf8)

        var request = URLRequest(url: URL(string: "https://detect.roboflow.com/\(modelId)?api_key=\(apiKey)&name=YOUR_IMAGE.jpg")!)
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "POST"
        request.httpBody = postData

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("Error: \(error)")
                return
            }

            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                print("Server responded with an error")
                return
            }

            guard let data = data else {
                print("No data received from the server")
                return
            }

            do {
                let response = try JSONDecoder().decode(Response.self, from: data)
                DispatchQueue.main.async {
                    self.detections = self.filterDetectionsByConfidence(response.predictions)

                    if let image = UIImage(data: imageData) {
                        self.capturedImage = image
                        self.processDetections(image)
                    }
                }
            } catch {
                print("Error decoding JSON: \(error)")
            }
        }.resume()
    }

    private func filterDetectionsByConfidence(_ detections: [Detection], threshold: Float = 0.40) -> [Detection] {
        return detections.filter { $0.confidence ?? 0 >= threshold }
    }

    private func combineDetections(_ detections: [String], imageSize: CGSize) -> [String] {
            var uniqueDetections: [String] = []

            for detection in detections {
                if !uniqueDetections.contains(detection) {
                    uniqueDetections.append(detection)
                }
            }

            return uniqueDetections
        }

    private func processDetections(_ image: UIImage) {
        let croppedImage = cropImageToSquare(image)
        let imageHeight = Float(croppedImage.size.height)
        let imageWidth = Float(croppedImage.size.width)

        guard let topHalfImage = cropImage(croppedImage, toRect: CGRect(x: 0, y: 0, width: CGFloat(imageWidth), height: CGFloat(imageHeight) / 2)),
              let bottomHalfImage = cropImage(croppedImage, toRect: CGRect(x: 0, y: CGFloat(imageHeight) / 2, width: CGFloat(imageWidth), height: CGFloat(imageHeight) / 2)) else {
            return
        }

        let normalizedDetections = detections.map { detection -> Detection in
            let normalizedY = detection.x.map { $0 / imageWidth }
            return Detection(className: detection.className, confidence: detection.confidence, x: detection.x, y: normalizedY, width: detection.width, height: detection.height)
        }

        let topHalfDetections = normalizedDetections.filter { $0.y ?? 1 < 0.5 }.compactMap { $0.className }
        let bottomHalfDetections = normalizedDetections.filter { $0.y ?? 0 >= 0.5 }.compactMap { $0.className }

        let combinedDealerDetections = combineDetections(topHalfDetections, imageSize: topHalfImage.size)
        let combinedPlayerDetections = combineDetections(bottomHalfDetections, imageSize: bottomHalfImage.size)

        dealerDetections.append(combinedDealerDetections)
        playerDetections.append(combinedPlayerDetections)
    }

    private func calculateScore(_ cardPredictions: [String]) -> Int {
        var score = 0
        var numAces = 0

        for prediction in cardPredictions {
            let first = prediction.prefix(1)
            let firstTwo = prediction.prefix(2)

            if let value = Int(first), value >= 2 && value <= 9 {
                score += value
            } else if firstTwo == "10" {
                score += 10
            } else if first == "A" {
                score += 11
                numAces += 1
            } else if first == "J" || first == "Q" || first == "K" {
                score += 10
            }
        }

        while score > 21 && numAces > 0 {
            score -= 10
            numAces -= 1
        }

        return score
    }

    private func cropImageToSquare(_ image: UIImage) -> UIImage {
        let imageWidth = image.size.width
        let imageHeight = image.size.height
        let squareSize = min(imageWidth, imageHeight)

        let x = (imageWidth - squareSize) / 2
        let y = (imageHeight - squareSize) / 2

        let cropRect = CGRect(x: x, y: y, width: squareSize, height: squareSize)
        guard let croppedImage = cropImage(image, toRect: cropRect) else { return image }

        return croppedImage
    }

    private func cropImage(_ image: UIImage, toRect rect: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        guard let croppedImage = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: croppedImage)
    }
    
    func saveImage(_ image: UIImage, withName name: String) {
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("Failed to get documents directory.")
            return
        }
        
        let fileURL = documentsDirectory.appendingPathComponent(name)
        guard let data = image.jpegData(compressionQuality: 1.0) else {
            print("Failed to convert image to JPEG.")
            return
        }
        
        do {
            try data.write(to: fileURL)
            print("Image saved successfully at: \(fileURL)")
        } catch {
            print("Failed to save image: \(error)")
        }
    }

    private func determinePredictions() {
        var dealerPredictions: [(card: String, confidence: Float)] = []
        var playerPredictions: [(card: String, confidence: Float)] = []

        let dealerCounts = dealerDetections.flatMap { $0 }.reduce(into: [String: Int]()) { counts, card in
            counts[card, default: 0] += 1
        }
        let playerCounts = playerDetections.flatMap { $0 }.reduce(into: [String: Int]()) { counts, card in
            counts[card, default: 0] += 1
        }

        for (card, count) in dealerCounts where count >= 4 {
            if let prediction = detections.first(where: { $0.className == card }),
               let confidence = prediction.confidence {
                dealerPredictions.append((card: card, confidence: confidence))
            }
        }

        for (card, count) in playerCounts where count >= 4 {
            if let prediction = detections.first(where: { $0.className == card }),
               let confidence = prediction.confidence {
                playerPredictions.append((card: card, confidence: confidence))
            }
        }

        let dealerScore = calculateScore(dealerPredictions.map { $0.card })
        let playerScore = calculateScore(playerPredictions.map { $0.card })

        let dealerPredictionString = dealerPredictions.map { "\($0.card), \($0.confidence)" }.joined(separator: ", ")
        let playerPredictionString = playerPredictions.map { "\($0.card), \($0.confidence)" }.joined(separator: ", ")

        dealerPrediction = dealerPredictionString + " (Score: \(dealerScore))"
        playerPrediction = playerPredictionString + " (Score: \(playerScore))"

        // Get the document directory URL
        guard let documentDirectoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("Failed to get document directory URL")
            return
        }

        // Create the "predictions" directory inside the document directory
        let predictionsDirectoryURL = documentDirectoryURL.appendingPathComponent("predictions", isDirectory: true)
        try? FileManager.default.createDirectory(at: predictionsDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        print(predictionsDirectoryURL)

        // Construct the CSV file URL
        let csvFileURL = predictionsDirectoryURL.appendingPathComponent("predictions.csv")

        let csvLine = "\"\(dealerPrediction)\",\"\(playerPrediction)\"\n"

        // Write to the CSV file
        if FileManager.default.fileExists(atPath: csvFileURL.path) {
            if let fileHandle = try? FileHandle(forWritingTo: csvFileURL) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(csvLine.data(using: .utf8)!)
                fileHandle.closeFile()
                print("Appended data to existing file")
            } else {
                print("Failed to open file for writing")
            }
        } else {
            do {
                try "Dealer,Player\n".write(to: csvFileURL, atomically: true, encoding: .utf8)
                print("Created new file with header")
            } catch {
                print("Failed to create new file: \(error)")
            }
            if let fileHandle = try? FileHandle(forWritingTo: csvFileURL) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(csvLine.data(using: .utf8)!)
                fileHandle.closeFile()
                print("Appended data to new file")
            } else {
                print("Failed to open new file for writing")
            }
        }
    }
}

struct Response: Codable {
    let time: Double
    let image: Image
    let predictions: [Detection]

    struct Image: Codable {
        let width, height: Int
    }
}

struct Detection: Codable, Identifiable {
    let id = UUID()
    let className: String?
    let confidence: Float?
    let x, y, width, height: Float?

    enum CodingKeys: String, CodingKey {
        case className = "class"
        case confidence
        case x, y, width, height
    }
}

struct CameraView: UIViewRepresentable {
    @ObservedObject var cameraViewModel: CameraViewModel

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: UIScreen.main.bounds)
        let previewLayer = AVCaptureVideoPreviewLayer(session: cameraViewModel.captureSession)
        previewLayer.frame = view.bounds
        previewLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
        view.layer.addSublayer(previewLayer)

        // Add a dotted line to show the split between player and dealer sections
        let lineLayer = CAShapeLayer()
        lineLayer.strokeColor = UIColor.white.cgColor
        lineLayer.lineWidth = 2
        lineLayer.lineDashPattern = [4, 4] // Adjust the dash pattern as needed

        let path = CGMutablePath()
        path.addLines(between: [
            CGPoint(x: 0, y: view.bounds.midY),
            CGPoint(x: view.bounds.width, y: view.bounds.midY)
        ])

        lineLayer.path = path
        lineLayer.position = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        view.layer.addSublayer(lineLayer)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
