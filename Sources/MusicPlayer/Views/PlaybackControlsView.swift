import SwiftUI

struct PlaybackControlsView: View {
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var playlistManager: PlaylistManager
    @State private var playButtonPressed = false
    @State private var previousButtonPressed = false
    @State private var nextButtonPressed = false
    @State private var isPulsing = false
    @State private var previousHovered = false
    @State private var nextHovered = false
    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }
    private var onAccentPillForeground: Color { colorScheme == .dark ? Color.black.opacity(0.86) : Color.white }
    private var isEphemeralPlayback: Bool { audioPlayer.persistPlaybackState == false }

    var body: some View {
        VStack(spacing: 24) {
            // 主要播放控制按钮
            HStack(spacing: 32) {
                // 上一首按钮
                Button(action: previousTrack) {
                    ZStack {
                        // 悬停时的发光背景
                        Circle()
                            .fill(theme.accent.opacity(previousHovered ? 0.15 : 0))
                            .frame(width: 52, height: 52)
                            .blur(radius: 4)

                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Circle()
                                    .fill(theme.surface.opacity(0.5))
                            )
                            .overlay(
                                Circle()
                                    .stroke(previousHovered ? theme.glowStroke : theme.stroke, lineWidth: 1)
                            )
                            .frame(width: 48, height: 48)
                            .shadow(color: theme.subtleShadow, radius: 8, x: 0, y: 4)

                        Image(systemName: "backward.fill")
                            .font(.title2)
                            .foregroundColor(previousHovered ? theme.accent : .primary)
                    }
                    .scaleEffect(previousButtonPressed ? 0.92 : (previousHovered ? 1.08 : 1.0))
                    .animation(AppTheme.quickSpring, value: previousButtonPressed)
                    .animation(AppTheme.quickSpring, value: previousHovered)
                }
                .disabled(playlistManager.playbackScopePlayableCount() == 0 || isEphemeralPlayback)
                .buttonStyle(PlainButtonStyle())
                .onHover { hovering in previousHovered = hovering }
                .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
                    previousButtonPressed = pressing
                }, perform: {})

                // 主播放按钮
                Button(action: togglePlayback) {
                    ZStack {
                        // 脉动光环（播放时显示）
                        if audioPlayer.isPlaying {
                            Circle()
                                .stroke(theme.accent.opacity(0.4), lineWidth: 3)
                                .frame(width: 80, height: 80)
                                .scaleEffect(isPulsing ? 1.25 : 1.0)
                                .opacity(isPulsing ? 0 : 0.6)

                            Circle()
                                .stroke(theme.accentSecondary.opacity(0.3), lineWidth: 2)
                                .frame(width: 80, height: 80)
                                .scaleEffect(isPulsing ? 1.4 : 1.0)
                                .opacity(isPulsing ? 0 : 0.4)
                        }

                        // 发光背景
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        theme.accent.opacity(audioPlayer.isPlaying ? 0.35 : 0.15),
                                        Color.clear
                                    ],
                                    center: .center,
                                    startRadius: 30,
                                    endRadius: 55
                                )
                            )
                            .frame(width: 90, height: 90)
                            .blur(radius: 8)

                        // 主按钮
                        Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 72))
                            .foregroundStyle(theme.accentGradient)
                            .shadow(color: theme.accentShadow, radius: 12, x: 0, y: 6)
                    }
                    .scaleEffect(playButtonPressed ? 0.92 : 1.0)
                    .animation(AppTheme.quickSpring, value: playButtonPressed)
                    .animation(AppTheme.smoothTransition, value: audioPlayer.isPlaying)
                }
                .disabled(audioPlayer.currentFile == nil)
                .buttonStyle(PlainButtonStyle())
                .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
                    playButtonPressed = pressing
                }, perform: {})
                .onChange(of: audioPlayer.isPlaying) { playing in
                    if playing {
                        startPulsingAnimation()
                    } else {
                        isPulsing = false
                    }
                }
                .onAppear {
                    if audioPlayer.isPlaying {
                        startPulsingAnimation()
                    }
                }

                // 下一首按钮
                Button(action: nextTrack) {
                    ZStack {
                        // 悬停时的发光背景
                        Circle()
                            .fill(theme.accent.opacity(nextHovered ? 0.15 : 0))
                            .frame(width: 52, height: 52)
                            .blur(radius: 4)

                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Circle()
                                    .fill(theme.surface.opacity(0.5))
                            )
                            .overlay(
                                Circle()
                                    .stroke(nextHovered ? theme.glowStroke : theme.stroke, lineWidth: 1)
                            )
                            .frame(width: 48, height: 48)
                            .shadow(color: theme.subtleShadow, radius: 8, x: 0, y: 4)

                        Image(systemName: "forward.fill")
                            .font(.title2)
                            .foregroundColor(nextHovered ? theme.accent : .primary)
                    }
                    .scaleEffect(nextButtonPressed ? 0.92 : (nextHovered ? 1.08 : 1.0))
                    .animation(AppTheme.quickSpring, value: nextButtonPressed)
                    .animation(AppTheme.quickSpring, value: nextHovered)
                }
                .disabled(playlistManager.playbackScopePlayableCount() == 0 || isEphemeralPlayback)
                .buttonStyle(PlainButtonStyle())
                .onHover { hovering in nextHovered = hovering }
                .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
                    nextButtonPressed = pressing
                }, perform: {})
            }
            
            // 循环和随机播放控制
            HStack(spacing: 16) {
                Button(action: { audioPlayer.toggleLoop() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "repeat")
                            .font(.caption)
                        Text("单曲循环")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(
                                audioPlayer.isLooping ? 
                                theme.accentGradient :
                                LinearGradient(
                                    colors: [
                                        theme.mutedSurface,
                                        theme.surface
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .shadow(color: theme.subtleShadow, radius: 6, x: 0, y: 2)
                    )
                    .foregroundColor(audioPlayer.isLooping ? onAccentPillForeground : .primary)
                    .animation(.easeInOut(duration: 0.2), value: audioPlayer.isLooping)
                }
                .buttonStyle(PlainButtonStyle())
                
                HStack(spacing: 8) {
                    Button(action: { audioPlayer.toggleShuffle() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "shuffle")
                                .font(.caption)
                            Text("随机播放")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 20)
                                .fill(
                                    audioPlayer.isShuffling ? 
                                    theme.accentGradient :
                                    LinearGradient(
                                        colors: [
                                            theme.mutedSurface,
                                            theme.surface
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .shadow(color: theme.subtleShadow, radius: 6, x: 0, y: 2)
                        )
                        .foregroundColor(audioPlayer.isShuffling ? onAccentPillForeground : .primary)
                        .animation(.easeInOut(duration: 0.2), value: audioPlayer.isShuffling)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    // 随机下一首按钮
                    Button(action: playRandomTrack) {
                        Image(systemName: "dice")
                            .font(.system(size: 14))
                            .foregroundColor(.primary)
                            .frame(width: 32, height: 32)
                            .background(
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            gradient: Gradient(colors: [
                                                Color.orange.opacity(0.8),
                                                Color.orange.opacity(0.6)
                                            ]),
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .shadow(color: Color.orange.opacity(0.3), radius: 4, x: 0, y: 2)
                            )
                    }
                    .disabled(playlistManager.playbackScopePlayableCount() < 2 || isEphemeralPlayback)
                    .buttonStyle(PlainButtonStyle())
                    .help(isEphemeralPlayback ? "临时播放模式下不可切歌" : "随机播放一首新歌")
                }
            }
        }
        // 自动播放逻辑已由常驻的 PlaybackCoordinator 处理，避免视图销毁时失效或重复触发
    }
    
    private func togglePlayback() {
        if audioPlayer.isPlaying {
            audioPlayer.pause()
        } else if audioPlayer.currentFile != nil {
            audioPlayer.resume()
        }
    }
    
    private func nextTrack() {
        guard !isEphemeralPlayback else { return }
        if let nextFile = playlistManager.nextFile(isShuffling: audioPlayer.isShuffling) {
            audioPlayer.play(nextFile)
        }
    }
    
    private func previousTrack() {
        guard !isEphemeralPlayback else { return }
        if let previousFile = playlistManager.previousFile(isShuffling: audioPlayer.isShuffling) {
            audioPlayer.play(previousFile)
        }
    }
    
    private func playRandomTrack() {
        guard !isEphemeralPlayback else { return }
        if let randomFile = playlistManager.getRandomFileExcludingCurrent() {
            audioPlayer.play(randomFile)
        }
    }

    private func startPulsingAnimation() {
        withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
            isPulsing = true
        }
    }
}

struct AudioControlsView: View {
    @ObservedObject var audioPlayer: AudioPlayer
    @State private var volumeHovering = false
    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }

    var body: some View {
        VStack(spacing: 20) {
            // 音量控制
            VStack(spacing: 14) {
                HStack {
                    // 音量图标（根据音量大小变化）
                    Image(systemName: volumeIconName)
                        .font(.system(size: 16))
                        .foregroundStyle(theme.accentGradient)
                        .frame(width: 24)

                    Text("主音量")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)

                    Spacer()

                    Text("\(Int(audioPlayer.volume * 100))%")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(theme.accent)
                        .monospacedDigit()
                }

                // 自定义音量滑块
                GeometryReader { geometry in
                    let volumeWidth = geometry.size.width * CGFloat(audioPlayer.volume)

                    ZStack(alignment: .leading) {
                        // 背景轨道
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.mutedSurface)
                            .frame(height: volumeHovering ? 8 : 6)

                        // 音量填充
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.accentGradient)
                            .frame(width: max(0, volumeWidth), height: volumeHovering ? 8 : 6)
                            .shadow(color: theme.accentShadow, radius: volumeHovering ? 6 : 3, x: 0, y: 0)

                        // 音量指示器
                        Circle()
                            .fill(.white)
                            .frame(width: volumeHovering ? 14 : 10, height: volumeHovering ? 14 : 10)
                            .shadow(color: theme.accent.opacity(0.4), radius: 3, x: 0, y: 1)
                            .offset(x: max(0, min(volumeWidth - (volumeHovering ? 7 : 5), geometry.size.width - (volumeHovering ? 14 : 10))))
                            .opacity(volumeHovering ? 1 : 0.9)
                    }
                    .frame(height: volumeHovering ? 14 : 10)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let newVolume = max(0, min(1, Float(value.location.x / geometry.size.width)))
                                audioPlayer.setVolume(newVolume)
                            }
                    )
                    .onHover { hovering in
                        withAnimation(AppTheme.quickSpring) {
                            volumeHovering = hovering
                        }
                    }
                }
                .frame(height: 14)
            }

            Divider()
                .background(theme.stroke)

            // 音量均衡开关
            HStack {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(audioPlayer.isNormalizationEnabled ? AnyShapeStyle(theme.accentGradient) : AnyShapeStyle(theme.mutedText))

                Text("音量均衡")
                    .font(.system(size: 14, weight: .medium))

                Spacer()

                Toggle("", isOn: Binding(
                    get: { audioPlayer.isNormalizationEnabled },
                    set: { _ in audioPlayer.toggleNormalization() }
                ))
                .toggleStyle(SwitchToggleStyle(tint: theme.accent))
                .labelsHidden()
            }
            .help("自动调整不同歌曲的音量差异")
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(theme.surface.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(theme.stroke, lineWidth: 0.5)
                )
                .shadow(color: theme.subtleShadow, radius: 12, x: 0, y: 6)
        )
    }

    private var volumeIconName: String {
        if audioPlayer.volume == 0 {
            return "speaker.slash.fill"
        } else if audioPlayer.volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if audioPlayer.volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }
}
