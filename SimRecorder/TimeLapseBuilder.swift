import AppKit
import AVFoundation

class MovieWriter: NSObject {
    typealias ConvertFinishedCallback = (_ data: Data?, _ succeed: Bool) -> ()
    
    func writeImagesAsMovie(imageURLs: [URL], videoPath: String, scale: CGFloat, videoFPS: Int32, compressionQuality: CGFloat, callback: ConvertFinishedCallback?) {
        guard let firstURL = imageURLs.first, let firstImage = NSImage(contentsOf: firstURL) else {
            callback?(nil, false)
            return
        }
        let videoSize = CGSize(width: firstImage.size.width * scale,
                               height: firstImage.size.height * scale)
        print("videoPath: \(videoPath), videoSize: \(videoSize), videoFPS: \(videoFPS), compressionQuality: \(compressionQuality)")
        // Create AVAssetWriter to write video
        guard let assetWriter = createAssetWriter(videoPath, size: videoSize, compressionQuality: compressionQuality) else {
            print("Error converting images to video: AVAssetWriter not created")
            return
        }
        
        // If here, AVAssetWriter exists so create AVAssetWriterInputPixelBufferAdaptor
        let writerInput = assetWriter.inputs.filter{ $0.mediaType == AVMediaTypeVideo }.first!
        let sourceBufferAttributes : [String : AnyObject] = [
            kCVPixelBufferPixelFormatTypeKey as String : Int(kCVPixelFormatType_32ARGB) as AnyObject,
            kCVPixelBufferWidthKey as String : videoSize.width as AnyObject,
            kCVPixelBufferHeightKey as String : videoSize.height as AnyObject,
            ]
        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: sourceBufferAttributes)
        
        // Start writing session
        assetWriter.startWriting()
        assetWriter.startSession(atSourceTime: kCMTimeZero)
        if (pixelBufferAdaptor.pixelBufferPool == nil) {
            print("Error converting images to video: pixelBufferPool nil after starting session")
            return
        }
        
        // -- Create queue for <requestMediaDataWhenReadyOnQueue>
        let mediaQueue = DispatchQueue(label: "mediaInputQueue", attributes: [])
        
        // -- Set video parameters
        let frameDuration = CMTimeMake(1, videoFPS)
        var frameCount = 0
        
        // -- Add images to video
        let numImages = imageURLs.count
        writerInput.requestMediaDataWhenReady(on: mediaQueue, using: { () -> Void in
            // Append unadded images to video but only while input ready
            while (writerInput.isReadyForMoreMediaData && frameCount < numImages) {
                let lastFrameTime = CMTimeMake(Int64(frameCount), videoFPS)
                let presentationTime = frameCount == 0 ? lastFrameTime : CMTimeAdd(lastFrameTime, frameDuration)
                
                guard let image = NSImage(contentsOf: imageURLs[frameCount]), self.appendPixelBufferForImageAtURL(image, scale: scale, pixelBufferAdaptor: pixelBufferAdaptor, presentationTime: presentationTime) else {
                    print("Error converting images to video: AVAssetWriterInputPixelBufferAdapter failed to append pixel buffer")
                    return
                }
                
                frameCount += 1
            }
            
            // No more images to add? End video.
            if (frameCount >= numImages) {
                writerInput.markAsFinished()
                assetWriter.finishWriting {
                    if (assetWriter.error != nil) {
                        print("Error converting images to video: \(assetWriter.error)")
                    } else {
                        print("Converted images to movie @ \(videoPath)")
                    }
                    callback?(nil, assetWriter.error == nil)
                }
            }
        })
    }
    
    
    func createAssetWriter(_ path: String, size: CGSize, compressionQuality: CGFloat) -> AVAssetWriter? {
        // Convert <path> to NSURL object
        let pathURL = URL(fileURLWithPath: path)
        
        // Return new asset writer or nil
        do {
            // Remove URL if its already existed
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
            
            // Create asset writer
            let newWriter = try AVAssetWriter(outputURL: pathURL, fileType: AVFileTypeMPEG4)
            
            // Define settings for video input
            let videoSettings: [String : AnyObject] = [
                AVVideoCodecKey  : AVVideoCodecH264 as AnyObject,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 2300000 as AnyObject,
                ] as AnyObject,
                AVVideoWidthKey  : size.width as AnyObject,
                AVVideoHeightKey : size.height as AnyObject,
                ]
            
            // Add video input to writer
            let assetWriterVideoInput = AVAssetWriterInput(mediaType: AVMediaTypeVideo, outputSettings: videoSettings)
            newWriter.add(assetWriterVideoInput)
            
            // Return writer
            print("Created asset writer for \(size.width)x\(size.height) video")
            return newWriter
        } catch {
            print("Error creating asset writer: \(error)")
            return nil
        }
    }
    
    
    func appendPixelBufferForImageAtURL(_ image: NSImage, scale: CGFloat, pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor, presentationTime: CMTime) -> Bool {
        var appendSucceeded = false
        
        autoreleasepool {
            if  let pixelBufferPool = pixelBufferAdaptor.pixelBufferPool {
                let pixelBufferPointer = UnsafeMutablePointer<CVPixelBuffer?>.allocate(capacity:1)
                let status: CVReturn = CVPixelBufferPoolCreatePixelBuffer(
                    kCFAllocatorDefault,
                    pixelBufferPool,
                    pixelBufferPointer
                )
                
                if let pixelBuffer = pixelBufferPointer.pointee , status == 0 {
                    fillPixelBufferFromImage(image,
                                             scale: scale,
                                             pixelBuffer: pixelBuffer)
                    appendSucceeded = pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime)
                    pixelBufferPointer.deinitialize()
                } else {
                    NSLog("Error: Failed to allocate pixel buffer from pool")
                }
                
                pixelBufferPointer.deallocate(capacity: 1)
            }
        }
        
        return appendSucceeded
    }
    
    
    func fillPixelBufferFromImage(_ image: NSImage, scale: CGFloat, pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))
        
        let pixelData = CVPixelBufferGetBaseAddress(pixelBuffer)
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let imageSize = CGSize(width: image.size.width * scale,
                               height: image.size.height * scale)
        
        // Create CGBitmapContext
        let context = CGContext(
            data: pixelData,
            width: Int(imageSize.width),
            height: Int(imageSize.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            )!
        
        // Draw image into context
        let drawCGRect = CGRect(x:0, y:0, width:imageSize.width, height:imageSize.height)
        var drawRect = NSRectFromCGRect(drawCGRect);
        let cgImage = image.cgImage(forProposedRect: &drawRect, context: nil, hints: nil)!
        context.draw(cgImage, in: CGRect(x: 0.0,y: 0.0,width: imageSize.width,height: imageSize.height))
        
        CVPixelBufferUnlockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))
    }
}
