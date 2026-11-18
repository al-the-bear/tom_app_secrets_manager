// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

import Flutter
import UIKit

/// The scene: a cover over the window while the app is not active, so the app
/// switcher's snapshot shows no entry (iOS has no FLAG_SECURE).
class SceneDelegate: FlutterSceneDelegate {
  private var cover: UIView?

  override func sceneWillResignActive(_ scene: UIScene) {
    super.sceneWillResignActive(scene)
    guard cover == nil, let window = self.window else { return }
    let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    view.frame = window.bounds
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    let icon = UIImageView(image: UIImage(systemName: "lock.fill"))
    icon.tintColor = .secondaryLabel
    icon.translatesAutoresizingMaskIntoConstraints = false
    view.contentView.addSubview(icon)
    NSLayoutConstraint.activate([
      icon.centerXAnchor.constraint(equalTo: view.contentView.centerXAnchor),
      icon.centerYAnchor.constraint(equalTo: view.contentView.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 48),
      icon.heightAnchor.constraint(equalToConstant: 48),
    ])
    window.addSubview(view)
    cover = view
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    cover?.removeFromSuperview()
    cover = nil
  }
}
