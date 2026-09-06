import SwiftUI
import GuitarAudio

struct AudioSettingsView: View {
    @ObservedObject var audio: AudioService
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            Label("声音设置",systemImage:"waveform").font(.title2.bold())
            Form {
                Section("采集来源") {
                    Picker("来源",selection:$audio.source) {
                        ForEach(CaptureSource.allCases) { Text($0.title).tag($0) }
                    }
                    if audio.source == .input {
                        Picker("输入设备",selection:$audio.inputDeviceID) {
                            Text("跟随系统输入").tag(UInt32(0))
                            ForEach(audio.inputDevices) { Text($0.name).tag($0.id) }
                        }
                        Picker("输入通道",selection:$audio.inputChannel) {
                            ForEach(0..<channelCount,id:\.self) { Text("通道 \($0+1)").tag($0) }
                        }
                    }
                    if audio.source == .system {
                        Picker("系统声音",selection:$audio.selectedProcessID) {
                            Text("整机混音（排除 Guitarget）").tag(nil as Int32?)
                            ForEach(audio.processes) { Text($0.name).tag(Optional($0.id)) }
                        }
                        Text("只列出已创建音频进程的 App。启动目标 App 并播放后，可刷新列表。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("声音输出") {
                    Picker("输出设备",selection:Binding(get:{audio.outputDeviceID},set:{audio.setOutputDevice($0)})) {
                        Text("跟随系统输出").tag(UInt32(0))
                        ForEach(audio.outputDevices) { Text($0.name).tag($0.id) }
                    }
                    Text("输出设备独立选择。点击指板和试听无需录音权限。").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            HStack {
                Button("刷新设备与 App") { audio.refreshDevices() }
                Spacer()
                if audio.isStartingCapture { Button("取消启动"){audio.stopCapture()} }
                else if audio.isCapturing { Button("停止采集"){audio.stopCapture()} }
                else { Button("开始采集"){audio.startCapture()}.buttonStyle(.borderedProminent).disabled(audio.source == .off) }
            }
            Label(audio.status,systemImage:audio.isCapturing ? "waveform.circle.fill":"info.circle").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Text("首次启用时，macOS 会申请相应录音权限。拒绝授权仍可编辑与试听。使用麦克风跟练或伴奏时建议佩戴耳机，避免扬声器串音。").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { audio.refreshDevices() }
    }
    private var channelCount:Int {
        audio.selectedInputChannelCount
    }
}

struct AudioStatusBar: View {
    @ObservedObject var audio: AudioService
    @State private var showSettings = false
    var body: some View {
        HStack(spacing:14) {
            Button { showSettings.toggle() } label: {
                Label(audio.isCapturing ? audio.source.title : "声音来源",systemImage:audio.isCapturing ? "waveform":"slider.horizontal.3")
            }.buttonStyle(.plain).popover(isPresented:$showSettings) { AudioSettingsView(audio:audio).padding(22).frame(width:520) }
            Circle().fill(audio.isCapturing ? .green : .secondary.opacity(0.4)).frame(width:6,height:6)
            Text(audio.status).lineLimit(1).foregroundStyle(.secondary)
            Spacer(minLength:12)
            if audio.isPlaying || audio.isPaused {
                Text(audio.isPaused ? "已暂停" : "播放中").foregroundStyle(.secondary)
                Button { audio.stop() } label:{ Image(systemName:"stop.fill") }.buttonStyle(.borderless).help("停止全部播放")
            }
            if let frame = audio.pitchFrame {
                Text("\(frame.noteName)\(frame.octave)").font(.system(size:15,weight:.bold,design:.rounded))
                Text(String(format:"%.1f Hz  %+.0f ¢",frame.frequency,frame.cents)).monospacedDigit().foregroundStyle(abs(frame.cents)<10 ? .green:.secondary)
            } else { Text("— Hz").monospacedDigit().foregroundStyle(.secondary) }
            ProgressView(value:min(1,audio.inputLevel*5)).frame(width:65).tint(.green).help("实时输入电平")
        }.font(.system(size:11)).padding(.horizontal,18).frame(height:40).background(.bar)
    }
}

struct TunerView: View {
    @ObservedObject var audio: AudioService
    var body: some View {
        LearningCard(title:"调音与自由演奏",icon:"tuningfork") {
            HStack(alignment:.firstTextBaseline,spacing:12) {
                Text(audio.pitchFrame.map{"\($0.noteName)\($0.octave)"} ?? "—").font(.system(size:52,weight:.medium,design:.rounded))
                    .foregroundStyle(inTune ? Color.green:Color.primary)
                VStack(alignment:.leading,spacing:5) {
                    Text(audio.pitchFrame.map{String(format:"%.2f Hz",$0.frequency)} ?? "等待单音输入").monospacedDigit()
                    Text(audio.pitchFrame.map{String(format:"%+.1f 音分 · 置信度 %.0f%%",$0.cents,$0.confidence*100)} ?? "A4 = 440 Hz").font(.caption).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geometry in
                ZStack {
                    Capsule().fill(.secondary.opacity(0.15)).frame(height:6)
                    Capsule().fill(.green.opacity(0.4)).frame(width:geometry.size.width*0.2,height:6)
                    Rectangle().fill(.green).frame(width:2,height:22)
                    if let frame = audio.pitchFrame {
                        Circle().fill(inTune ? .green:.orange).frame(width:14,height:14).offset(x:geometry.size.width*CGFloat(max(-50,min(50,frame.cents)))/100)
                    }
                }
            }.frame(height:26)
            HStack { Text("♭ 偏低");Spacer();Text(inTune ? "音准稳定":"单音调音");Spacer();Text("偏高 ♯") }.font(.caption).foregroundStyle(.secondary)
            Text(audio.isCapturing ? "拨响一根弦，让声音自然延续。" : "在窗口底部“声音来源”中启用输入。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var inTune:Bool { audio.pitchFrame.map { abs($0.cents) <= 10 && $0.isStable } ?? false }
}
