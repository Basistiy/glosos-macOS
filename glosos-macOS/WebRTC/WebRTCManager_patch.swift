import AVFoundation

// Testing AVAudioSinkNode syntax
let sink = AVAudioSinkNode { (timestamp, frames, audioBufferList) -> OSStatus in
    return noErr
}
