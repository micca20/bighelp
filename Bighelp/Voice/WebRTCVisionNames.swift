#if os(visionOS)
@preconcurrency import LiveKitWebRTC

// The WebRTC package the app uses has no visionOS build. LiveKit's build of
// the same library does, with an LK prefix on its Objective-C names, so the
// voice peer compiles unchanged against these names.
typealias RTCAudioSession = LKRTCAudioSession
typealias RTCAudioSessionDelegate = LKRTCAudioSessionDelegate
typealias RTCAudioTrack = LKRTCAudioTrack
typealias RTCConfiguration = LKRTCConfiguration
typealias RTCDataChannel = LKRTCDataChannel
typealias RTCIceCandidate = LKRTCIceCandidate
typealias RTCMediaConstraints = LKRTCMediaConstraints
typealias RTCMediaStream = LKRTCMediaStream
typealias RTCPeerConnection = LKRTCPeerConnection
typealias RTCPeerConnectionDelegate = LKRTCPeerConnectionDelegate
typealias RTCPeerConnectionFactory = LKRTCPeerConnectionFactory
typealias RTCRtpTransceiverInit = LKRTCRtpTransceiverInit
typealias RTCSessionDescription = LKRTCSessionDescription
typealias RTCIceConnectionState = LKRTCIceConnectionState
typealias RTCIceGatheringState = LKRTCIceGatheringState
typealias RTCPeerConnectionState = LKRTCPeerConnectionState
typealias RTCSignalingState = LKRTCSignalingState

@discardableResult
func RTCInitializeSSL() -> Bool { LKRTCInitializeSSL() }
#endif
