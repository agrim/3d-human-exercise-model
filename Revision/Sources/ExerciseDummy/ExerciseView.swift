import MetalKit
import SwiftUI

/// UIKit/AppKit surface for hosts that own their own view hierarchy.
@MainActor
public final class ExerciseMetalView: MTKView, MTKViewDelegate {
  public private(set) var player: ExercisePlayer
  public init(player: ExercisePlayer) {
    self.player = player
    super.init(frame: .zero, device: player.renderer.device)
    colorPixelFormat = .bgra8Unorm_srgb
    depthStencilPixelFormat = .depth32Float
    sampleCount = player.renderer.sampleCount
    preferredFramesPerSecond = 60
    framebufferOnly = true
    delegate = self
    player.attach(self)
    refresh()
  }
  @available(*, unavailable)
  required init(coder: NSCoder) { fatalError("Initialize with an ExercisePlayer.") }

  public func display(_ player: ExercisePlayer) {
    guard self.player !== player else { return }
    self.player.detach(self)
    self.player = player
    device = player.renderer.device
    sampleCount = player.renderer.sampleCount
    player.attach(self)
    refresh()
  }
  #if os(iOS)
    public override func didMoveToWindow() {
      super.didMoveToWindow()
      NotificationCenter.default.removeObserver(
        self, name: UIScene.didEnterBackgroundNotification, object: nil)
      NotificationCenter.default.removeObserver(
        self, name: UIScene.didActivateNotification, object: nil)
      if let scene = window?.windowScene {
        for name in [UIScene.didEnterBackgroundNotification, UIScene.didActivateNotification] {
          NotificationCenter.default.addObserver(
            self, selector: #selector(sceneChanged(_:)), name: name, object: scene)
        }
      }
      refresh()
    }
    @objc private func sceneChanged(_ notification: Notification) { refresh() }
  #else
    public override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      refresh()
    }
  #endif

  func refresh() {
    #if os(iOS)
      let visible = window != nil && window?.windowScene?.activationState != .background
    #else
      let visible = window != nil
    #endif
    isPaused = !visible || !player.isPlaying
    enableSetNeedsDisplay = visible && !player.isPlaying
    if enableSetNeedsDisplay {
      #if os(iOS)
        setNeedsDisplay()
      #else
        needsDisplay = true
      #endif
    }
  }
  public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { refresh() }
  public func draw(in view: MTKView) { player.draw(in: view) }
}

#if os(iOS)
  public struct ExerciseDummyView: UIViewRepresentable {
    public let player: ExercisePlayer
    public init(player: ExercisePlayer) { self.player = player }
    public func makeUIView(context: Context) -> ExerciseMetalView {
      ExerciseMetalView(player: player)
    }
    public func updateUIView(_ view: ExerciseMetalView, context: Context) { view.display(player) }
  }
#elseif os(macOS)
  public struct ExerciseDummyView: NSViewRepresentable {
    public let player: ExercisePlayer
    public init(player: ExercisePlayer) { self.player = player }
    public func makeNSView(context: Context) -> ExerciseMetalView {
      ExerciseMetalView(player: player)
    }
    public func updateNSView(_ view: ExerciseMetalView, context: Context) { view.display(player) }
  }
#endif
