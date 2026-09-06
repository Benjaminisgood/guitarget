import SwiftUI
import AVFoundation
import GuitarCore
import GuitarAudio

struct PracticePanel: View {
    @ObservedObject var audio: AudioService
    let score: GuitarScore
    @State private var mode: PracticeMode = .waitForCorrect
    @State private var voice: ScoreVoice = .melody
    @State private var engine = PracticeEngine()
    @State private var latencyMS: Double = 0
    @State private var engineStarted = false
    @State private var awaitingAnchor = false
    @State private var demonstration = false
    @State private var externalDemonstration = false
    @State private var savedTick = 0
    @State private var previousMutes: Set<ScoreVoice> = []
    @State private var previousMetronome = false
    @State private var previousCountIn = false
    @State private var previousLoop: Range<Int>?
    @State private var previousSpeed = 1.0
    @State private var audioSettingsSaved = false
    @State private var synchronizedAnchor: Double?
    @State private var anchorRequestedAt = 0.0
    @State private var acceptFramesAfter = 0.0
    @State private var transportPaused = false
    @State private var borrowedSettingsSuspended = false
    @State private var practiceSpeed = 1.0
    @State private var practiceMetronome = true
    @State private var calibration = false
    @State private var calibrationAnchor: Double?
    @State private var calibrationPairs: [Int: Double] = [:]
    @State private var lastCalibrationOnset: Double = 0
    @State private var calibrationStatus = ""
    @State private var owner = "练习-\(UUID().uuidString)"
    private let timer = Timer.publish(every:0.025,on:.main,in:.common).autoconnect()

    var body: some View {
        LearningCard(title:"把听见的，变成弹出的",icon:"ear.badge.checkmark") {
            HStack(spacing:16) {
                Picker("练习模式",selection:$mode) { ForEach(PracticeMode.allCases){Text($0.title).tag($0)} }.pickerStyle(.segmented).frame(width:270).disabled(engineStarted)
                Picker("声部",selection:$voice) { ForEach(ScoreVoice.allCases){Text($0.title).tag($0)} }.frame(width:120).disabled(engineStarted)
                Spacer()
                if engineStarted {
                    Button("结束练习"){stop()}
                } else {
                    Button("开始练习"){start()}.buttonStyle(.borderedProminent).disabled(!audio.isCapturing || calibration)
                }
            }
            HStack(alignment:.center,spacing:22) {
                VStack(alignment:.leading,spacing:6) {
                    Text(engine.currentTarget?.title ?? (engine.isFinished ? "完成":"准备好了吗？")).font(.system(size:30,weight:.bold,design:.rounded)).foregroundStyle(.orange)
                    Text(transportPaused ? "播放已暂停，暂停练习判定" : engine.status).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if engineStarted, let target = engine.currentTarget {
                    Text("\(engine.index+1) / \(engine.targets.count)").monospacedDigit().foregroundStyle(.secondary)
                    if let midi = target.midi {
                        Button { demonstrate(midi:midi) } label:{Label("示范",systemImage:"speaker.wave.2")}.disabled(demonstration || awaitingAnchor)
                    }
                    if mode == .waitForCorrect { Button("手动继续"){engine.manualAdvance(at:hostTime())}.disabled(demonstration || externalDemonstration || transportPaused) }
                }
            }
            if engineStarted || engine.isFinished { ProgressView(value:engine.progress).tint(.orange) }
            HStack(spacing:16) {
                Text("音准 ±25 音分 · 稳定 120 ms · 起音 ±150 ms").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("输入延迟").font(.caption)
                TextField("ms",value:$latencyMS,format:.number.precision(.fractionLength(0))).frame(width:55).textFieldStyle(.roundedBorder).disabled(engineStarted || calibration)
                Text("ms").font(.caption).foregroundStyle(.secondary)
                Button(calibration ? "完成校准":"跟拍校准") { calibration ? finishCalibration() : startCalibration() }.disabled(engineStarted || !audio.isCapturing)
            }
            if !calibrationStatus.isEmpty { Text(calibrationStatus).font(.caption).foregroundStyle(.secondary) }
            if !engine.results.isEmpty {
                Divider()
                HStack(spacing:25) {
                    resultNumber("已评分",String(engine.summary.assessed))
                    resultNumber("音准与节奏通过",String(format:"%.0f%%",engine.summary.accuracy*100))
                    resultNumber("漏音",String(engine.summary.missed))
                    resultNumber("平均起音偏差",engine.summary.meanAbsoluteTimingMS.map{String(format:"%.0f ms",$0)} ?? "—")
                    Spacer()
                }
                ScrollView(.horizontal) {
                    HStack(spacing:8) {
                        ForEach(engine.results.suffix(24)) { result in
                            VStack(spacing:4) {
                                Text(result.target.title).font(.caption.bold())
                                Text(result.outcome.title).font(.caption).foregroundStyle(result.outcome == .correct ? .green:.secondary)
                                Text(result.timingDescription).font(.system(size:10)).foregroundStyle(.secondary)
                            }.padding(8).background(.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:8))
                        }
                    }
                }
            }
            Text(audio.isCapturing ? "跟练时两个声部默认静音；示范期间暂停判定。和弦、死音与连续变音技巧跳过单音评分。麦克风跟练建议戴耳机。" : "先在“声音来源”启用麦克风、声卡或系统声音，即可开始。自由调音始终显示在指板页面。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
        .onReceive(timer){_ in tick()}
        .onReceive(audio.pitchFrames){ frame in consume(frame) }
        .onChange(of:score) { previous,current in
            if engineStarted && engine.stopIfScoreChanged(from:previous,to:current) { stop() }
        }
        .onDisappear { if engineStarted || calibration { stop() } }
    }

    private func resultNumber(_ title:String,_ value:String)->some View {
        VStack(alignment:.leading,spacing:5) {Text(title).font(.caption).foregroundStyle(.secondary);Text(value).font(.title3.bold()).monospacedDigit()}
    }
    private func hostTime()->Double { AVAudioTime.seconds(forHostTime:mach_absolute_time()) }
    private var effectiveBPM: Double { score.bpm * max(0.2,min(3,audio.speed)) }
    private func saveAudioSettings() {
        previousMutes=audio.mutedVoices;previousMetronome=audio.metronomeEnabled;previousCountIn=audio.countInEnabled;previousLoop=audio.loopRange;previousSpeed=audio.speed
        audioSettingsSaved=true
        borrowedSettingsSuspended=false
        audio.stop();audio.mutedVoices=[.melody,.bass];audio.loopRange=nil
    }
    private func restoreAudioSettings() {
        guard audioSettingsSaved else{return}
        audioSettingsSaved=false
        borrowedSettingsSuspended=false
        if audio.ownerID == owner || audio.ownerID == owner+"示范" { audio.stop() }
        audio.mutedVoices=previousMutes;audio.metronomeEnabled=previousMetronome;audio.countInEnabled=previousCountIn;audio.loopRange=previousLoop;audio.speed=previousSpeed
    }
    private func start() {
        let targets=PracticeTarget.from(score:score,voice:voice)
        latencyMS=latencyMS.isFinite ? max(-1000,min(1000,latencyMS)):0
        engine=PracticeEngine(configuration:PracticeConfiguration(inputLatency:latencyMS/1000))
        guard !targets.isEmpty else {
            engine.start(targets:[],mode:mode,at:hostTime(),bpm:effectiveBPM)
            return
        }
        saveAudioSettings()
        engineStarted=true;demonstration=false;externalDemonstration=false;transportPaused=false
        acceptFramesAfter=hostTime();synchronizedAnchor=nil
        if mode == .timed {
            audio.metronomeEnabled=true;audio.countInEnabled=true
            requestAnchor()
            audio.play(score:score,owner:owner,fromTick:0)
        } else {
            engine.start(targets:targets,mode:mode,at:hostTime(),bpm:effectiveBPM)
        }
    }
    private func stop() {
        engine.stop();engineStarted=false;awaitingAnchor=false;demonstration=false;externalDemonstration=false;calibration=false;transportPaused=false;synchronizedAnchor=nil
        restoreAudioSettings()
    }
    private func requestAnchor() {
        awaitingAnchor=true;anchorRequestedAt=hostTime();synchronizedAnchor=nil
    }
    private func resumePracticeTransport() {
        if borrowedSettingsSuspended {
            borrowedSettingsSuspended=false
            audio.speed=practiceSpeed;audio.metronomeEnabled=practiceMetronome
            audio.mutedVoices=[.melody,.bass];audio.loopRange=nil
        }
        acceptFramesAfter=hostTime()
        engine.setDemonstrating(false,at:acceptFramesAfter)
        if mode == .timed {
            audio.mutedVoices=[.melody,.bass];audio.loopRange=nil;audio.countInEnabled=false
            requestAnchor();audio.play(score:score,owner:owner,fromTick:savedTick)
        }
    }
    private func tick() {
        if calibration {
            guard audio.isCapturing else { calibration=false;calibrationStatus="声音采集已停止，校准已取消。";restoreAudioSettings();return }
            guard audio.ownerID == owner else { calibration=false;calibrationStatus="其他播放已接管声音，校准已取消。";restoreAudioSettings();return }
            if calibrationAnchor == nil { calibrationAnchor=audio.transportStartHostTime }
            else if let anchor=audio.transportStartHostTime,anchor != calibrationAnchor {
                calibration=false;calibrationStatus="播放时钟或速度发生变化，请重新校准。";restoreAudioSettings();return
            }
            if calibrationAnchor == nil, hostTime()-anchorRequestedAt>2 {
                calibration=false;calibrationStatus="未取得校准播放时钟，请检查输出设备。";restoreAudioSettings();return
            }
            if let anchor=calibrationAnchor, hostTime()>anchor+6.5 { finishCalibration() }
            return
        }
        guard engineStarted else{return}
        if !audio.isCapturing { stop();return }
        if audio.isPlaying || audio.isPaused, audio.ownerID != owner, audio.ownerID != owner+"示范" {
            if !externalDemonstration {
                if !demonstration { savedTick = engine.currentTarget?.startTick ?? 0 }
                engine.setDemonstrating(true,at:hostTime());externalDemonstration=true;demonstration=false
                practiceSpeed=audio.speed;practiceMetronome=audio.metronomeEnabled;borrowedSettingsSuspended=true
                // A different document must not inherit the temporary mute used by this practice.
                // Keep the original snapshot until this session ends; resume reapplies its own settings.
                audio.mutedVoices=previousMutes;audio.metronomeEnabled=previousMetronome;audio.countInEnabled=previousCountIn;audio.loopRange=previousLoop;audio.speed=previousSpeed
            }
            return
        }
        if externalDemonstration {
            externalDemonstration=false;resumePracticeTransport()
        }
        if demonstration {
            if !audio.isPlaying && !audio.isPaused {
                demonstration=false
                resumePracticeTransport()
            }
            return
        }
        if mode == .timed, audio.ownerID == owner, audio.isPaused {
            if !transportPaused { engine.setDemonstrating(true,at:hostTime());transportPaused=true }
            return
        }
        if transportPaused {
            transportPaused=false;acceptFramesAfter=hostTime();engine.setDemonstrating(false,at:acceptFramesAfter);requestAnchor()
        }
        if mode == .timed, audio.ownerID == owner, let anchor=audio.transportStartHostTime, anchor != synchronizedAnchor {
            if engine.targets.isEmpty {
                engine.start(targets:PracticeTarget.from(score:score,voice:voice),mode:mode,at:anchor,bpm:effectiveBPM)
            } else {
                engine.synchronizeTimeline(startedAt:anchor,bpm:effectiveBPM)
                acceptFramesAfter=hostTime()
            }
            synchronizedAnchor=anchor;awaitingAnchor=false
        }
        if mode == .timed, audio.ownerID == owner, audio.transportStartHostTime == nil, !awaitingAnchor { requestAnchor() }
        if awaitingAnchor, hostTime()-anchorRequestedAt>2 { stop();calibrationStatus="未取得播放时钟，请检查输出设备后重试。";return }
        if !awaitingAnchor { engine.update(at:hostTime()) }
        if engine.isFinished { engineStarted=false;restoreAudioSettings();return }
        if mode == .timed, audio.ownerID != owner, !awaitingAnchor { stop() }
    }
    private func consume(_ frame:PitchFrame) {
        if calibration {
            guard audio.ownerID == owner, audio.isCapturing, let anchor=calibrationAnchor,let onset=frame.onsetTimestamp,onset>lastCalibrationOnset else{return}
            lastCalibrationOnset=onset
            let index=Int(((onset-anchor)/0.75).rounded())
            if (0..<8).contains(index),abs(onset-(anchor+Double(index)*0.75))<0.35,calibrationPairs[index] == nil { calibrationPairs[index]=onset }
            calibrationStatus="跟随节拍拨一根空弦，已记录 \(calibrationPairs.count) / 8 次。"
            return
        }
        guard engineStarted,!awaitingAnchor,!demonstration,!externalDemonstration,!transportPaused,frame.timestamp >= acceptFramesAfter else{return}
        if mode == .timed, audio.transportStartHostTime == nil || audio.transportStartHostTime != synchronizedAnchor { return }
        if (audio.isPlaying || audio.isPaused) && audio.ownerID != owner { return }
        engine.consume(PitchObservation(timestamp:frame.timestamp,frequency:frame.frequency,cents:frame.cents,confidence:frame.confidence,rms:frame.rms,isStable:frame.isStable,onsetTimestamp:frame.onsetTimestamp))
    }
    private func demonstrate(midi:Int) {
        guard let note=score.measures.flatMap(\.voices).flatMap(\.events).flatMap(\.notes).first(where:{score.midi(for:$0)==midi}) else{return}
        savedTick=audio.currentTick;engine.setDemonstrating(true,at:hostTime());demonstration=true
        audio.preview(notes:[note],tuning:score.tuning,owner:owner+"示范",strum:false)
    }
    private func startCalibration() {
        saveAudioSettings();calibration=true;calibrationAnchor=nil;calibrationPairs=[:];lastCalibrationOnset=0
        anchorRequestedAt=hostTime()
        audio.speed=1;audio.metronomeEnabled=true;audio.countInEnabled=true
        var sample=GuitarScore(title:"输入延迟校准",measures:[ScoreMeasure(),ScoreMeasure()]);sample.bpm=80
        calibrationStatus="预备拍后，跟随 8 次节拍拨空弦。估计值包含人为跟拍偏差；精确延迟需声卡回环测量。"
        audio.play(score:sample,owner:owner,fromTick:0)
    }
    private func finishCalibration() {
        if let anchor=calibrationAnchor {
            let keys=calibrationPairs.keys.sorted()
            if let estimate=InputLatencyCalibration.estimate(expected:keys.map{anchor+Double($0)*0.75},detected:keys.map{calibrationPairs[$0]!}) {
                latencyMS=estimate*1000;calibrationStatus=String(format:"已用 %d 次起音估计偏移：%+.0f ms（含人为跟拍偏差）。",keys.count,latencyMS)
            } else {calibrationStatus="有效起音不足 3 次，请检查输入电平后重试。"}
        } else {calibrationStatus="尚未取得预备拍后的播放时钟，请重新校准。"}
        calibration=false;restoreAudioSettings()
    }
}
