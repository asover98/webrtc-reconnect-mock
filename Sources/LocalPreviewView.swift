import SwiftUI
import UIKit
import AVFoundation
import LiveKitWebRTC

/// Local camera preview using LiveKitWebRTC's `LKRTCCameraPreviewView`
/// (AVCaptureVideoPreviewLayer on the same session the capturer uses).
struct LocalPreviewView: UIViewRepresentable {
    var captureSession: AVCaptureSession?

    func makeUIView(context: Context) -> LKRTCCameraPreviewView {
        let view = LKRTCCameraPreviewView()
        view.backgroundColor = .black
        view.clipsToBounds = true
        view.captureSession = captureSession
        return view
    }

    func updateUIView(_ uiView: LKRTCCameraPreviewView, context: Context) {
        if uiView.captureSession !== captureSession {
            uiView.captureSession = captureSession
        }
    }
}
