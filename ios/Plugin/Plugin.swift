import Capacitor
import Foundation
import AVFoundation

@objc(BarcodeScanner)
public class BarcodeScanner: CAPPlugin, AVCaptureMetadataOutputObjectsDelegate, AVCapturePhotoCaptureDelegate {

    class CameraView: UIView {
        var videoPreviewLayer:AVCaptureVideoPreviewLayer?

        func interfaceOrientationToVideoOrientation(_ orientation : UIInterfaceOrientation) -> AVCaptureVideoOrientation {
            switch (orientation) {
            case UIInterfaceOrientation.portrait:
                return AVCaptureVideoOrientation.portrait;
            case UIInterfaceOrientation.portraitUpsideDown:
                return AVCaptureVideoOrientation.portraitUpsideDown;
            case UIInterfaceOrientation.landscapeLeft:
                return AVCaptureVideoOrientation.landscapeLeft;
            case UIInterfaceOrientation.landscapeRight:
                return AVCaptureVideoOrientation.landscapeRight;
            default:
                return AVCaptureVideoOrientation.portraitUpsideDown;
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews();
            if let sublayers = self.layer.sublayers {
                for layer in sublayers {
                    layer.frame = self.bounds;
                }
            }

            self.videoPreviewLayer?.connection?.videoOrientation = interfaceOrientationToVideoOrientation(UIApplication.shared.statusBarOrientation);
        }


        func addPreviewLayer(_ previewLayer:AVCaptureVideoPreviewLayer?) {
            previewLayer!.videoGravity = AVLayerVideoGravity.resizeAspectFill
            previewLayer!.frame = self.bounds
            self.layer.addSublayer(previewLayer!)
            self.videoPreviewLayer = previewLayer;
        }

        func removePreviewLayer() {
            if self.videoPreviewLayer != nil {
                self.videoPreviewLayer!.removeFromSuperlayer()
                self.videoPreviewLayer = nil
            }
        }
    }

    var cameraView: CameraView!
    var captureSession:AVCaptureSession?
    var captureVideoPreviewLayer:AVCaptureVideoPreviewLayer?
    var metaOutput: AVCaptureMetadataOutput?

    var currentCamera: Int = 0;
    var frontCamera: AVCaptureDevice?
    var backCamera: AVCaptureDevice?
    var output: AVCapturePhotoOutput?
    var timer:Timer?
    
    var isScanning: Bool = false
    var shouldRunScan: Bool = false
    var didRunCameraSetup: Bool = false
    var didRunCameraPrepare: Bool = false
    var isBackgroundHidden: Bool = false

    var savedCall: CAPPluginCall? = nil

    enum SupportedFormat: String, CaseIterable {
        // 1D Product
        //!\ UPC_A is part of EAN_13 according to Apple docs
        case UPC_E
        //!\ UPC_EAN_EXTENSION is not supported by AVFoundation
        case EAN_8
        case EAN_13
        // 1D Industrial
        case CODE_39
        case CODE_39_MOD_43
        case CODE_93
        case CODE_128
        //!\ CODABAR is not supported by AVFoundation
        case ITF
        case ITF_14
        // 2D
        case AZTEC
        case DATA_MATRIX
        //!\ MAXICODE is not supported by AVFoundation
        case PDF_417
        case QR_CODE
        //!\ RSS_14 is not supported by AVFoundation
        //!\ RSS_EXPANDED is not supported by AVFoundation

        var value: AVMetadataObject.ObjectType {
            switch self {
                // 1D Product
                case .UPC_E: return AVMetadataObject.ObjectType.upce
                case .EAN_8: return AVMetadataObject.ObjectType.ean8
                case .EAN_13: return AVMetadataObject.ObjectType.ean13
                // 1D Industrial
                case .CODE_39: return AVMetadataObject.ObjectType.code39
                case .CODE_39_MOD_43: return AVMetadataObject.ObjectType.code39Mod43
                case .CODE_93: return AVMetadataObject.ObjectType.code93
                case .CODE_128: return AVMetadataObject.ObjectType.code128
                case .ITF: return AVMetadataObject.ObjectType.interleaved2of5
                case .ITF_14: return AVMetadataObject.ObjectType.itf14
                // 2D
                case .AZTEC: return AVMetadataObject.ObjectType.aztec
                case .DATA_MATRIX: return AVMetadataObject.ObjectType.dataMatrix
                case .PDF_417: return AVMetadataObject.ObjectType.pdf417
                case .QR_CODE: return AVMetadataObject.ObjectType.qr
            }
        }
    }

    var targetedFormats = [AVMetadataObject.ObjectType]()

    enum CaptureError: Error {
        case backCameraUnavailable
        case frontCameraUnavailable
        case couldNotCaptureInput(error: NSError)
    }

    public override func load() {
        self.cameraView = CameraView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height))
        self.cameraView.autoresizingMask = [.flexibleWidth, .flexibleHeight];
    }

    private func hasCameraPermission() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: AVMediaType.video)
        if (status == AVAuthorizationStatus.authorized) {
            return true
        }
        return false;
    }

    private func setupCamera() -> Bool {
        do {
            cameraView.backgroundColor = UIColor.clear
            self.webView!.superview!.insertSubview(cameraView, belowSubview: self.webView!)
            let availableVideoDevices =  AVCaptureDevice.devices(for: AVMediaType.video)
            for device in availableVideoDevices {
                if device.position == AVCaptureDevice.Position.back {
                    backCamera = device
                }
                else if device.position == AVCaptureDevice.Position.front {
                    frontCamera = device
                }
            }
            // older iPods have no back camera
            if(backCamera == nil){
                currentCamera = 1
            }
            let input: AVCaptureDeviceInput
            input = try self.createCaptureDeviceInput()
            captureSession = AVCaptureSession()
            captureSession!.addInput(input)
            metaOutput = AVCaptureMetadataOutput()
            captureSession!.addOutput(metaOutput!)
            metaOutput!.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            captureVideoPreviewLayer = AVCaptureVideoPreviewLayer(session: captureSession!)
            cameraView.addPreviewLayer(captureVideoPreviewLayer)
            self.output = AVCapturePhotoOutput()
            captureSession!.addOutput(self.output!)
            self.didRunCameraSetup = true
            return true
        } catch CaptureError.backCameraUnavailable {
            //
        } catch CaptureError.frontCameraUnavailable {
            //
        } catch CaptureError.couldNotCaptureInput {
            //
        } catch {
            //
        }
        return false
    }
    
    private func createCaptureDeviceInput() throws -> AVCaptureDeviceInput {
        var captureDevice: AVCaptureDevice
        if(currentCamera == 0){
            if(backCamera != nil){
                captureDevice = backCamera!
            } else {
                throw CaptureError.backCameraUnavailable
            }
        } else {
            if(frontCamera != nil){
                captureDevice = frontCamera!
            } else {
                throw CaptureError.frontCameraUnavailable
            }
        }
        let captureDeviceInput: AVCaptureDeviceInput
        do {
            captureDeviceInput = try AVCaptureDeviceInput(device: captureDevice)
        } catch let error as NSError {
            throw CaptureError.couldNotCaptureInput(error: error)
        }
        return captureDeviceInput
    }

    private func dismantleCamera() {
        // opposite of setupCamera

        if (self.captureSession != nil) {
            DispatchQueue.main.async {
                self.captureSession!.stopRunning()
                self.cameraView.removePreviewLayer()
                self.captureVideoPreviewLayer = nil
                self.metaOutput = nil
                self.captureSession = nil
                self.currentCamera = 0
                self.frontCamera = nil
                self.backCamera = nil
            }
        }

        self.isScanning = false
        self.didRunCameraSetup = false
        self.didRunCameraPrepare = false

        // If a call is saved and a scan will not run, free the saved call
        if (self.savedCall != nil && !self.shouldRunScan) {
            self.savedCall = nil
        }
    }

    private func prepare() {
        // undo previous setup
        // because it may be prepared with a different config
        self.dismantleCamera()

        DispatchQueue.main.async {
            // setup camera with new config
            if (self.setupCamera()) {
                // indicate this method was run
                self.didRunCameraPrepare = true

                if (self.shouldRunScan) {
                    self.scan()
                }
            } else {
                self.shouldRunScan = false
            }
        }
    }

    private func destroy() {
        self.showBackground()

        self.dismantleCamera()
    }

    private func scan() {
        if (!self.didRunCameraPrepare) {
            if (!self.hasCameraPermission()) {
                // @TODO()
                // requestPermission()
            } else {
                self.shouldRunScan = true
                self.prepare()
            }
        } else {
            self.didRunCameraPrepare = false

            self.shouldRunScan = false

            targetedFormats = [AVMetadataObject.ObjectType]();

            if ((savedCall?.hasOption("targetedFormats")) != nil) {
                let _targetedFormats = savedCall?.getArray("targetedFormats", String.self, [String]());

                if (_targetedFormats != nil && _targetedFormats?.count ?? 0 > 0) {
                    _targetedFormats?.forEach { targetedFormat in
                        if let value = SupportedFormat(rawValue: targetedFormat)?.value {
                            print(value)
                            targetedFormats.append(value)
                        }
                    }
                }

                if (targetedFormats.count == 0) {
                    print("The property targetedFormats was not set correctly.")
                }
            }

            if (targetedFormats.count == 0) {
                for supportedFormat in SupportedFormat.allCases {
                    targetedFormats.append(supportedFormat.value)
                }
            }

            DispatchQueue.main.async {
                self.metaOutput!.metadataObjectTypes = self.targetedFormats
                self.captureSession!.startRunning()
            }
            if ((savedCall?.hasOption("isCode")) != nil) {
                self.timer = Timer.scheduledTimer(timeInterval: 1.5, target: self, selector: #selector(capturePhoto), userInfo: nil, repeats: true)
            }
            self.hideBackground()
            self.isScanning = true
        }
    }

    private func hideBackground() {
        DispatchQueue.main.async {
            self.bridge.getWebView()!.isOpaque = false
            self.bridge.getWebView()!.backgroundColor = UIColor.clear
            self.bridge.getWebView()!.scrollView.backgroundColor = UIColor.clear

            let javascript = "document.documentElement.style.backgroundColor = 'transparent'"

            self.bridge.getWebView()!.evaluateJavaScript(javascript)
        }
    }

    private func showBackground() {
        DispatchQueue.main.async {
            let javascript = "document.documentElement.style.backgroundColor = ''"

            self.bridge.getWebView()!.evaluateJavaScript(javascript) { (result, error) in
                self.bridge.getWebView()!.isOpaque = true
                self.bridge.getWebView()!.backgroundColor = UIColor.white
                self.bridge.getWebView()!.scrollView.backgroundColor = UIColor.white
            }
        }
    }
    
    @objc public func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        let previewPixelType = settings.availablePreviewPhotoPixelFormatTypes.first!
        let previewFormat = [kCVPixelBufferPixelFormatTypeKey as String: previewPixelType,
                           kCVPixelBufferWidthKey as String: 160,
                           kCVPixelBufferHeightKey as String: 160]
        settings.previewPhotoFormat = previewFormat
        
        self.output?.capturePhoto(with: settings, delegate: self)
    }
    
    private func cropImage(image : UIImage) -> UIImage?{
        print(image.size.width)
        print(image.size.height)
        
        let w = image.size.width / 2
        let x = w - (w/2)
        let h = w*70/250;
        let y = (image.size.height / 2) - (h/2)
        print(x, y, w, h)

        let cropRect = CGRect(x: y, y: x, width: h, height: w)
        guard let imageRef = image.cgImage!.cropping(to: cropRect)
        else {
            return nil
        }
        let croppedImage: UIImage = UIImage(cgImage: imageRef)
        return croppedImage
    }


    public func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
      AudioServicesDisposeSystemSoundID(1108)
    }

    public func photoOutput(_ output: AVCapturePhotoOutput, didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
      AudioServicesDisposeSystemSoundID(1108)
    }
    
    public func photoOutput(_ captureOutput: AVCapturePhotoOutput, didFinishProcessingPhoto photoSampleBuffer: CMSampleBuffer?, previewPhoto previewPhotoSampleBuffer: CMSampleBuffer?, resolvedSettings: AVCaptureResolvedPhotoSettings, bracketSettings: AVCaptureBracketedStillImageSettings?, error: Error?) {

        if let error = error {
            print("error occure : \(error.localizedDescription)")
        }

        if  let sampleBuffer = photoSampleBuffer,
            let previewBuffer = previewPhotoSampleBuffer,
            let dataImage =  AVCapturePhotoOutput.jpegPhotoDataRepresentation(forJPEGSampleBuffer:  sampleBuffer, previewPhotoSampleBuffer: previewBuffer) {
                let cropped = self.cropImage(image: UIImage(data: dataImage)!)
                let imageData:Data = cropped!.pngData()!
                let strBase64 = imageData.base64EncodedString(options: .lineLength64Characters)
                self.notifyListeners("onCodeEvent", data: ["img":strBase64])
        } else {
            print("some error here")
        }
    }

    
    // This method processes metadataObjects captured by iOS.
    public func metadataOutput(_ captureOutput: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {

        if (metadataObjects.count == 0 || !self.isScanning) {
            // while nothing is detected, or if scanning is false, do nothing.
            return
        }

        let found = metadataObjects[0] as! AVMetadataMachineReadableCodeObject
        if (targetedFormats.contains(found.type)) {
            var jsObject = PluginResultData()

            if (found.stringValue != nil) {
                jsObject["hasContent"] = true
                jsObject["content"] = found.stringValue
            } else {
                jsObject["hasContent"] = false
            }

            if (self.savedCall != nil) {
                savedCall?.resolve(jsObject)
                savedCall = nil
            }

            self.destroy()
        }
    }

    @objc func prepare(_ call: CAPPluginCall) {
        self.prepare()
        call.resolve()
    }

    @objc func hideBackground(_ call: CAPPluginCall) {
        self.hideBackground()
        call.resolve()
    }

    @objc func showBackground(_ call: CAPPluginCall) {
        self.showBackground()
        call.resolve()
    }

    @objc func startScan(_ call: CAPPluginCall) {
        self.savedCall = call
        self.scan()
    }

    @objc func stopScan(_ call: CAPPluginCall) {
        self.timer?.invalidate()
        self.destroy()
        call.resolve()
    }

    @objc func checkPermission(_ call: CAPPluginCall) {
        let force = call.getBool("force") ?? false

        var savedReturnObject = PluginResultData()

        DispatchQueue.main.async {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized:
                    savedReturnObject["granted"] = true
                case .denied:
                    savedReturnObject["denied"] = true
                case .notDetermined:
                    savedReturnObject["neverAsked"] = true
                case .restricted:
                    savedReturnObject["restricted"] = true
                @unknown default:
                    savedReturnObject["unknown"] = true
            }

            if (force && savedReturnObject["neverAsked"] != nil) {
                savedReturnObject["asked"] = true

                AVCaptureDevice.requestAccess(for: .video) { (authorized) in
                    if (authorized) {
                        savedReturnObject["granted"] = true
                    } else {
                        savedReturnObject["denied"] = true
                    }
                    call.resolve(savedReturnObject)
                }
            } else {
                call.resolve(savedReturnObject)
            }
        }
    }

    @objc func openAppSettings(_ call: CAPPluginCall) {
      guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
          return
      }

      DispatchQueue.main.async {
          if UIApplication.shared.canOpenURL(settingsUrl) {
              UIApplication.shared.open(settingsUrl, completionHandler: { (success) in
                  call.resolve()
              })
          }
      }
    }

}
