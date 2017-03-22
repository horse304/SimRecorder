#!/usr/bin/env swift -framework OptionKit -F Carthage/Build/Mac
import Cocoa
import CoreGraphics
import OptionKit

extension NSImage {
    var CGImage: CGImage {
        get {
            let imageData = self.tiffRepresentation
            let source = CGImageSourceCreateWithData(imageData! as CFData, nil)
            let maskRef = CGImageSourceCreateImageAtIndex(source!, 0, nil)!
            return maskRef;
        }
    }
}

enum TargetSimulator: String {
    case iOS = "ios"
    case iOSWatch = "ios-watch"
    case Android64ARM = "android64-arm"
    case Android64X86 = "android64-x86"
    case Android64MIPS = "android64-mips"
    
    func hasBundleId() -> Bool {
        return self == .iOS || self == .iOSWatch
    }
    
    func toFilterValue() -> String {
        switch self {
        case .iOS: return "com.apple.iphonesimulator"
        case .iOSWatch: return "com.apple.watchsimulator"
        case .Android64ARM: return "emulator64-arm"
        case .Android64X86: return "emulator64-x86"
        case .Android64MIPS: return "emulator64-mips"
        }
    }
}

class Storage {
    fileprivate let DefaultTempDirName = "simrec/"
    fileprivate var url : URL?
    
    init() {
        self.url = createTemporaryDirectory()
    }
    
    func createTemporaryDirectory() -> URL? {
        let url : URL = URL(fileURLWithPath: NSTemporaryDirectory())
        let pathURL : URL = url.appendingPathComponent(DefaultTempDirName)
        let fileManager = FileManager.default
        print("temporary directory: \(pathURL)")
        do {
            if fileManager.fileExists(atPath: pathURL.standardizedFileURL.path) {
                print("path existed -> Remove")
                try fileManager.removeItem(at: pathURL)
            }
            try fileManager.createDirectory(at: pathURL, withIntermediateDirectories: true, attributes: nil)
            return pathURL
        } catch {
            print("Error when creating temporary folder \(error)")
            return nil
        }
    }
    
    func basePath() -> String? {
        return self.url?.absoluteString;
    }
    
    func imageURLs(count: UInt) -> [URL] {
        guard let url = url else { return [] }
        var urls = [URL]()
        for i in 0..<count {
            urls.append(URL(string: "\(i).png", relativeTo: url)!)
        }
        
        return urls
    }
    
    func writeToFile(_ image : CGImage, filename : String) -> Data {
        let bitmapRep : NSBitmapImageRep = NSBitmapImageRep(cgImage: image)
        let fileURL : URL = URL(string: filename, relativeTo: url)!
        let properties: Dictionary<String, AnyObject> = [
            NSImageCompressionFactor: 0.5 as AnyObject,
        ]
        let data : Data = bitmapRep.representation(using: NSBitmapImageFileType.JPEG, properties: properties)!
        if !((try? data.write(to: fileURL.standardizedFileURL, options: [])) != nil) {
            print("write to file failed")
        }
        return data
    }
}

class Converter {
    typealias ConvertFinishedCallback = (_ data: Data?, _ succeed: Bool) -> ()
    
    func createGIF(with images: [NSImage], quality: Float = 1.0, loopCount: UInt = 0, frameDelay: Double, destinationURL : URL, callback : ConvertFinishedCallback?) {
        let frameCount = images.count
        let animationProperties = 
        [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: loopCount], 
            kCGImageDestinationLossyCompressionQuality as String: quality] as [String : Any]
        let frameProperties = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: frameDelay, kCGImagePropertyGIFUnclampedDelayTime as String: frameDelay]]
        
        let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, kUTTypeGIF, frameCount, nil)
        if let destination = destination {
            CGImageDestinationSetProperties(destination, animationProperties as CFDictionary?)
            for i in 0 ..< frameCount {
                autoreleasepool {
                    let image = images[i];
                    CGImageDestinationAddImage(destination, image.CGImage, frameProperties as CFDictionary?)
                }
            }

            if CGImageDestinationFinalize(destination) {
                if let callback = callback {
                    callback(try? Data(contentsOf: destinationURL), true)
                }
            } else {
                if let callback = callback {
                    callback(nil, false)
                }
            }
        }
    }
}

class Recorder {
    fileprivate var windowID : CGWindowID?
    fileprivate var frame: UInt = 0
    fileprivate var timer: Timer!
    fileprivate let storage: Storage = Storage()
    fileprivate let converter: Converter = Converter()
    fileprivate let movieWriter = MovieWriter()
//    fileprivate var images: [NSImage] = []
    var quality: Float = 0.5
    var sizeScale: Float = 0.5
    var fps: UInt = 10
    var outputPath: String = "animation.mov"
    var loopCount: UInt = 0
    var targetSimulator: TargetSimulator
    
    convenience init() {
        self.init(targetSimulator: .iOS)
    }
    
    init(targetSimulator: TargetSimulator) {
        self.targetSimulator = targetSimulator
        self.windowID = self.simulatorWindowID()
    }

    fileprivate func simulatorWindowID() -> CGWindowID? {
        var windowIDs : [CGWindowID] = []
        
        let simulators : [NSRunningApplication]
        if targetSimulator.hasBundleId() {
            simulators = NSWorkspace.shared().runningApplications.filter({
                (app : NSRunningApplication) in
                return app.bundleIdentifier == targetSimulator.toFilterValue()
            })
        } else {
            simulators = NSWorkspace.shared().runningApplications.filter({
                (app : NSRunningApplication) in
                return app.localizedName == targetSimulator.toFilterValue()
            })
        }
        
        if (simulators.count > 0) {
            let simulator : NSRunningApplication = simulators.first!
            
            let windowArray : CFArray = CGWindowListCopyWindowInfo(CGWindowListOption.optionOnScreenOnly, 0)!
            let windows : NSArray = windowArray as NSArray
            for window in windows {
                let dict = window as! Dictionary<String, AnyObject>
                let windowIDNumber: NSNumber = dict["kCGWindowNumber"] as! NSNumber
                let ownerPID: NSNumber = dict["kCGWindowOwnerPID"] as! NSNumber
                if ownerPID.int32Value == Int32(simulator.processIdentifier) {
                    windowIDs.append(CGWindowID(windowIDNumber.int32Value))
                }
            }
        }
        if windowIDs.count > 0 {
            return windowIDs.last;
        }
        return nil
    }
    
    func secPerFrame() -> Double {
        return 1.0 / Double(self.fps)
    }
    
    func outputURL() -> URL {
        return URL(string: self.outputPath)!
    }
    
    func isAttachSimulator() -> Bool {
        return self.windowID != nil
    }

    @objc fileprivate func takeScreenshot() {
        let imageRef : CGImage = CGWindowListCreateImage(CGRect.null, CGWindowListOption.optionIncludingWindow, windowID!, CGWindowImageOption.boundsIgnoreFraming)!
        let newRef = removeAlpha(imageRef)
        _ = self.storage.writeToFile(newRef, filename: "\(self.frame).png")
        self.frame += 1
//        let image = NSImage(data: data)
//        if let image = image {
//            self.images.append(image)
//        }
    }
    
    fileprivate func removeAlpha(_ imageRef: CGImage) -> CGImage {
        let width = imageRef.width
        let height = imageRef.height
        let bitmapContext: CGContext? = CGContext(data: nil,
            width: width,
            height: height,
            bitsPerComponent: imageRef.bitsPerComponent, 
            bytesPerRow: imageRef.bytesPerRow, 
            space: imageRef.colorSpace!, 
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let rect: CGRect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        if let bitmapContext = bitmapContext {
            bitmapContext.draw(imageRef, in: rect);
            return bitmapContext.makeImage()!
        }
        return imageRef
    }
    
    func startCapture() {
        self.timer = Timer.scheduledTimer(timeInterval: self.secPerFrame(), target: self, selector: #selector(Recorder.takeScreenshot), userInfo: nil, repeats: true)
    }
    
    func endCapture(_ callback : Converter.ConvertFinishedCallback?) {
        self.timer?.invalidate()
        let destinationURL : URL = URL(fileURLWithPath: self.outputPath)
        self.movieWriter.writeImagesAsMovie(
            imageURLs: self.storage.imageURLs(count: frame),
            videoPath: destinationURL.standardizedFileURL.path,
            scale: CGFloat(sizeScale),
            videoFPS: Int32(fps),
            compressionQuality: CGFloat(quality),
            callback: callback)
//        self.converter.createGIF(with: self.images, quality: self.quality, loopCount: self.loopCount, frameDelay: self.secPerFrame(), destinationURL: destinationURL, callback: callback)
    }
}

class Command {
    typealias SignalCallback = @convention(c) (Int32) -> Void

    static func execute(_ arguments : [String]) {
        let frameRateOption = Option(trigger: OptionTrigger.mixed("f", "fps"), numberOfParameters: 1, helpDescription: "Recording frames per second")
        let outputPathOption = Option(trigger: OptionTrigger.mixed("o", "outputPath"), numberOfParameters: 1, helpDescription: "Animation output path")
        let qualityOption = Option(trigger: OptionTrigger.mixed("q", "quality"), numberOfParameters: 1, helpDescription: "Quality of animations 0.0 ~ 1.0")
        let loopCountOption = Option(trigger: OptionTrigger.mixed("l", "loopCount"), numberOfParameters: 1, helpDescription: "Loop count of animations. if you passed 0, it animate eternally")
        let targetSimulatorOption = Option(trigger: OptionTrigger.mixed("t", "targetSimulator"), numberOfParameters: 1, helpDescription: "Target simulator [\(TargetSimulator.iOS.rawValue)|\(TargetSimulator.Android64ARM.rawValue)|\(TargetSimulator.Android64X86.rawValue)|\(TargetSimulator.Android64MIPS.rawValue)]")
        
        let parser = OptionParser(definitions: [frameRateOption, outputPathOption, qualityOption, loopCountOption, targetSimulatorOption])
        
        do {
            let (options, _) = try parser.parse(arguments)
            
            let recorder : Recorder
            
            if let targetSimulator = options[targetSimulatorOption]?.first {
                if let targetSimulatorEnum = TargetSimulator.init(rawValue: targetSimulator) {
                    recorder = Recorder(targetSimulator: targetSimulatorEnum)
                } else {
                    recorder = Recorder()
                }
            } else {
                recorder = Recorder()
            }
            
            guard recorder.isAttachSimulator() else {
                print("iOS simulator seems not to launch")
                exit(EXIT_FAILURE)
            }
            
            if let frameRate: UInt = options[frameRateOption]?.flatMap({ UInt($0) }).first {
                recorder.fps = frameRate
            }
            
            if let outputPath = options[outputPathOption]?.first {
                recorder.outputPath = outputPath
            }
            
            if let quality: Float = options[qualityOption]?.flatMap({ Float($0) }).first {
                recorder.quality = quality
            }
            
            if let loopCount: UInt = options[loopCountOption]?.flatMap({ UInt($0) }).first {
                recorder.loopCount = loopCount
            }
            
            let callback : @convention(block) (Int32) -> Void = { (Int32) -> Void in
                recorder.endCapture({ (data : Data?, succeed : Bool) in
                    if succeed {
                        print("Gif animation generated")
                        exit(EXIT_SUCCESS)
                    } else {
                        print("Gif animation generation is failed")
                        exit(EXIT_FAILURE)
                    }
                })
            }
            
            // Convert Objective-C block to C function pointer
            let imp = imp_implementationWithBlock(unsafeBitCast(callback, to: AnyObject.self))
            signal(SIGINT, unsafeBitCast(imp, to: SignalCallback.self))
            recorder.startCapture()
            autoreleasepool {
                RunLoop.current.run()
            }
        } catch {
        }
    }
}

let actualArguments = Array(CommandLine.arguments[1..<CommandLine.arguments.count])

Command.execute(actualArguments)

